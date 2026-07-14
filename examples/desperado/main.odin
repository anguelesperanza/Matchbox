package desperado

import "core:time"
import "../../matchbox"

Entity :: struct {
	sprite:matchbox.Sprite,
	fire_time:i64,
	fired:bool,
}

Timer :: struct {
	timer:matchbox.CooldownTimer,
	state:bool,
	fire:bool,
}

GRAVITY :: 2

main :: proc() {
	mbi := matchbox.init("Desperado Vs. Sheriff", 1280, 720)

	player:Entity
	player.sprite = matchbox.create_sprite(&mbi, #load("./assets/images/desperado.png"), 20)
	player.sprite.velocity = {10, 100}
	player.sprite.speed = 25
	player.sprite.jump_force = 1000

	sheriff:Entity
	sheriff.sprite = matchbox.create_sprite(&mbi, #load("./assets/images/sheriff.png"), 20)
	sheriff.sprite.flip_x = true
	sheriff.sprite.position.x = cast(f32)mbi.width - sheriff.sprite.size.x
	sheriff.sprite.velocity = {10, 200}
	sheriff.sprite.speed = 25
	sheriff.sprite.jump_force = 1000

	pg:matchbox.Sprite
	pg = matchbox.create_sprite(&mbi, #load("./assets/images/gun.png"), 10)
	pg.rotation = 90
	sg:matchbox.Sprite
	sg = matchbox.create_sprite(&mbi, #load("./assets/images/gun.png"), 10)
	sg.rotation = 45
	sg.flip_y = true

	timer:Timer
	matchbox.start_cooldown(&timer.timer, 3)

	for mbi.running {

		matchbox.poll_events(&mbi)
		
		matchbox.begin_drawing(&mbi)
		matchbox.clear_background(&mbi, matchbox.PUMPKIN_ORANGE)

		// Keyboard input
		if matchbox.is_key_pressed(&mbi, .F) {
			if timer.fire && player.fired == false {
				player.fired = true
				player.fire_time = time.now()._nsec
			}
		}
		if matchbox.is_key_pressed(&mbi, .J) {
			if timer.fire && sheriff.fired == false {
				sheriff.fired = true
				sheriff.fire_time = time.now()._nsec
			}
		}

		pg.position = player.sprite.position
		pg.position.y += 50

		sg.position = sheriff.sprite.position
		sg.position.y += 50

		matchbox.update_cooldown(&timer.timer, mbi.delta_time)

		// check who shot first
		if player.fire_time > sheriff.fire_time {
			player.sprite.rotation = 0
		}
		if player.fire_time < sheriff.fire_time {
			sheriff.sprite.rotation = 0
		}
		if player.fire_time == sheriff.fire_time && player.fire_time != 0{
			sheriff.sprite.rotation = 0
			player.sprite.rotation = 0
		}

		matchbox.draw_sprite(&mbi, player.sprite)
		matchbox.draw_sprite(&mbi, sheriff.sprite)
		matchbox.draw_sprite(&mbi, pg)
		matchbox.draw_sprite(&mbi, sg)

		if matchbox.is_cooldown_done(timer.timer) {
			matchbox.draw_text(&mbi, &mbi.font, "FIRE!!!!", cast(f32)mbi.width / 2, cast(f32)mbi.height / 2, matchbox.BLACK)
		} else {
			matchbox.draw_text(&mbi, &mbi.font, cast(i64)timer.timer.remaining, cast(f32)mbi.width / 2, cast(f32)mbi.height / 2, matchbox.BLACK)
		}

		matchbox.end_drawing(&mbi)
	}

	matchbox.destroy_font(&mbi, &mbi.font)
	matchbox.destroy_sprite(&mbi, &pg)
	matchbox.destroy_sprite(&mbi, &sg)
	matchbox.destroy_sprite(&mbi, &player.sprite)
	matchbox.destroy_sprite(&mbi, &sheriff.sprite)
	matchbox.wait_idle()
	matchbox.cleanup(&mbi)
}
