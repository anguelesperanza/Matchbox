package model_check

/*
	G1's check, lit in G2 L4-6: models through a perspective camera, lit by one sun. Run from the
	repository root (the assets are the shared ones in assets/), on PC with
	`odin run examples/model-check`; on the handhelds with `3ds_build.bat examples\model-check` /
	`vita_build.bat examples\model-check`.

	test_crate.glb is loaded from assets/models, which git ignores (assets are the game's own).
	`python tools/make_test_model.py` writes it there, beside the tracked copy the tests read in
	tools/testdata/models.

	What should show, left to right on a grey floor (create_plane_model):
	- a cube (create_cube_model), tinted blue
	- test_crate.glb, turning: an orange/white checkered crate with a red square standing
	  above it, half its size. The square is double-sided, so it shows from behind too
	- a sphere (create_sphere_model), tinted green, with a highlight
	- a cylinder (create_cylinder_model), tinted yellow
	and behind them a white checkerboard standing upright with every other square cut out.

	The sun shines down from the right and from the camera's side, so tops are brightest, and
	the fronts and right-hand sides are lit alike. L, or the bottom face button (B on the 3DS,
	Cross on the Vita), switches lighting off and on: off, every model draws as it did before
	lighting existed, texture times tint. P, or the right face button (A on the 3DS, Circle on the Vita),
	switches two more lights off and on (G2 L8): a warm point light low between the cube and the crate, and a
	spot light from above on the cylinder. The sun stays. M, or the left face button (Y on the 3DS, Square on the
Vita), switches between lighting per pixel and per vertex.

	The checkerboard is the lit cut-out. A highlight has alpha 0 on every target, so the holes
	stay holes under the light (G2 L4-0); were it 1, the board would be a solid square lit grey.

	M, or the left face button (Y on the 3DS, Square on the Vita), cycles the scene's lighting
	mode between per pixel and per vertex (G2 L5-4). The sphere's material always asks for the
	other one, so every frame draws both pipelines side by side; the HUD names both modes.

	A HUD line names the crate and its size from calculate_model_size, one says whether
	lighting is on, and one names the modes. SELECT or Escape quits
*/

import "core:fmt"
import "core:math"
import mb "../../matchbox"

