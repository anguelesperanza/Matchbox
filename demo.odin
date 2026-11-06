package demo
import mb "matchbox"

main :: proc() {
	mb.init("Demo Window", 1920, 1080) // works

	// WIP -- Want to pass pixel positions as parameters -- Need projection mapping working
	triangle:mb.Triangle = mb.create_triangle({5, 10})

	// TODO	
	player:mb.Sprite = mb.create_sprite(filename = "toyota.png")
	player.x = 10
	player.y = 10
	player.speed = 100


	meme:mb.Sprite = mb.create_sprite(filename = "cat_transparent.png")

	// TODO
	jump_sound:mb.Audio = mb.load_audio(filepath = "path-to-audio")

	mb.print("Hello", "World", 10)

	mb.set_mouse_capture() // Works but commented out during testing
	// size := mb.get_window_size() // WIP -- Works on windows but 3DS has second screen to account for

	for mb.is_running() { // Works
		mb.poll_events() // Works

		// Works -- might change as based on win32 approach but odin d3d11 examples repo I reference has a different approach
		dt := mb.get_delta_time()
		
		if mb.is_key_pressed(.ESCAPE) || mb.is_gamepad_pressed(.SELECT) {
			mb.stop_running()
		}
		
		if mb.is_key_held(.D) || mb.is_gamepad_held(.DPAD_RIGHT, 0) {
			player.x += dt * player.speed
		}
		
		if mb.is_key_held(.A) || mb.is_gamepad_held(.DPAD_LEFT, 0) {
			player.x -= dt * player.speed
		}
		
		if mb.is_key_held(.W) || mb.is_gamepad_held(.DPAD_UP, 0) {
			player.y -= dt * player.speed
		}
		
		if mb.is_key_held(.S) || mb.is_gamepad_held(.DPAD_DOWN, 0) {
			player.y += dt * player.speed
		}
		
		if mb.is_key_pressed(.SPACE) || mb.is_gamepad_pressed(.FACE_DOWN) {
			mb.play_audio(audio = jump_sound) // TODO
		}
		
		mouse_position := mb.get_mouse_position()
		mouse_wheel_value := mb.get_mouse_wheel_value()
		// Works
		
		mb.render_start()
		mb.clear_background(color = {0, 0.4, 0.6, 1})
		// mb.render_triangle(a = {100, 100}, b = {200, 300}, c = {50, 300}, color = {0.3, 0.6, 0.9, 1})
		// mb.render_triangle(a = {400, 100}, b = {500, 300}, c = {350, 300}, color = {0.5, 0.5, 0.5, 1})
		mb.render_sprite(sprite = player) // WIP -- Still more work to do for transparenet sprites
		mb.render_sprite(sprite = meme)
		mb.render_triangle(a = {400, 100}, b = {500, 300}, c = {350, 300}, color = {1, 0, 0, 0.5})
		// Works
		mb.render_end() 
	}

	mb.destroy(player) // Works
	mb.destroy(jump_sound) // TODO: Audio not implemeted yet

	mb.cleanup()
}
