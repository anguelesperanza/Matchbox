package demo

/*
	Demo
	====
	This shows how to use the Matchbox API

	The actual implementation is in the `matchbox` folder

	Before the API Implementation this demo stands to scaffold what the API should look like
*/

import mb "matchbox"

main :: proc() {

	mb.init("Demo Window", 600, 600) // works

	// WIP -- Want to pass pixel positions as parameters -- Need projection mapping working
	triangle:mb.Triangle = mb.create_triangle({5, 10})

	// TODO	
	player:mb.Sprite = mb.create_sprite(filepath = "path-to-sprite")
	player.x = 50
	player.y = 50
	player.speed = 100

	// TODO
	jump_sound:mb.Audio = mb.load_audio(filepath = "path-to-audio")

	mb.print("Hello", "World", 10)


	for mb.is_running() { // Works
		mb.poll_events() // Works


		// Works
		dt := mb.get_delta_time()
		
		// Works
		if mb.is_key_pressed(.F) || mb.is_gamepad_pressed(.FACE_UP,0 ) {
		}

		// Works
		if mb.is_key_pressed(.ESCAPE) || mb.is_gamepad_pressed(.SELECT) {
			mb.stop_running()
		}

		// TODO -- works but may need tweaking on PC side
		if mb.is_key_held(.S) || mb.is_gamepad_pressed(.DPAD_LEFT, 0) {
			player.x += dt * player.speed
		}
		
		if mb.is_key_pressed(.SPACE) || mb.is_gamepad_pressed(.FACE_DOWN) {
			mb.play_audio(audio = jump_sound) // TODO
		}

		if mb.is_mouse_pressed(.LEFT) {
			mb.print("Left Mouse Pressed")
		}

		if mb.is_mouse_pressed(.RIGHT) {
			mb.print("Right Mouse Print")
		}

		if mb.is_mouse_pressed(.MIDDLE) {
			mb.print("Middle Mouse Pressed")
		}

		if mb.is_mouse_pressed(.SIDE_1) {
			mb.print("Side 1 Mouse Pressed")
		}
		
		if mb.is_mouse_pressed(.SIDE_2) {
			mb.print("Side 2 Mouse Pressed")
		}

		if mb.is_key_held(.J) {
			// mb.print("J is held")
		}

		if mb.is_key_released(.J) {
			mb.print("J released")
		}


		mouse_position := mb.get_mouse_position()
		mouse_wheel_value := mb.get_mouse_wheel_value()
		
		left_trigger_value := mb.get_trigger_value(trigger = .LEFT_TRIGGER)
		right_trigger_value := mb.get_trigger_value(trigger = .RIGHT_TRIGGER)

		if left_trigger_value > 0 do mb.stop_running()

		left_thumb := mb.get_thumbstick_value(.LEFT_THUMBSTICK)
		right_thumb := mb.get_thumbstick_value(.RIGHT_THUMBSTICK)

		// Works
		mb.render_start()
		mb.clear_background(color = {0, 0.4, 0.6, 1})
		mb.render_triangle(a = {-0.8, 0.2}, b = {-0.4, -0.4}, c = {-1.0, -0.4}, color = {0.3, 0.6, 0.9, 1})
		mb.render_triangle(a = {0.5, 0.6}, b = {0.9, -0.1}, c = {0.1, -0.1}, color = {0.5, 0.5, 0.5, 1})

		mb.render_sprite(sprite = player) // TODO

		// Works
		mb.render_end() 
	}

	// TODO -- stubbed | sprites and audio are not implemented yet; 
	mb.destroy(player)
	mb.destroy(jump_sound)

	// Works
	mb.cleanup()
}
