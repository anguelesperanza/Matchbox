package clickcoin

import "../../matchbox"
import "core:math/rand"

main :: proc() {
	matchbox.init("ClickyCoin", 1920, 1080)

	coin:matchbox.Rectangle = {
		position = {50, 50},
		size = {128, 128},
		color = matchbox.PUMPKIN_ORANGE,
		rotation = 0,
		pivot = {0.5, 0.5},
		
	}

	counter:i64 

	coin.position = {cast(f32)rand.int31_max(cast(i32)matchbox.mbi.width - cast(i32)coin.size.x),cast(f32)rand.int31_max(cast(i32)matchbox.mbi.height - cast(i32)coin.size.y)}
	
	for matchbox.is_running() {
		matchbox.poll_events()

		if matchbox.is_mouse_pressed(.LEFT) {
			if matchbox.mouse_over_rect(coin) {
				coin.position = {cast(f32)rand.int31_max(cast(i32)matchbox.mbi.width - cast(i32)coin.size.x),cast(f32)rand.int31_max(cast(i32)matchbox.mbi.height - cast(i32)coin.size.y)}
				counter += 1
			}
		}
		
		matchbox.begin_drawing()
		matchbox.clear_background(matchbox.BLACK)
		matchbox.draw_rect(coin)
		matchbox.draw_text(&matchbox.mbi.font, counter, 26, 26, matchbox.WHITE)
		matchbox.end_drawing()
	}
	matchbox.cleanup()
}
