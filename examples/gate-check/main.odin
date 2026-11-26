package gate_check

/*
	The Phase B and C gate scene, which render_plan.md asked for and nothing had built: a textured cube that spins, and a half-transparent
	quad passing through it. Run from the repository root: `odin run examples/gate-check` on PC, or
	`3ds_build.bat examples\gate-check` / `vita_build.bat examples\gate-check`.

	On the second frame it checks the scene by numbers. The scene is drawn four times into four small targets, with the quad
	in four places: absent, in front of the cube, through its middle and behind it. Each picture is read back and these are asserted:
	- the cube's front face shows its four texels in their places: red top left, green top right, magenta bottom left, yellow
	  bottom right (the texture is the right way up and not mirrored)
	- the quad is see-through: where it covers the background the blue is lightened, neither left alone nor replaced by white
	- the quad in front lightens the cube's texels too
	- the quad behind the cube, or through its middle, leaves the cube's texels exactly as they were, and still lightens the
	  background (the depth test hides the part of it the cube covers, and a blended draw does not write depth)
	The numbers are compared with each other, not with fixed colours, because PC blends in linear light and writes sRGB while the
	handhelds blend the stored values: half white over blue is about (188, 188, 255) on PC and (128, 128, 255) on a handheld. Both
	read as "lightened, not replaced" here.
	It prints "gate-check: N passed, M failed" and shows it on the HUD (the billboard-check pattern).

	What should show: the cube turning, its four coloured quarters on every face, and a white half-see-through square sliding
	back and forth through it: in front of the cube it washes the cube out, inside the cube the cube's faces stay solid, behind it
	only the background is washed. Resizing the PC window keeps the picture's shape. SELECT or Escape quits.
*/

import "core:fmt"
import "core:math"
import mb "../../matchbox"

PROBE_SIZE :: 64

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

Scene :: struct {
	texture:mb.Texture,
	cube:mb.Model,
	quad:mb.Model,
	camera:mb.Camera,
}

create_scene :: proc() -> (scene:Scene) {
	// Four quarters of 4 x 4 texels on an 8 x 8 picture: the smallest the 3DS takes. POINT so every texel is exact
	pixels:[8 * 8][4]u8
	for &pixel, index in pixels {
		x := index % 8
		y := index / 8
		switch {
		case y < 4 && x < 4: pixel = {255, 0, 0, 255} // top left: red
		case y < 4:          pixel = {0, 255, 0, 255} // top right: green
		case x < 4:          pixel = {255, 0, 255, 255} // bottom left: magenta
		case:                pixel = {255, 255, 0, 255} // bottom right: yellow
		}
	}
	scene.texture = mb.create_texture_from_pixels(&pixels, 8, 8, .POINT)
	scene.cube = mb.create_cube_model(2)
	scene.cube.parts[0].texture = scene.texture
	scene.quad = mb.create_plane_model(10)
	scene.quad.parts[0].blend = .ALPHA
	scene.quad.parts[0].cull = .NONE
	scene.camera = mb.Camera {
		position = {0, 0, 6},
		target = {0, 0, 0},
		up = {0, 1, 0},
		fov_y = 50,
		near = 0.1,
		far = 100,
		zoom = 1,
		projection = .PERSPECTIVE,
	}
	return
}

// The camera, the cube turned by `angle` about Y, and the quad (when `quad_z` is given) stood up facing the camera at that depth
draw_scene :: proc(scene:Scene, angle:f32, quad_z:Maybe(f32)) {
	mb.camera_start(scene.camera)
	mb.render_model(scene.cube, mb.create_transform({0, 0, 0}, mb.calculate_rotation_axis_angle({0, 1, 0}, angle)))
	if z, ok := quad_z.?; ok {
		upright := mb.calculate_rotation_axis_angle({1, 0, 0}, math.PI / 2)
		mb.render_model(scene.quad, mb.create_transform({0, 0, z}, upright), {1, 1, 1, 0.5})
	}
	mb.camera_end()
}

// Where the four probes put the quad: none, in front of the cube, through its middle, behind it
QUAD_DEPTHS :: [4]Maybe(f32){nil, 2.5, 0, -2.5}

pixel :: proc(pixels:[]u8, x, y:int) -> [4]int {
	offset := (y * PROBE_SIZE + x) * 4
	return {int(pixels[offset]), int(pixels[offset + 1]), int(pixels[offset + 2]), int(pixels[offset + 3])}
}

// How far apart two pixels are, as the biggest channel difference
distance :: proc(a, b:[4]int) -> int {
	return max(abs(a.r - b.r), abs(a.g - b.g), abs(a.b - b.b))
}

