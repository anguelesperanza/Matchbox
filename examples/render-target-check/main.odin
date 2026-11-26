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
BENCH_STEPS :: 4 // the scene straight to the screen, then through a target at each of the three sizes
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

/*
	A picture that is not a power of two (20 x 12 sits in the 3DS's 32 x 16 canvas), drawn green over a magenta clear,
	then drawn as a sprite into a second target of the same size, which was cleared blue. Every pixel of the copy
	should be green: magenta in it is the source's padding being sampled, blue is the picture not being sampled at all.
	It goes through the GPU twice, so it finds a wrong placement or uv rectangle that reading the memory back cannot
*/
SAMPLE_WIDTH :: 20
SAMPLE_HEIGHT :: 12

Sample_Pair :: struct {
	source:mb.Render_Target,
	copy:mb.Render_Target,
	sprite:mb.Sprite,
}

create_sample_pair :: proc(filter:mb.Filter_Mode) -> (pair:Sample_Pair) {
	pair.source = mb.create_render_target({width = SAMPLE_WIDTH, height = SAMPLE_HEIGHT, filter = filter})
	pair.copy = mb.create_render_target({width = SAMPLE_WIDTH, height = SAMPLE_HEIGHT})
	pair.sprite = mb.create_sprite(pair.source.texture)
	pair.sprite.pixels_per_unit = 1
	return
}

destroy_sample_pair :: proc(pair:^Sample_Pair) {
	// Not destroy_sprite: it frees the texture, which belongs to the target. Freeing it twice corrupted the heap
	// and killed the real 3DS in malloc a few seconds later (Azahar does not notice)
	mb.destroy(&pair.copy)
	mb.destroy(&pair.source)
}

draw_sample :: proc(pair:^Sample_Pair) {
	mb.render_target_start(&pair.source, [4]f32{1, 0, 1, 1})
	mb.camera_start(mb.create_camera_2d(SAMPLE_HEIGHT))
	mb.render_rectangle({0, 0, -5}, {SAMPLE_WIDTH, SAMPLE_HEIGHT}, {0, 1, 0, 1})
	mb.camera_end()
	mb.render_target_end()

	mb.render_target_start(&pair.copy, [4]f32{0, 0, 1, 1})
	mb.camera_start(mb.create_screen_camera(SAMPLE_HEIGHT))
	mb.render_sprite(pair.sprite)
	mb.camera_end()
	mb.render_target_end()
}

