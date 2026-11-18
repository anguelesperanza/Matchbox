package demo
import mb "matchbox"

import "core:fmt"
import "core:math"

main :: proc() {
	mb.init("Demo Window", 800, 800)

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

	// The shia sheet from tools/sheetpack. Its shia.meta gives 169 frames and 256 pixels per unit,
	// so a frame is 1 unit wide. Asking for 128 below makes it 2 units wide
	shia_texture := mb.create_texture("shia.png", .POINT)
	sheet := mb.create_animation_clip(shia_texture, 0.1)

	// Frame numbers from shia-test's anim_list.txt
	idle := mb.animation_range(sheet, 67, 74)
	walk := mb.animation_range(sheet, 95, 106)
	run := mb.animation_range(sheet, 113, 118, 0.07)
	attack := mb.animation_range(sheet, 0, 5)

	shia := mb.create_animated_sprite_from_clip(idle, 1, true, 128)
	shia.position = {2, -1.5, 2}

	// HUD: 12 units tall at 16 pixels per unit, pinned to the corners of whatever shape the window is
	corner := mb.create_sprite(cat_texture, {}, 16)
	corner.source = {150, 150, 32, 32}
	middle := corner

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

		// 1 idle, 2 walk, 3 run: switching every frame is safe, it only restarts on a change
		if mb.is_key_pressed(._1) do mb.switch_animation(&shia, idle)
		if mb.is_key_pressed(._2) do mb.switch_animation(&shia, walk)
		if mb.is_key_pressed(._3) do mb.switch_animation(&shia, run)

		// 4 plays the attack once, then goes back to idle by itself
		if mb.is_key_pressed(._4) {
			mb.switch_animation(&shia, attack, looping = false)
			mb.queue_animation(&shia, idle, true)
		}

		// F flips, P pauses
		if mb.is_key_pressed(.F) do shia.flip_x = shia.flip_x == false
		if mb.is_key_pressed(.P) do shia.playing = shia.playing == false

		mb.update_animation(&shia, dt)

		// Frames 1 to 3 of the attack are its "cancel window"
		if mb.is_animation_in_window(shia, 1, 3) && shia.clip.frame_start == attack.frame_start {
			shia.tint = {1, 0.6, 0.6, 1}
		} else {
			shia.tint = {1, 1, 1, 1}
		}

		// The HUD follows the window: top left, bottom right and top centre
		corner.position = mb.anchor_position(.TOP_LEFT, {1.5, -1.5})
		middle.position = mb.anchor_position(.BOTTOM_RIGHT, {-1.5, 1.5})

		mover.position = {math.cos(angle * 0.3) * 2.5, math.sin(angle * 0.4) * 1.5, 1}

		mb.render_start()
		mb.clear_background(color = {0, 0.4, 0.6, 1})

			mb.camera_start(camera)

			mb.render_sprite(face)
			mb.render_sprite(mover)
			mb.render_animated_sprite(shia)

			mb.camera_end()

			mb.screen_start()
			mb.render_sprite(corner)
			mb.render_sprite(middle)
			mb.screen_end()

		mb.render_end()
	}

	mb.destroy_texture(cat_texture)
	mb.destroy_animation_clip(sheet)
	mb.destroy(jump_sound) // TODO: Audio not implemeted yet

	mb.cleanup()
}
