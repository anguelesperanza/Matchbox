package model_check

/*
	G1's check: models through a perspective camera. Run from the repository root (the assets are
	the shared ones in assets/), on PC with `odin run examples/model-check`; on the handhelds with
	`3ds_build.bat examples\model-check` / `vita_build.bat examples\model-check` once they read
	models.

	test_crate.glb is loaded from assets/models, which git ignores (assets are the game's own).
	`python tools/make_test_model.py` writes it there, beside the tracked copy the tests read in
	tools/testdata/models.

	What should show, left to right on a grey floor (create_plane_model):
	- a cube (create_cube_model), tinted blue
	- test_crate.glb, turning: an orange/white checkered crate with a red square standing
	  above it, half its size. The square is double-sided, so it shows from behind too
	- a sphere (create_sphere_model), tinted green
	- a cylinder (create_cylinder_model), tinted yellow
	A HUD line names the model and its size from calculate_model_size. SELECT or Escape quits
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
	font := mb.create_font(mb.DEFAULT_FONT_BYTES, 32)

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
	for mb.is_running() {
		mb.poll_events()
		if mb.is_key_pressed(.ESCAPE) || mb.is_gamepad_pressed(.SELECT) do mb.stop_running()
		time += mb.get_delta_time()

		mb.render_start()
		mb.clear_background({0.15, 0.17, 0.22, 1})

		mb.camera_start(camera)
		// All three forms of the render_model group: a position, a pivot and a transform, a transform.
		// The positions are typed because they have to be: an untyped {x, y, z} also fits a Transform,
		// and Odin stops the build as ambiguous (see render_model)
		mb.render_model(floor, [3]f32{0, -0.5, 0}, tint = {0.4, 0.4, 0.45, 1})
		mb.render_model(cube, [3]f32{-3, 0, 0}, tint = {0.4, 0.6, 1, 1})
		turning := mb.create_transform({-1, 0, 0}, mb.calculate_rotation_axis_angle({0, 1, 0}, time))
		mb.render_model(crate, mb.calculate_model_center(crate), turning)
		mb.render_model(sphere, [3]f32{1.2, 0, 0}, tint = {0.4, 1, 0.5, 1})
		mb.render_model(cylinder, mb.create_transform({3, 0, 0}, mb.calculate_rotation_axis_angle({0, 0, 1}, math.sin(time) * 0.5)), {1, 0.9, 0.3, 1})
		mb.camera_end()

		mb.screen_start()
		size := mb.calculate_model_size(crate)
		label := fmt.tprintf("test_crate.glb: %v parts, size %.2f x %.2f x %.2f", len(crate.parts), size.x, size.y, size.z)
		mb.render_text(font, label, mb.calculate_anchor_position(.TOP_LEFT, {0.3, -0.6}))
		mb.screen_end()

		mb.render_end()
	}

	mb.destroy(crate)
	mb.destroy(cube)
	mb.destroy(sphere)
	mb.destroy(cylinder)
	mb.destroy(floor)
	mb.destroy_font(font)
	mb.cleanup()
}
