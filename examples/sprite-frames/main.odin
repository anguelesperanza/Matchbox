package sprite_frames

import "../../matchbox"

main :: proc() {
	matchbox.init("Sprite Frames", 960, 540)
	defer matchbox.cleanup()

	// Without this, a frame that failed to decode would be logged nowhere.
	context.logger = matchbox.mbi.logger

	// A folder of separate files rather than one strip, which is what an exporter
	// that numbers its output gives you. `#load_directory` is a compile-time
	// builtin so the path has to be a literal written here; the result is a
	// local, because it is no more a constant than a slice literal is.
	//
	// load_animation_directory skips anything that is not an image and orders
	// what is left so that coin_10 would follow coin_9 rather than coin_1.
	// `load_animation_frames` is the explicit form when the frames are named
	// individually or come from more than one place.
	clip, ok := matchbox.load_animation_directory(#load_directory("assets"), 0.08)
	if !ok do return
	defer matchbox.destroy_animation_clip(&clip)

	// switch_animation sizes the sprite from the clip, so the frame size is not
	// written out here and cannot drift from the art.
	coin: matchbox.AnimatedSprite
	coin.scale = 4
	coin.pivot = {0.5, 0.5}
	coin.tint  = matchbox.WHITE
	matchbox.switch_animation(&coin, clip)
	coin.position = {480 - coin.size.x * 0.5, 240 - coin.size.y * 0.5}

	// The same clip on a second sprite, running at its own speed: a clip holds
	// the art, a sprite holds where it has got to.
	slow: matchbox.AnimatedSprite
	slow.scale = 2
	slow.pivot = {0.5, 0.5}
	slow.tint  = matchbox.WHITE
	matchbox.switch_animation(&slow, clip)
	slow.clip.seconds_per_frame = 0.25
	slow.position = {760, 400}

	for matchbox.is_running() {
		matchbox.poll_events()
		if matchbox.is_key_pressed(.ESCAPE) do matchbox.mbi.running = false

		dt := matchbox.delta_time()
		matchbox.update_animation(&coin, dt)
		matchbox.update_animation(&slow, dt)

		matchbox.begin_drawing()
		matchbox.clear_background(matchbox.CORNFLOWER_BLUE)

		matchbox.draw_animated_sprite(coin)
		matchbox.draw_animated_sprite(slow)

		matchbox.draw_text(&matchbox.mbi.font,
			"eight separate PNGs, packed into one sheet at load", 60, 80, matchbox.WHITE)
		matchbox.draw_text(&matchbox.mbi.font,
			"frame", 60, 460, matchbox.WHITE)
		matchbox.draw_text(&matchbox.mbi.font,
			cast(i64)coin.current_frame, 160, 460, matchbox.WHITE)

		matchbox.end_drawing()
	}
}