// Counts the copy's pixels that are not green, and where they are, so the HUD says which edge went wrong
check_sample :: proc(pair:Sample_Pair, name:string, result:^Check_Result) -> string {
	pixels := mb.read_render_target_pixels(pair.copy)
	defer delete(pixels)
	bad, top, bottom, left, right, worst := 0, 0, 0, 0, 0, 0
	for y in 0 ..< SAMPLE_HEIGHT {
		for x in 0 ..< SAMPLE_WIDTH {
			got := pixel(pixels, SAMPLE_WIDTH, x, y)
			// Off by how much from green: rounding in the GPU's filter is a unit or two, the padding's magenta is hundreds
			deviation := abs(int(got.r)) + abs(int(got.g) - 255) + abs(int(got.b)) + abs(int(got.a) - 255)
			worst = max(worst, deviation)
			if deviation <= 3 do continue
			bad += 1
			if y < SAMPLE_HEIGHT / 2 do top += 1
			else do bottom += 1
			if x < SAMPLE_WIDTH / 2 do left += 1
			else do right += 1
		}
	}
	check(result, bad == 0, fmt.tprintf("sampling %s", name))
	// Short: every glyph is a draw on the 3DS, and a screenful of text overflowed its command buffer
	return fmt.aprintf("%d t%d b%d l%d r%d d%d", bad, top, bottom, left, right, worst)
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

	sample_point := create_sample_pair(.POINT)
	sample_linear := create_sample_pair(.LINEAR)
	sample_lines:[2]string

	scales := SCALES
	fits := FITS
	scale_index := 0
	fit_index := 0 // FIT: no bars at full size, and the smaller sizes fill the screen. INTEGER (index 1) leaves bars by design
	filter := mb.Filter_Mode.POINT
	internal := false
	scene := mb.create_render_target({scale = scales[scale_index], filter = filter})
	scene_dirty := false

	checks:Check_Result
	bench_lines:[BENCH_STEPS]string
	bench_gpu, bench_cpu:f32
	direct := true // the benchmark starts with the scene drawn straight to the screen, as a game with no target would
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

		// The first four steps: the scene drawn straight to the screen, then through a target at each of the three sizes.
		// Each line is the frame time, then the GPU's and the CPU's share of it as citro3d counts them (3DS only)
		gpu_times := mb.get_gpu_times()
		if frame > 3 && bench_frame < BENCH_STEPS * BENCH_FRAMES {
			bench_time += delta_time
			bench_cpu += gpu_times[0]
			bench_gpu += gpu_times[1]
			if (frame - 3) % BENCH_FRAMES == 0 {
				step := bench_frame / BENCH_FRAMES
				size := [2]i32{scene.width, scene.height}
				if internal do size = mb.get_internal_resolution()
				if direct {
					window := mb.get_window_size()
					size = {window[0], window[1]}
				}
				name := "direct" if direct else fmt.tprintf("%.2f", scales[scale_index])
				bench_lines[step] = fmt.aprintf("%s %dx%d %.1fms g%.1f c%.1f", name, size.x, size.y, bench_time / BENCH_FRAMES * 1000, bench_gpu / BENCH_FRAMES, bench_cpu / BENCH_FRAMES)
				bench_time, bench_gpu, bench_cpu = 0, 0, 0
				if direct {
					direct = false
					scale_index = 0
				} else if step < BENCH_STEPS - 1 {
					scale_index = step // step 1 is scale 0 done, next is scale 1
					scene_dirty = true
				}
			}
			bench_frame += 1
		}

		// Between frames (a target made or freed inside one crashes the 3DS): the sample pairs, read at frame 2, are given
		// back so the benchmark below has their VRAM
		if frame == 3 {
			destroy_sample_pair(&sample_point)
			destroy_sample_pair(&sample_linear)
		}

		// A new size or filter remakes the target, and the internal resolution follows the same settings
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
		if frame == 1 {
			draw_probe(&probe)
			draw_sample(&sample_point)
			draw_sample(&sample_linear)
		}
		if internal == false do draw_minimap(&minimap, f32(frame % 60) / 60 - 0.5)
		if frame == 2 {
			check_probe(probe, minimap, &checks)
			sample_lines[0] = check_sample(sample_point, "POINT", &checks)
			sample_lines[1] = check_sample(sample_linear, "LINEAR", &checks)
			mb.print(fmt.tprintf("render-target-check: %d passed, %d failed %s", checks.passed, checks.failed, checks.first_failure))
		}

		use_target := internal == false && direct == false
		if use_target do mb.render_target_start(&scene, [4]f32{0.15, 0.17, 0.22, 1})
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
		if use_target {
			mb.render_target_end()
			mb.clear_background({0, 0, 0, 1})
			mb.render_upscaled_target(scene, fits[fit_index])
		}

		// Where the picture lands and how big it is, so a photo of the screen shows what the code intended
		rectangle_line := ""
		{
			shown := mb.Render_Target{width = mb.get_internal_resolution().x, height = mb.get_internal_resolution().y} if internal else scene
			top_left, bottom_right := mb.calculate_upscaled_rectangle(shown, fits[fit_index])
			rectangle_line = fmt.tprintf("%dx%d %.0f,%.0f-%.0f,%.0f", shown.width, shown.height, top_left.x, top_left.y, bottom_right.x, bottom_right.y)
		}

		// The HUD: after the upscale it is in screen pixels (crisp); in internal mode it is inside the picture
		lines := [?]string {
			fmt.tprintf("checks: %d passed, %d failed", checks.passed, checks.failed),
			checks.first_failure,
			fmt.tprintf("%s %v %v", "internal" if internal else "target", fits[fit_index], filter),
			fmt.tprintf("sample P %s L %s", sample_lines[0], sample_lines[1]),
			rectangle_line,
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
