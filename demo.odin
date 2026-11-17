package demo
import mb "matchbox"

import "core:fmt"
import "core:math"

main :: proc() {
	mb.init("Demo Window", 400, 400)

	// TODO
	jump_sound:mb.Audio = mb.load_audio(filepath = "path-to-audio")

	mb.print("Hello", "World", 10)
	mb.print(fmt.tprintf("%v", 1.5))

	camera := mb.create_camera_2d(6)
	camera.pixel_snap = true

	// POINT = hard pixels, the filter for pixel art
	cat_texture := mb.create_texture("meme_cat.png", .POINT)

	// 16 image pixels per world unit, so a 64 pixel crop is 4 units wide
	face := mb.create_sprite(cat_texture, {0, 0, 0}, 16)
	face.source = {150, 150, 64, 64}

	// A small sprite drifting slowly, so it sits on fractional pixel positions
	mover := mb.create_sprite(cat_texture, {0, 0, 1}, 16)
	mover.source = {234, 234, 32, 32}

	scale := 4
	fractional := false
	follow_target := [2]f32{0, 0}
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

		if mb.is_key_pressed(.TAB) do camera.pixel_snap = camera.pixel_snap == false
		if mb.is_key_pressed(.Q) do fractional = fractional == false

		// Wheel changes the whole-number scale (screen pixels per image pixel)
		wheel := mb.get_mouse_wheel_value()
		if wheel > 0 do scale += 1
		if wheel < 0 do scale -= 1
		scale = clamp(scale, 1, 8)

		pixel_scale := f32(scale)
		if fractional == true do pixel_scale += 0.5
		mb.camera_set_pixel_scale(&camera, 16, pixel_scale, f32(mb.get_window_size()[1]))

		// Left click moves the camera there; it glides, so it sits on fractional positions
		if mb.is_mouse_pressed(.LEFT) {
			follow_target = mb.get_mouse_world_pos(camera)
		}
		mb.camera_follow(&camera, follow_target, 3, dt)

		mover.position = {math.cos(angle * 0.3) * 2.5, math.sin(angle * 0.4) * 1.5, 1}

		mb.render_start()
		mb.clear_background(color = {0, 0.4, 0.6, 1})

			mb.camera_start(camera)

			mb.render_sprite(face)
			mb.render_sprite(mover)

			mb.camera_end()

		mb.render_end()
	}

	mb.destroy_texture(cat_texture)
	mb.destroy(jump_sound) // TODO: Audio not implemeted yet

	mb.cleanup()
}
