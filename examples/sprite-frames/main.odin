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

	// Sized from the clip, so the frame size is never written out here and cannot
	// drift from the art. `position` is the top-left: draw_animated_sprite adds
	// pivot * size, so a centred pivot draws half a frame right and down of it.
	coin := matchbox.create_animated_sprite_from_clip(clip, scale = 4)
	coin.position = {480 - coin.size.x, 240 - coin.size.y}

	// The first four frames, at a third of the speed. The bounds are first and
	// last, inclusive. A range is a view onto the same
	// texture -- no second upload -- which is how a walk, an idle and a jump come
	// off one sheet. Destroy the sheet only; the ranges share its texture.
	half := matchbox.animation_range(clip, 0, 3, 0.25)
	slow := matchbox.create_animated_sprite_from_clip(half, scale = 2)
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
			"whole sheet, frame", 60, 460, matchbox.WHITE)
		matchbox.draw_text(&matchbox.mbi.font,
			cast(i64)coin.current_frame, 340, 460, matchbox.WHITE)

		matchbox.draw_text(&matchbox.mbi.font,
			"range 0..3, frame", 500, 460, matchbox.WHITE)
		matchbox.draw_text(&matchbox.mbi.font,
			cast(i64)slow.current_frame, 780, 460, matchbox.WHITE)

		matchbox.end_drawing()
	}
}