run_checks :: proc(targets:^[4]mb.Render_Target) -> (result:Check_Result) {
	// The front face of the cube is 27 pixels wide at the centre of the 64 pixel picture: 18 to 46. The probes sit in its quarters
	// and in the corner, which the cube never reaches
	spots := [?][2]int{{25, 25}, {39, 25}, {25, 39}, {39, 39}, {4, 4}}
	got:[4][5][4]int
	for index in 0 ..< 4 {
		pixels := mb.read_render_target_pixels(targets[index], context.temp_allocator)
		if len(pixels) != PROBE_SIZE * PROBE_SIZE * 4 {
			check(&result, false, "the probe could not be read back")
			return
		}
		for spot, spot_index in spots do got[index][spot_index] = pixel(pixels, spot.x, spot.y)
	}

	plain := got[0]
	check(&result, plain[0].r > 200 && plain[0].g < 60 && plain[0].b < 60, "cube top left is red")
	check(&result, plain[1].g > 200 && plain[1].r < 60 && plain[1].b < 60, "cube top right is green")
	check(&result, plain[2].r > 200 && plain[2].b > 200 && plain[2].g < 60, "cube bottom left is magenta")
	check(&result, plain[3].r > 200 && plain[3].g > 200 && plain[3].b < 60, "cube bottom right is yellow")
	check(&result, plain[4].b > 200 && plain[4].r < 60 && plain[4].g < 60, "background is blue")

	for index in 1 ..< 4 {
		quad := got[index]
		names := [?]string{"", "in front", "through the middle", "behind"}
		name := names[index]
		// See-through: the blue background is lightened (red and green up) but not replaced by white (blue stays full and the
		// red stays below full). Half white over blue is 128 or 188 by the target, so the window is wide on purpose
		lightened := quad[4].r > 90 && quad[4].r < 215 && quad[4].g > 90 && quad[4].g < 215 && quad[4].b > 200
		check(&result, lightened, fmt.tprintf("quad %s lightens the background", name))
		if index == 1 {
			// In front: the red texel gets the white added: green and blue rise to the same middle, red stays full
			covered := quad[0].r > 200 && quad[0].g > 90 && quad[0].g < 215 && quad[0].b > 90 && quad[0].b < 215
			check(&result, covered, "quad in front lightens the cube's red texel")
			check(&result, distance(quad[4], got[3][4]) <= 3, "quad in front and behind lighten the background alike")
		} else {
			// Not in front: the cube hides it, so every texel is what it was without the quad
			same := true
			for spot_index in 0 ..< 4 do same &&= distance(quad[spot_index], plain[spot_index]) <= 3
			check(&result, same, fmt.tprintf("quad %s is hidden by the cube's depth", name))
		}
	}
	return
}

main :: proc() {
	mb.init("gate check", 960, 544)
	mb.set_lighting({enabled = false})
	font := mb.create_font(mb.DEFAULT_FONT_BYTES, 32)
	scene := create_scene()

	// Made now, not in a frame: creating a render target mid-frame killed the real 3DS in G5
	targets:[4]mb.Render_Target
	for &target in targets do target = mb.create_render_target({width = PROBE_SIZE, height = PROBE_SIZE})

	result:Check_Result
	time:f32 = 0
	frame := 0
	for mb.is_running() {
		mb.poll_events()
		if mb.is_key_pressed(.ESCAPE) || mb.is_gamepad_pressed(.SELECT) do mb.stop_running()
		time += mb.get_delta_time()
		frame += 1

		mb.render_start()
		// Every target first, then the screen
		if frame == 1 {
			depths := QUAD_DEPTHS
			for &target, index in targets {
				mb.render_target_start(&target, [4]f32{0, 0, 1, 1})
				draw_scene(scene, 0, depths[index])
				mb.render_target_end()
			}
		}
		if frame == 3 {
			result = run_checks(&targets)
			mb.print(fmt.tprintf("gate-check: %d passed, %d failed %s", result.passed, result.failed, result.first_failure))
		}

		mb.clear_background({0, 0, 1, 1})
		quad_z := 2.5 * math.sin(time)
		draw_scene(scene, time, quad_z)

		mb.screen_start()
		visible_min, visible_max := mb.calculate_visible_rectangle()
		margin :f32 = 0.2
		baseline := visible_max.y - margin - font.ascent / font.pixels_per_unit
		lines := [?]string {
			fmt.tprintf("checks: %d passed, %d failed", result.passed, result.failed),
			result.first_failure,
			fmt.tprintf("quad z %.1f", quad_z),
		}
		for line in lines {
			mb.render_text(font, line, {visible_min.x + margin, baseline, 0})
			baseline -= mb.calculate_line_height(font)
		}
		mb.screen_end()

		mb.render_end()
	}

	for &target in targets do mb.destroy(&target)
	mb.destroy(scene.cube)
	mb.destroy(scene.quad)
	mb.destroy(scene.texture)
	mb.destroy_font(font)
	mb.cleanup()
}
