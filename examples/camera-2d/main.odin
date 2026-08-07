package camera2d

import "../../matchbox"

main :: proc () {
	matchbox.init("2D Camera", 1280, 720)

	desperado := matchbox.create_sprite(#load("assets/images/desperado.png"), 10)

	desperado.speed = 50
	desperado.velocity = {10, 10}

	sheriff := matchbox.create_sprite(#load("assets/images/sheriff.png"), 10)
	sheriff.position = {1000, 0}


	for matchbox.mbi.running {

		matchbox.poll_events()

		if matchbox.is_key_held(.D) {
			desperado.position.x += desperado.velocity.x * desperado.speed * matchbox.mbi.delta_time
		}
		if matchbox.is_key_held(.A) {
			desperado.position.x -= desperado.velocity.x * desperado.speed * matchbox.mbi.delta_time
		}
		if matchbox.is_key_held(.S) {
			desperado.position.y += desperado.velocity.y * desperado.speed * matchbox.mbi.delta_time
		}
		if matchbox.is_key_held(.W) {
			desperado.position.y -= desperado.velocity.y * desperado.speed * matchbox.mbi.delta_time
		}

		matchbox.mbi.camera.position = matchbox.sprite_center(desperado)

		matchbox.begin_drawing()
		matchbox.clear_background(matchbox.LIME_GREEN)

			matchbox.begin_drawing_2d(&matchbox.mbi.camera)
				matchbox.draw_sprite(sheriff)
				matchbox.draw_sprite(desperado)
			matchbox.end_drawing_2d(&matchbox.mbi.camera)

			matchbox.draw_text(&matchbox.mbi.font, "Text is here", 10, 20, matchbox.WHITE)

		matchbox.end_drawing()
	}


	matchbox.destroy_sprite(&desperado)
	matchbox.destroy_sprite(&sheriff)
	matchbox.wait_idle()
	matchbox.cleanup()
}
