package demo

/*
	Demo
	====
	This shows how to use the Matchbox API

	The actual implementation is in the `matchbox` folder

	Before the API Implementation this demo stands to scaffold what the API should look like
*/

import "core:log"
import mb "matchbox"

main :: proc() {

	mb.init("Demo Window", 200, 200)

	context.logger = mb.get_logger()
	
	player:mb.Sprite = mb.create_sprite(filepath = "path-to-sprite")
	player.x = 50
	player.y = 50
	player.speed = 100

	jump_sound:mb.Audio = mb.load_audio(filepath = "path-to-audio")
	

	for mb.is_running() {
		mb.poll_events()

		if mb.is_key_pressed(.F) {
			log.info("F Pressed")
		}
		dt := mb.get_delta_time()

		if mb.is_key_pressed(.ESCAPE) {
			mb.stop_running()
		}

		if mb.is_key_held(.D) {
			player.x += dt * player.speed
		}

		if mb.is_key_pressed(.SPACE) {
			mb.play_audio(audio = jump_sound)
		}
		
		mb.render_start()
		mb.clear_background()

		mb.render_sprite(sprite = player)
		
		mb.render_end() 
	}


	mb.destroy(player)
	mb.destroy(jump_sound)

	mb.cleanup()
}
