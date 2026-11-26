package render_target_check

/*
	G5's check: render targets and the internal resolution. Run from the repository root: `odin run examples/render-target-check`
	on PC, or `3ds_build.bat examples\render-target-check` / `vita_build.bat examples\render-target-check`.

	On the first frame a 16x16 probe target is drawn into (four coloured quarters and a near and a far square that only
	a depth buffer can put in order); on the second frame its pixels are read back and compared with what was drawn, and the
	HUD shows "checks: N passed, M failed" (the billboard-check pattern, and printed with the same prefix). It is a handful of
	draws: on the 3DS hundreds in one frame overflowed the command buffer once (G4).

	The scene is a lit floor, a character, three billboards and two trees, drawn into a target and scaled up to the screen.
	A 64x64 minimap (a target with no depth buffer, drawn with a screen camera) is shown on the HUD as an ordinary sprite.
	Over the first 360 frames the scene's size goes 1, 2/3, 1/2 of the screen and the pixel count and average frame time of each
	is printed (and shown): the frame time is only a rough guide on an emulator, and v-synced hardware stays at 16.7 ms until
	a size is too much for it, so the pixel count is the number to read.

	Controls (PC key / 3DS button / Vita button):
	- walk: WASD or arrows / left stick (circle pad) / d-pad. Look: right stick (C-stick) / touch drag
	- M / face button up (X, Triangle): explicit target <-> set_internal_resolution (the whole game, HUD included, at the smaller size)
	- S / face button down (B, Cross): size 1, 2/3, 1/2
	- F / face button left (Y, Square): fit FIT, INTEGER, FILL, STRETCH
	- P / face button right (A, Circle): POINT <-> LINEAR upscaling
	- Escape / SELECT quits

	What should show: the scene at the smaller size, scaled up (blocky with POINT, soft with LINEAR; INTEGER leaves bars when
	the size does not divide the screen), and the HUD text always crisp in explicit mode and as blocky as the scene in internal
	mode, where the HUD is drawn into the same smaller picture. The minimap's red quarter is at its top left.
*/

import "core:fmt"
import mb "../../matchbox"

SPEED :: 4
BENCH_FRAMES :: 120
SCALES :: [3]f32{1, 0.6667, 0.5}
FITS :: [4]mb.Fit_Mode{.FIT, .INTEGER, .FILL, .STRETCH}

Check_Result :: struct {
	passed:int,
	failed:int,
	first_failure:string,
}

check :: proc(result:^Check_Result, ok:bool, what:string) {
	if ok {
		result.passed += 1
		return
	}
	result.failed += 1
	if result.first_failure == "" do result.first_failure = what
}

// What the probe is drawn with: a camera 16 units tall is a unit a pixel, x from -8 to 8 and y from 8 to -8
draw_probe :: proc(probe:^mb.Render_Target) {
	mb.render_target_start(probe, [4]f32{0, 0, 0, 1})
	mb.camera_start(mb.create_camera_2d(16))
	mb.render_rectangle({-4, 4, -5}, {8, 8}, {1, 0, 0, 1}) // top left: red
	mb.render_rectangle({4, 4, -5}, {8, 8}, {0, 1, 0, 1}) // top right: green
	mb.render_rectangle({-4, -4, -5}, {8, 8}, {0, 0, 1, 1}) // bottom left: blue
	mb.render_rectangle({4, -4, -5}, {8, 8}, {1, 1, 1, 1}) // bottom right: white
	// The near yellow (z 1) first, the far magenta (z -1) second: yellow covers x -2..2, magenta x -1..3,
	// so a depth buffer shows yellow up to x 2 and magenta from 2 to 3, whatever the order
	mb.render_rectangle({0, 0, 1}, {4, 4}, {1, 1, 0, 1})
	mb.render_rectangle({1, 0, -1}, {4, 4}, {1, 0, 1, 1})
	mb.camera_end()
	mb.render_target_end()
}

draw_minimap :: proc(minimap:^mb.Render_Target, angle:f32) {
	mb.render_target_start(minimap, [4]f32{0, 0, 1, 1})
	mb.camera_start(mb.create_screen_camera(64)) // a screen camera: this target has no depth buffer
	mb.render_rectangle({-16, 16, 0}, {32, 32}, {1, 0, 0, 1}) // the top left quarter, red
	mb.render_rectangle({16 * angle, -16, 0}, {8, 8}, {1, 1, 0, 1}) // a marker that slides
	mb.camera_end()
	mb.render_target_end()
}