main :: proc() {
	mb.init("model check", 960, 544)

	crate := mb.load_model("test_crate.glb")
	cube := mb.create_cube_model()
	sphere := mb.create_sphere_model(0.5)
	cylinder := mb.create_cylinder_model(0.4, 1)
	floor := mb.create_plane_model(12)
	// A floor has no highlight to show, and strength 0 lets the Vita skip the specular work for every pixel of it, the most
	// expensive thing on screen (24 fps with the bulbs on at 0.5, 60 at 0)
	floor.parts[0].material = mb.Material{shininess = 16, specular_strength = 0}
	font := mb.create_font(mb.DEFAULT_FONT_BYTES, 32)

	// The cut-out: a plane stood upright, an 8 x 8 checkerboard whose dark squares are see-through.
	// Made in code because no test model has a MASK material yet. Point filtering keeps the
	// squares' edges sharp, so a hole is a hole and not a blend between the two
	holes:[8 * 8][4]u8
	for &pixel, index in holes {
		x := index % 8
		y := index / 8
		pixel = {255, 255, 255, 255} if (x + y) % 2 == 0 else {0, 0, 0, 0}
	}
	board_texture := mb.create_texture_from_pixels(&holes, 8, 8, .POINT)
	board := mb.create_plane_model(1.5)
	board.parts[0].texture = board_texture
	board.parts[0].alpha_cutoff = 0.5
	board.parts[0].cull = .NONE
	// The plane faces up; a quarter turn about X stands it up facing the camera (+Z)
	board_transform := mb.create_transform({0, 0.5, -1.5}, mb.calculate_rotation_axis_angle({1, 0, 0}, math.PI / 2))

	lighting_on := true
	scene_mode := mb.Lighting_Mode.PER_PIXEL
	bulbs_on := true
	bulbs := [2]mb.Light {
		mb.create_point_light({-2, 0.8, 1.5}, {1, 0.7, 0.4, 1}),
		mb.create_spot_light({3, 3.5, 1.5}, {0, -1, -0.3}, {1, 1, 1, 1}, 15, 30),
	}
	sun := mb.create_directional_light({-1, -2, -1})
	mb.set_lights({sun, bulbs[0], bulbs[1]})
	// The sphere always takes the other pipeline from the scene, so every frame mixes both
	apply_lighting :: proc(sphere:mb.Model, enabled:bool, mode:mb.Lighting_Mode) {
		mb.set_lighting({enabled = enabled, ambient = {0.2, 0.2, 0.2, 1}, mode = mode})
		sphere.parts[0].material.lighting = .PER_VERTEX if mode == .PER_PIXEL else .PER_PIXEL
	}
	apply_lighting(sphere, lighting_on, scene_mode)

	camera := mb.Camera {
		position = {0, 2.5, 6},
		target = {0, 0.5, 0},
		up = {0, 1, 0},
		fov_y = 50,
		near = 0.1,
		far = 100,
		zoom = 1,
		projection = .PERSPECTIVE,
	}

	time:f32 = 0
	fps:f32 = 0
	fps_time:f32 = 0
	fps_frames := 0
	for mb.is_running() {
		mb.poll_events()
		if mb.is_key_pressed(.ESCAPE) || mb.is_gamepad_pressed(.SELECT) do mb.stop_running()
		if mb.is_key_pressed(.L) || mb.is_gamepad_pressed(.FACE_DOWN) {
			lighting_on = !lighting_on
			apply_lighting(sphere, lighting_on, scene_mode)
		}
		// FACE_LEFT: Y on the 3DS, Square on the Vita
		if mb.is_key_pressed(.M) || mb.is_gamepad_pressed(.FACE_LEFT) {
			scene_mode = .PER_VERTEX if scene_mode == .PER_PIXEL else .PER_PIXEL
			apply_lighting(sphere, lighting_on, scene_mode)
		}
		if mb.is_key_pressed(.P) || mb.is_gamepad_pressed(.FACE_RIGHT) {
			bulbs_on = !bulbs_on
			if bulbs_on do mb.set_lights({sun, bulbs[0], bulbs[1]})
			else do mb.set_lights({sun})
		}
		time += mb.get_delta_time()

		mb.render_start()
		mb.clear_background({0.15, 0.17, 0.22, 1})

		mb.camera_start(camera)
		// All three forms of the render_model group: a position, a pivot and a transform, a transform.
		// The positions are typed because they have to be: an untyped {x, y, z} also fits a Transform,
		// and Odin stops the build as ambiguous (see render_model)
		mb.render_model(floor, [3]f32{0, -0.5, 0}, tint = {0.4, 0.4, 0.45, 1})
		mb.render_model(board, board_transform)
		mb.render_model(cube, [3]f32{-3, 0, 0}, tint = {0.4, 0.6, 1, 1})
		turning := mb.create_transform({-1, 0, 0}, mb.calculate_rotation_axis_angle({0, 1, 0}, time))
		mb.render_model(crate, mb.calculate_model_center(crate), turning)
		mb.render_model(sphere, [3]f32{1.2, 0, 0}, tint = {0.4, 1, 0.5, 1})
		mb.render_model(cylinder, mb.create_transform({3, 0, 0}, mb.calculate_rotation_axis_angle({0, 0, 1}, math.sin(time) * 0.5)), {1, 0.9, 0.3, 1})
		mb.camera_end()

		// Frame rate, smoothed over half a second so the digits can be read
		fps_time += mb.get_delta_time()
		fps_frames += 1
		if fps_time >= 0.5 {
			fps = f32(fps_frames) / fps_time
			fps_time = 0
			fps_frames = 0
		}

		size := mb.calculate_model_size(crate)
		// Short on purpose, measured with calculate_text_size against calculate_visible_rectangle: the longest is about 9
		// of the 19.6 units the 3DS's top screen gives (the narrowest target). The letters
		// are the PC keys; after the slash is the face button's place on the handhelds
		lines := [?]string {
			fmt.tprintf("crate %.2f x %.2f x %.2f", size.x, size.y, size.z),
			"lighting on [L / down]" if lighting_on else "lighting off [L / down]",
			"bulbs on [P / right]" if bulbs_on else "bulbs off [P / right]",
			"scene per vertex [M / left]" if scene_mode == .PER_VERTEX else "scene per pixel [M / left]",
			"sphere per vertex" if mb.get_lighting_mode(sphere.parts[0].material) == .PER_VERTEX else "sphere per pixel",
			fmt.tprintf("fps %.0f (%.1f ms)", fps, 1000 / max(fps, 0.001)),
		}

		mb.screen_start()
		visible_min, visible_max := mb.calculate_visible_rectangle()
		margin :f32 = 0.2
		// The cursor y of a line is its baseline, so the first sits one ascent below the top edge
		baseline := visible_max.y - margin - font.ascent / font.pixels_per_unit
		for line in lines {
			mb.render_text(font, line, {visible_min.x + margin, baseline, 0})
			baseline -= mb.calculate_line_height(font)
		}
		mb.screen_end()

		mb.render_end()
	}

	mb.destroy(crate)
	mb.destroy(cube)
	mb.destroy(sphere)
	mb.destroy(cylinder)
	mb.destroy(floor)
	mb.destroy(board)
	mb.destroy(board_texture)
	mb.destroy_font(font)
	mb.cleanup()
}
