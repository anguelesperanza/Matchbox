package pong


import "core:fmt"
import "core:strconv"
import "core:math/rand"
import "../../matchbox"

Ball :: struct {
	rect:matchbox.Rectangle,
	velocity:[2]f32,
	speed:f32,
}

Paddle :: struct {
	rect:matchbox.Rectangle,
	velocity:f32,
	speed:f32,
	score:i64,
}

ball_collide_wall :: proc(ball:Ball, wall_height:i32) -> [2]f32 {
	final_velocity:[2]f32 = ball.velocity
	if ball.rect.position.y - (ball.rect.size.y / 2) < 0 {
		final_velocity.y = abs(ball.velocity.y)
	}

	if ball.rect.position.y + (ball.rect.size.y / 2) > cast(f32)wall_height {
		final_velocity.y = -abs(ball.velocity.y)
	}

	return final_velocity
}

ball_collide_paddle :: proc(ball: Ball, player, enemy: Paddle) -> [2]f32 {
    final_velocity := ball.velocity

    ball_left   := ball.rect.position.x - (ball.rect.size.x / 2)
    ball_top    := ball.rect.position.y - (ball.rect.size.y / 2)
    ball_bottom := ball.rect.position.y + (ball.rect.size.y / 2)

    paddle_right  := player.rect.position.x + (player.rect.size.x / 2)
    paddle_top    := player.rect.position.y - (player.rect.size.y / 2)
    paddle_bottom := player.rect.position.y + (player.rect.size.y / 2)

    e_paddle_left  := enemy.rect.position.x - (enemy.rect.size.x / 2)
    e_paddle_top    := enemy.rect.position.y - (enemy.rect.size.y / 2)
    e_paddle_bottom := enemy.rect.position.y + (enemy.rect.size.y / 2)

    // Check if ball is vertically within the paddle's range
    if ball_bottom >= paddle_top && ball_top <= paddle_bottom {
        // Check if ball's left edge has reached or passed the paddle's right edge
        if ball_left <= paddle_right {
            final_velocity.x = abs(ball.velocity.x) // force ball to move right
        }
    }
    // Check if ball is vertically within the enemy paddle's range
    if ball_bottom >= e_paddle_top && ball_top <= e_paddle_bottom {
        // Check if ball's left edge has reached or passed the paddle's right edge
        if ball_left >= e_paddle_left {
            final_velocity.x = -abs(ball.velocity.x) // force ball to move right
        }
    }

    return final_velocity
}

main :: proc() {
	win_width:i32 = 1080
	win_height:i32 = 720

	matchbox.init("Pong", win_width, win_height)
	// Paddle bounds and ball collisions are all in terms of win_width/win_height,
	// so pin the resolution and let the window letterbox it.
	matchbox.set_logical_size(win_width, win_height)

	player:Paddle = {
		rect = {
			position = {20, cast(f32)win_height / 2},
			size = {16, 100},
			color = {.28, .28, .28, 1},
		},
		velocity = 5,
		speed = 100
	}

	enemy:Paddle = {
		rect = {
			position = {cast(f32)win_width - 30, cast(f32)win_height / 2},
			size = {16, 100},
			color = {.38, .38, .38, 1},
		},
		velocity = 5,
		speed = 60,
	}
	
	ball:Ball = {
		rect = {
			position = {cast(f32)win_width / 2, cast(f32)win_height / 2},
			size = {20, 20},
			color = {0.3, 0.5,0.7, 1}
		},
		speed = 75,
	}

	font := matchbox.load_font(#load("new_hiscore.ttf"), 64)
	

	start_dir := rand.int_range(0, 2)
	if start_dir == 0 {ball.velocity.x = -5} else {ball.velocity.x = 5}
	start_dir = rand.int_range(0, 2)
	if start_dir == 0 {ball.velocity.y = -5} else {ball.velocity.y = 5}

	for matchbox.is_running() {

		matchbox.poll_events()
		

		if matchbox.is_key_held(.W) {
			player.rect.position.y -= player.velocity * player.speed * matchbox.get_delta_time()
		}
		if matchbox.is_key_held(.S) {
			player.rect.position.y += player.velocity * player.speed * matchbox.get_delta_time()
		}

		if player.rect.position.y - (player.rect.size.y / 2) < 0 do player.rect.position.y = 0 + (player.rect.size.y / 2)
		if player.rect.position.y + (player.rect.size.y / 2) > cast(f32)win_height do player.rect.position.y = cast(f32)win_height - (player.rect.size.y / 2) 

		ball.rect.position.x += ball.velocity.x * ball.speed * matchbox.get_delta_time()
		ball.rect.position.y += ball.velocity.y * ball.speed * matchbox.get_delta_time()

		ball.velocity = ball_collide_wall(ball, win_height)
		ball.velocity = ball_collide_paddle(ball, player, enemy)

		// Ball off left screen, reset position
		if ball.rect.position.x + (ball.rect.size.x / 2) < 0 {
			ball.rect.position = {cast(f32)win_width / 2, cast(f32)win_height / 2}
			enemy.score += 1
			ball.velocity = {}
			start_dir = rand.int_range(0, 2)
			if start_dir == 0 {ball.velocity.x = -5} else {ball.velocity.x = 5}
			start_dir = rand.int_range(0, 2)
			if start_dir == 0 {ball.velocity.y = -5} else {ball.velocity.y = 5}
		}
		// ball off right screen, reset position
		if ball.rect.position.x + (ball.rect.size.x / 2) > cast(f32)win_width {
			ball.rect.position = {cast(f32)win_width / 2, cast(f32)win_height / 2}
			player.score += 1
			ball.velocity = {}
			start_dir = rand.int_range(0, 2)
			if start_dir == 0 {ball.velocity.x = -5} else {ball.velocity.x = 5}
			start_dir = rand.int_range(0, 2)
			if start_dir == 0 {ball.velocity.y = -5} else {ball.velocity.y = 5}
		}


		if ball.rect.position.y > enemy.rect.position.y do enemy.velocity = 5
		if ball.rect.position.y < enemy.rect.position.y do enemy.velocity = -5

		enemy.rect.position.y += enemy.velocity * enemy.speed * matchbox.get_delta_time()

		player_buf:[4]u8
		enemy_buf:[4]u8


		matchbox.begin_drawing()
		matchbox.clear_background()
		matchbox.draw_text(&font, strconv.write_int(player_buf[:], player.score, 10), f32(win_width / 2 - 64), f32(win_height / 2), {1, 1, 1, 1})
		matchbox.draw_text(&font, strconv.write_int(player_buf[:], enemy.score, 10), f32(win_width / 2 + 64), f32(win_height / 2), {1, 1, 1, 1})
	
		matchbox.draw_rect(player.rect)
		matchbox.draw_rect(enemy.rect)
		matchbox.draw_rect(ball.rect)
		matchbox.end_drawing()
	}

	matchbox.destroy_font(&font)
	matchbox.wait_idle()
	matchbox.cleanup()
}
