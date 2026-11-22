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
	cat_texture := mb.load_texture("meme_cat.png", .POINT)

	// 16 image pixels per world unit, so a 64 pixel crop is 4 units wide
	face := mb.create_sprite(cat_texture, {0, 0, 0}, 16)
	face.source = {150, 150, 64, 64}

	// A small sprite drifting slowly, so it sits on fractional pixel positions
	mover := mb.create_sprite(cat_texture, {0, 0, 1}, 16)
	mover.source = {234, 234, 32, 32}

	// The shia sheet from tools/sheetpack. Its shia.meta gives 169 frames and 256 pixels per unit,
	// so a frame is 1 unit wide. Asking for 128 below makes it 2 units wide
	shia_texture := mb.load_texture("shia.png", .POINT)
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

	// The bottom screen: B (or Start) swaps to it, and its face swaps back
	back := corner

	// Text: baked at 32 pixels, and the HUD is 400 / 12 screen pixels to the unit, so the
	// glyphs are drawn at about the size they were baked at
	font := mb.create_font(mb.DEFAULT_FONT_BYTES, 32, f32(mb.get_window_size()[1]) / 12)

	scale := 4
	fractional := false
	menu_open := false // the bottom screen as a menu: the game's own state, not Matchbox's
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

		// The HUD follows the window: top left and bottom right
		corner.position = mb.calculate_anchor_position(.TOP_LEFT, {1.5, -1.5})
		middle.position = mb.calculate_anchor_position(.BOTTOM_RIGHT, {-1.5, 1.5})

		// B or Start opens and closes the menu. On PC it fills the window while open, and the
		// world comes back when it closes; on the 3DS it is on its own screen either way
		if mb.is_key_pressed(.B) || mb.is_gamepad_pressed(.START) do menu_open = menu_open == false
		mb.set_bottom_screen(.FULLSCREEN if menu_open else .HIDDEN)

		// The HUD gets the mouse first. A face under the mouse lights up, and a click on
		// one must not also move the world camera. With the menu filling the window, the world and HUD are not shown
		mouse_on_hud := mb.calculate_mouse_screen_position()
		corner_min, corner_max := mb.calculate_sprite_bounds(corner)
		middle_min, middle_max := mb.calculate_sprite_bounds(middle)
		over_corner := menu_open == false && mb.is_point_in_rectangle(mouse_on_hud, corner_min, corner_max)
		over_middle := menu_open == false && mb.is_point_in_rectangle(mouse_on_hud, middle_min, middle_max)

		// The bottom screen has its own mouse position, as touch would be on a 3DS
		back.position = mb.calculate_bottom_screen_anchor_position(.BOTTOM, {0, 2})
		mouse_on_bottom, on_bottom_screen := mb.calculate_mouse_bottom_screen_position()
		back_min, back_max := mb.calculate_sprite_bounds(back)
		over_back := on_bottom_screen == true && mb.is_point_in_rectangle(mouse_on_bottom, back_min, back_max)
		back.tint = {1, 0.6, 0.6, 1} if over_back else {1, 1, 1, 1}
		if over_back == true && mb.is_mouse_pressed(.LEFT) do menu_open = false

		corner.tint = {1, 0.6, 0.6, 1} if over_corner else {1, 1, 1, 1}
		middle.tint = {1, 0.6, 0.6, 1} if over_middle else {1, 1, 1, 1}

		// The bottom right face is a button: it flips shia
		if over_middle == true && mb.is_mouse_pressed(.LEFT) do shia.flip_x = shia.flip_x == false

		// Left click moves the camera there; it glides, so it sits on fractional positions.
		// Not when the click landed on the HUD
		if mb.is_mouse_pressed(.LEFT) && menu_open == false && over_corner == false && over_middle == false {
			follow_target = mb.calculate_mouse_world_position(camera)
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

		mover.position = {math.cos(angle * 0.3) * 2.5, math.sin(angle * 0.4) * 1.5, 1}

		mb.render_start()
		mb.clear_background(color = {0, 0, 0, 1})

			// Every pass, every frame. Matchbox drops what the target cannot show: on PC the menu
			// replaces the world while it is open; on the 3DS both screens always show
			mb.camera_start(camera)

			mb.render_sprite(face)
			mb.render_sprite(mover)
			mb.render_animated_sprite(shia)

			mb.camera_end()

			mb.screen_start()
			mb.render_sprite(corner)
			mb.render_sprite(middle)

			top_left := mb.calculate_anchor_position(.TOP_LEFT, {3, -0.3})
			mb.render_text_wrapped(font, "Text in the HUD. It wraps at a width in world units.", top_left, 7)
			mb.render_text(font, 1 / dt, mb.calculate_anchor_position(.BOTTOM_LEFT, {0.5, 0.5}), {1, 1, 0, 1}) // frames per second
			mb.screen_end()

			// The menu, laid out with anchors so it fits any shape
			mb.bottom_screen_start()
			mb.render_sprite(back)
			mb.render_text_wrapped(font, "The bottom screen. Click the face, or press B, to go back.", mb.calculate_bottom_screen_anchor_position(.TOP_LEFT, {1, -1}), 10)
			mb.bottom_screen_end()

		mb.render_end()
	}

	mb.destroy_texture(cat_texture)
	mb.destroy_animation_clip(sheet)
	mb.destroy_font(font)
	mb.destroy(jump_sound) // TODO: Audio not implemeted yet

	mb.cleanup()
}