pixel :: proc(pixels:[]u8, width, x, y:int) -> [4]u8 {
	offset := (y * width + x) * 4
	return {pixels[offset], pixels[offset + 1], pixels[offset + 2], pixels[offset + 3]}
}

// Reads the probe back and compares it with what draw_probe drew. Pixel (x, y) is top-left origin
check_probe :: proc(probe:mb.Render_Target, minimap:mb.Render_Target, result:^Check_Result) {
	check(result, probe.width == 16 && probe.height == 16 && probe.has_depth, "probe size and depth")
	check(result, minimap.width == 64 && minimap.has_depth == false, "minimap size, no depth")

	pixels := mb.read_render_target_pixels(probe)
	defer delete(pixels)
	check(result, pixel(pixels, 16, 3, 3) == {255, 0, 0, 255}, "top left is red")
	check(result, pixel(pixels, 16, 12, 3) == {0, 255, 0, 255}, "top right is green")
	check(result, pixel(pixels, 16, 3, 12) == {0, 0, 255, 255}, "bottom left is blue")
	check(result, pixel(pixels, 16, 12, 12) == {255, 255, 255, 255}, "bottom right is white")
	// World x 1.5 is pixel 9 (both squares cover it: the near yellow wins); x 2.5 is pixel 10 (only the far magenta)
	check(result, pixel(pixels, 16, 9, 8) == {255, 255, 0, 255}, "depth: the near square wins")
	check(result, pixel(pixels, 16, 10, 8) == {255, 0, 255, 255}, "depth: the far one beyond it")

	mini := mb.read_render_target_pixels(minimap)
	defer delete(mini)
	check(result, pixel(mini, 64, 8, 8) == {255, 0, 0, 255}, "minimap: red quarter at the top left")
	check(result, pixel(mini, 64, 56, 8) == {0, 0, 255, 255}, "minimap: the clear colour elsewhere")

	// The picture lands on whole multiples at INTEGER, and its corner is the target's origin
	top_left, bottom_right := mb.calculate_upscaled_rectangle(probe, .INTEGER)
	width := int(bottom_right.x - top_left.x)
	check(result, width >= 16 && width % 16 == 0, "INTEGER is a whole multiple")
	position := mb.calculate_target_position(probe, top_left, .INTEGER)
	check(result, abs(position.x) < 0.01 && abs(position.y) < 0.01, "the picture's corner is the target's origin")
}

