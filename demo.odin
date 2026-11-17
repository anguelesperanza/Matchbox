package demo
import mb "matchbox"

import "core:fmt"

main :: proc() {
	mb.init("Demo Window", 400, 400)

	// TODO
	jump_sound:mb.Audio = mb.load_audio(filepath = "path-to-audio")

	mb.print("Hello", "World", 10)
	mb.print(fmt.tprintf("%v", 1.5))


	camera := mb.Camera {
		position = {0, 0, 3},
		target = {0, 0, 0},
		up = {0, 1, 0},
		fov_y = 60,
		near = 0.1,
		far = 100,
		projection = .PERSPECTIVE,
	}

	// camera := mb.create_camera_2d(3)
	camera.fov_y = 90
	
	cube_vertices, cube_indices := mb.mesh_cube()
	cube := mb.create_mesh(cube_vertices, cube_indices) // pass args as pointers to free inside create_mesh?
	cat := mb.create_texture("meme_cat.png")


	quad_vertices, quad_indices := mb.mesh_quad()
	quad := mb.create_mesh(quad_vertices, quad_indices)
	delete(cube_vertices)
	delete(cube_indices)

	angle:f32

	for mb.is_running() {
		dt := mb.get_delta_time()

		mb.poll_events()
		if mb.is_key_pressed(.ESCAPE) || mb.is_gamepad_pressed(.SELECT) {
			mb.stop_running()
		}

		if mb.is_key_pressed(.SPACE) || mb.is_gamepad_pressed(.FACE_DOWN) {
			mb.play_audio(audio = jump_sound) // TODO
		}

		angle += dt



		mb.render_start()
		mb.clear_background(color = {0, 0.4, 0.6, 1})


			mb.camera_start(camera)

			near_quad := mb.create_model_matrix(position = {0, 0, 0.8}, scale = {1.8, 1.8, 1})
			mb.render_mesh(quad, near_quad, {1, 1, 1, 0.5}, .ALPHA, .NONE)

			far_quad := mb.create_model_matrix(position = {0.3, 0.3, -0.8}, scale = {1.8, 1.8, 1})
			mb.render_mesh(quad, far_quad, {1, 0.4, 0.4, 0.5}, .ALPHA, .NONE)

			spin := mb.create_model_matrix(rotation = mb.create_rotation_euler(pitch = angle * 0.5, yaw = angle))
			mb.render_mesh(cube, spin, texture = cat)

			mb.camera_end()

		mb.render_end()
	}

	mb.destroy(cat)
	mb.destroy_mesh(quad)
	mb.destroy_mesh(cube)
	mb.destroy(jump_sound) // TODO: Audio not implemeted yet

	mb.cleanup()
}
