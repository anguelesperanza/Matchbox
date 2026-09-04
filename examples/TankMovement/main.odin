package wip

import "../../matchbox"

Tank :: struct {
	body:matchbox.Sprite,
	cannon:matchbox.Sprite,
	look_at_dest:[2]f32,
	rotation_speed:f32,
}

main :: proc() {
	matchbox.init("Tank", 1920, 1080)

	body, body_err := matchbox.create_sprite(#load("assets/images/tank_body.png"), 20)
	if body_err != nil do return

	cannon, cannon_err := matchbox.create_sprite(#load("assets/images/tank_cannon.png"), 20)
	if cannon_err != nil do return

	tank:Tank = {
		body = body,
		cannon = cannon,
	}

	tank.body.velocity = {5, 5}
	tank.body.speed = 70
	tank.rotation_speed = 2

	for matchbox.is_running() {

		matchbox.poll_events()
		

		forward := matchbox.sprite_forward_by_rotation(tank.body)

		if matchbox.is_key_held(.W) {
			tank.body.position += forward * tank.body.speed * matchbox.get_delta_time()
		}

		if matchbox.is_key_held(.S) {
			tank.body.position -= forward * tank.body.speed * matchbox.get_delta_time()
		}

		if matchbox.is_key_held(.A) {
			tank.body.rotation -= tank.rotation_speed * matchbox.get_delta_time()
		}

		if matchbox.is_key_held(.D) {
			tank.body.rotation += tank.rotation_speed * matchbox.get_delta_time()
		}

		if matchbox.is_mouse_pressed(.RIGHT) {
			tank.look_at_dest = matchbox.get_mouse_position()
			tank.cannon.rotation = matchbox.look_at(tank.cannon, tank.look_at_dest)
		}

		// Tie the tank's cannont position to the tank's body
		tank.cannon.position = tank.body.position

		matchbox.begin_drawing()
		matchbox.clear_background(matchbox.CORNFLOWER_BLUE)

		// Draw the tank as two seperate, overlapping sprite; body and cannon
		matchbox.draw_sprite(tank.body)
		matchbox.draw_sprite(tank.cannon)
		// matchbox.draw_sprite(testgirl)
		matchbox.end_drawing()
	}

	// matchbox.destroy_sprite(&testgirl)
	matchbox.destroy_sprite(&tank.body)
	matchbox.destroy_sprite(&tank.cannon)
	matchbox.wait_idle()
	matchbox.cleanup()
}
