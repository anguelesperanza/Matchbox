package camera2d

import "../../../matchbox"

main :: proc () {
	mbi := matchbox.init("2D Camera", 1280, 720)

	desperado := matchbox.create_sprite(&mbi, #load("assets/images/desperado.png"), 10)

	desperado.speed = 50
	desperado.velocity = {10, 10}

	sheriff := matchbox.create_sprite(&mbi, #load("assets/images/sheriff.png"), 10)
	sheriff.position = {1000, 0}


	for mbi.running {

		if matchbox.is_key_down(&mbi, .D) {
			desperado.position.x += desperado.velocity.x * desperado.speed * mbi.delta_time
		}
		if matchbox.is_key_down(&mbi, .A) {
			desperado.position.x -= desperado.velocity.x * desperado.speed * mbi.delta_time
		}
		if matchbox.is_key_down(&mbi, .S) {
			desperado.position.y += desperado.velocity.y * desperado.speed * mbi.delta_time
		}
		if matchbox.is_key_down(&mbi, .W) {
			desperado.position.y -= desperado.velocity.y * desperado.speed * mbi.delta_time
		}

		mbi.camera.position = matchbox.sprite_center(desperado)

		matchbox.begin_drawing(&mbi)
		matchbox.clear_background(&mbi, matchbox.LIME_GREEN)

			matchbox.begin_drawing_2d(&mbi.camera)
				matchbox.draw_sprite(&mbi,sheriff)
				matchbox.draw_sprite(&mbi,desperado)
			matchbox.end_drawing_2d(&mbi.camera)

			matchbox.draw_text(&mbi, &mbi.font, "Text is here", 10, 20, matchbox.WHITE)

		matchbox.end_drawing(&mbi)
	}


	matchbox.destroy_sprite(&mbi, &desperado)
	matchbox.destroy_sprite(&mbi, &sheriff)
	matchbox.wait_idle()
	matchbox.cleanup(&mbi)
}