main :: proc() {
	mb.init("render target check", 960, 544)

	floor := mb.create_plane_model(40)
	character := mb.create_cylinder_model(0.4, 1.7)
	font := mb.create_font(mb.DEFAULT_FONT_BYTES, 32)
	marker := mb.create_sprite(mb.load_texture("marker.png", .POINT))
	tree := mb.create_sprite(mb.load_texture("tree.png", .POINT))
	tree.pivot = {0.5, 0}

	mb.set_lighting()
	mb.set_lights({mb.create_directional_light({-0.5, -1, -0.3})})

	probe := mb.create_render_target({width = 16, height = 16})
	minimap := mb.create_render_target({width = 64, height = 64, no_depth = true, filter = .POINT})
	minimap_sprite := mb.create_sprite(minimap.texture)
	minimap_sprite.pixels_per_unit = 32 // 2 HUD units wide

	scales := SCALES
	fits := FITS
	scale_index := 0
	fit_index := 1
	filter := mb.Filter_Mode.POINT
	internal := false
	scene := mb.create_render_target({scale = scales[scale_index], filter = filter})
	scene_dirty := false

	checks:Check_Result
	bench_lines:[3]string
	bench_frame := 0
	bench_time:f32 = 0

	player := [3]f32{0, 0, 8}
	third := mb.create_third_person_camera(player, 0)
	frame := 0

	for mb.is_running() {
		mb.poll_events()
		if mb.is_key_pressed(.ESCAPE) || mb.is_gamepad_pressed(.SELECT) do mb.stop_running()
		delta_time := mb.get_delta_time()
		frame += 1

		if mb.is_key_pressed(.M) || mb.is_gamepad_pressed(.FACE_UP) do internal = !internal
		if mb.is_key_pressed(.S) || mb.is_gamepad_pressed(.FACE_DOWN) {
			scale_index = (scale_index + 1) % len(scales)
			scene_dirty = true
		}
		if mb.is_key_pressed(.F) || mb.is_gamepad_pressed(.FACE_LEFT) do fit_index = (fit_index + 1) % len(fits)
		if mb.is_key_pressed(.P) || mb.is_gamepad_pressed(.FACE_RIGHT) {
			filter = .LINEAR if filter == .POINT else .POINT
			scene_dirty = true
		}

		// The first 360 frames walk through the three sizes, one after another, and print what each cost
		if frame > 3 && bench_frame < 3 * BENCH_FRAMES {
			bench_time += delta_time
			if (frame - 3) % BENCH_FRAMES == 0 {
				step := bench_frame / BENCH_FRAMES
				size := mb.get_internal_resolution() if internal else [2]i32{scene.width, scene.height}
				bench_lines[step] = fmt.aprintf("%.2f: %dx%d = %d px, %.1f ms", scales[step], size.x, size.y, size.x * size.y, bench_time / BENCH_FRAMES * 1000)
				mb.print("render-target-check: bench", bench_lines[step])
				bench_time = 0
				if step < 2 {
					scale_index = step + 1
					scene_dirty = true
				}
			}
			bench_frame += 1
		}

		// Between frames: a new size or filter remakes the target, and the internal resolution follows the same settings
		if scene_dirty {
			scene_dirty = false
			mb.destroy(&scene)
			scene = mb.create_render_target({scale = scales[scale_index], filter = filter})
		}
		if internal do mb.set_internal_resolution({scale = scales[scale_index], filter = filter, fit = fits[fit_index]})
		else do mb.set_internal_resolution()

		mb.walk_third_person_camera(&third, &player, SPEED, delta_time)
		player.x = clamp(player.x, -19, 19)
		player.z = clamp(player.z, -19, 19)

		mb.render_start()

		// Every target first, then the screen
		if frame == 1 do draw_probe(&probe)
		if internal == false do draw_minimap(&minimap, f32(frame % 60) / 60 - 0.5)
		if frame == 2 {
			check_probe(probe, minimap, &checks)
			mb.print(fmt.tprintf("render-target-check: %d passed, %d failed %s", checks.passed, checks.failed, checks.first_failure))
		}

		if internal == false do mb.render_target_start(&scene, [4]f32{0.15, 0.17, 0.22, 1})
		else do mb.clear_background({0.15, 0.17, 0.22, 1})
		mb.camera_start(third.camera)
		mb.render_model(floor, [3]f32{0, 0, 0}, tint = {0.4, 0.4, 0.45, 1})
		mb.render_model(character, mb.create_transform(player + {0, 0.85, 0}), {1, 0.9, 0.3, 1})
		marker.position = {-4, 1.5, 0}
		mb.render_billboard(marker, {mode = .CAMERA_PLANE})
		marker.position = {0, 1.5, 0}
		mb.render_billboard(marker, {mode = .CAMERA_POSITION})
		marker.position = {4, 1.5, 0}
		mb.render_billboard(marker)
		for position in ([?][3]f32{{-6, 0, -5}, {6, 0, -5}}) {
			tree.position = position
			mb.render_billboard(tree)
		}
		mb.camera_end()
		if internal == false {
			mb.render_target_end()
			mb.clear_background({0, 0, 0, 1})
			mb.render_upscaled_target(scene, fits[fit_index])
		}

		// The HUD: after the upscale it is in screen pixels (crisp); in internal mode it is inside the picture
		lines := [?]string {
			fmt.tprintf("checks: %d passed, %d failed", checks.passed, checks.failed),
			checks.first_failure,
			fmt.tprintf("%s %v %v", "internal" if internal else "target", fits[fit_index], filter),
			bench_lines[0],
			bench_lines[1],
			bench_lines[2],
		}
		mb.screen_start()
		visible_min, visible_max := mb.calculate_visible_rectangle()
		margin :f32 = 0.2
		baseline := visible_max.y - margin - font.ascent / font.pixels_per_unit
		for line in lines {
			mb.render_text(font, line, {visible_min.x + margin, baseline, 0})
			baseline -= mb.calculate_line_height(font)
		}
		if internal == false {
			minimap_sprite.position = mb.calculate_anchor_position(.TOP_RIGHT, {-1.4, -1.4})
			mb.render_sprite(minimap_sprite)
		}
		mb.screen_end()

		mb.render_end()
	}

	mb.destroy(&scene)
	mb.destroy(&minimap)
	mb.destroy(&probe)
	mb.destroy(floor)
	mb.destroy(character)
	mb.destroy_font(font)
	mb.destroy_sprite(marker)
	mb.destroy_sprite(tree)
	mb.cleanup()
}
