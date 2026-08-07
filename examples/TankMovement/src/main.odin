package wip

import "../../../matchbox"

Tank :: struct {
	body:matchbox.Sprite,
	cannon:matchbox.Sprite,
	look_at_dest:[2]f32,
	rotation_speed:f32,
}

main :: proc() {
	mbi := matchbox.init("Tank", 1920, 1080)

	tank:Tank = {
		body = matchbox.create_sprite(&mbi, #load("assets/images/tank_body.png"), 20),
		cannon = matchbox.create_sprite(&mbi, #load("assets/images/tank_cannon.png"), 20),
	}

	tank.body.velocity = {5, 5}
	tank.body.speed = 70
	tank.rotation_speed = 2

	for mbi.running {

		matchbox.poll_events(&mbi)
		

		forward := matchbox.sprite_forward_by_rotation(tank.body)

		if matchbox.is_key_held(&mbi, .W) {
			tank.body.position += forward * tank.body.speed * mbi.delta_time
		}

		if matchbox.is_key_held(&mbi, .S) {
			tank.body.position -= forward * tank.body.speed * mbi.delta_time
		}

		if matchbox.is_key_held(&mbi, .A) {
			tank.body.rotation -= tank.rotation_speed * mbi.delta_time
		}

		if matchbox.is_key_held(&mbi, .D) {
			tank.body.rotation += tank.rotation_speed * mbi.delta_time
		}

		if matchbox.is_mouse_pressed(&mbi, .RIGHT) {
			tank.look_at_dest = {mbi.input.mouse.x, mbi.input.mouse.y}
			tank.cannon.rotation = matchbox.look_at(tank.cannon, tank.look_at_dest)
		}

		// Tie the tank's cannont position to the tank's body
		tank.cannon.position = tank.body.position

		matchbox.begin_drawing(&mbi)
		matchbox.clear_background(&mbi, matchbox.CORNFLOWER_BLUE)

		// Draw the tank as two seperate, overlapping sprite; body and cannon
		matchbox.draw_sprite(&mbi, tank.body)
		matchbox.draw_sprite(&mbi, tank.cannon)
		// matchbox.draw_sprite(&mbi, testgirl)
		matchbox.end_drawing(&mbi)
	}

	// matchbox.destroy_sprite(&mbi, &testgirl)
	matchbox.destroy_sprite(&mbi, &tank.body)
	matchbox.destroy_sprite(&mbi, &tank.cannon)
	matchbox.wait_idle()
	matchbox.cleanup(&mbi)
}
