package animation_chain

/*
	A sequence of clips that hands itself on, and the questions a game asks
	about where playback has got to.

	SPACE starts the chain, R replays whatever clip is showing, ESC quits.

	**Nothing in the loop below advances the chain.** The three clips are lined
	up once, when SPACE is pressed, and after that the only animation call per
	frame is `update_animation`. Watch "queued" fall from 2 to 0 on its own:
	that number is the proof, because the game never touches it.

	This is what `queue_animation` is for. The alternative -- and what a game
	writes without it -- is a phase enum and a transition per stage:

		if !player.playing {
			switch player.phase {
			case .WIND_UP: player.phase = .SPIN;   switch_animation(p, spin)
			case .SPIN:    player.phase = .SETTLE; switch_animation(p, settle)
			case .SETTLE:
			}
		}

	That enum is not game logic. It encodes "which clip comes after which",
	which is a property of the animation and belongs with it. A jump made of
	three clips grows a Jump_Phase; a guard made of two grows a Guard_Phase;
	and each one is a place for the sequence and the state to drift apart.

	The three clips here are ranges cut from one eight-frame coin sheet, so
	the chain needs no art of its own -- see `sprite-frames` for what
	`animation_range` is and why the ranges share the sheet's texture.
*/

import "core:fmt"

import "../../matchbox"

// The frames of the current clip that count as its "active window", the shape
// a fighting game's cancel window has. Inclusive at both ends, and relative to
// the clip rather than to the sheet -- so it means the same thing whichever
// stage of the chain is playing, even though they start at different cells.
WINDOW_FIRST :: 1
WINDOW_LAST  :: 2

// The frame whose crossing is counted below. Frame 1 rather than 0 on purpose:
// seating a clip is not crossing into its first frame, so a one-shot would
// never report frame 0 at all.
MARKED_FRAME :: 1

BG      :: [4]f32{0.09, 0.09, 0.11, 1}
BAR_BG  :: [4]f32{0.20, 0.20, 0.26, 1}
PANEL   :: [4]f32{0.16, 0.16, 0.20, 1}

/*
	Starts the chain from the top, whatever is playing when it is called.

	The three lines below look like one line's work and are not, and the reason
	is worth following, because it is the whole distinction between the verbs.

	`switch_animation` is idempotent: asked for the clip already playing it
	does nothing, which is what lets a state machine call it every frame. So
	pressing SPACE during the *first* stage takes that branch -- the chain
	would not restart, and the queue would not be cleared either, so the two
	`queue_animation` calls below would stack a second copy behind the first
	until the queue filled up.

	`clear_animation_queue` handles the queue half; `replay_animation` handles
	the restart half, and is the verb that exists precisely because
	`switch_animation` will not restart the clip in hand.
*/
start_chain :: proc(coin: ^matchbox.Animated_Sprite, wind_up, spin, settle: matchbox.Animation_Clip) {
	matchbox.clear_animation_queue(coin)
	matchbox.switch_animation(coin, wind_up, looping = false)
	matchbox.replay_animation(coin)

	// `looping` has no default here, deliberately: a queued clip is usually a
	// one-shot handing on to the next, while switch_animation's default is
	// true. Saying it costs a word and cannot be got wrong invisibly.
	matchbox.queue_animation(coin, spin,   false)

	// The last of a chain is the one that loops. Only a clip that *finishes*
	// pulls the next one, so anything queued behind this would never be
	// reached -- a loop has no end to fire on.
	matchbox.queue_animation(coin, settle, true)
}

main :: proc() {
	matchbox.init("Animation Chain", 960, 540)
	defer matchbox.cleanup()

	// Without this, a frame that failed to decode would be logged nowhere.
	context.logger = matchbox.mbi.logger

	sheet, err := matchbox.load_animation_directory(#load_directory("assets"), 0.12)
	if err != nil do return
	defer matchbox.destroy_animation_clip(&sheet)

	// Three stages out of the one sheet, each at its own pace. Destroy the
	// sheet only -- the ranges are views onto its texture.
	wind_up := matchbox.animation_range(sheet, 0, 2, 0.16)
	spin    := matchbox.animation_range(sheet, 3, 5, 0.06)
	settle  := matchbox.animation_range(sheet, 6, 7, 0.20)

	coin := matchbox.create_animated_sprite_from_clip(wind_up, scale = 6)
	coin.position = {150, 150}

	start_chain(&coin, wind_up, spin, settle)

	// The game's own bookkeeping, and all of it is presentation: how many times
	// the marked frame has been crossed. Nothing here drives the animation.
	crossings := 0

	font := &matchbox.mbi.font

	for matchbox.is_running() {
		matchbox.poll_events()
		if matchbox.is_key_pressed(.ESCAPE) do matchbox.mbi.running = false

		if matchbox.is_key_pressed(.SPACE) {
			start_chain(&coin, wind_up, spin, settle)
			crossings = 0
		}

		// Retriggering the clip already playing. switch_animation cannot do
		// this -- asking it for the clip in hand does nothing, which is what
		// lets a state machine call it every frame -- so replaying is its own
		// verb. The queue is left alone: replaying is not abandoning what was
		// lined up behind.
		if matchbox.is_key_pressed(.R) do matchbox.replay_animation(&coin)

		matchbox.update_animation(&coin, matchbox.get_delta_time())

		/*
			Asked once per update, right after it.

			Not `get_animation_frame(coin) == MARKED_FRAME`: one update can
			advance several frames when the game renders slower than the clip
			was drawn, and an update that steps from 0 to 2 never *shows*
			frame 1. An equality test would miss the crossing, and miss it
			more often the worse the frame rate got -- reliable while you are
			looking at it and unreliable on the machine that matters.
		*/
		if matchbox.is_animation_frame_passed(coin, MARKED_FRAME) do crossings += 1

		in_window := matchbox.is_animation_in_window(coin, WINDOW_FIRST, WINDOW_LAST)

		matchbox.begin_drawing()
		matchbox.clear_background(BG)

		// The window indicator sits behind the coin, so "inside the window" is
		// a state of the thing rather than a light somewhere else on screen.
		matchbox.draw_rect({
			position = {110, 110},
			size     = {coin.size.x + 80, coin.size.y + 80},
			color    = matchbox.PUMPKIN_ORANGE if in_window else PANEL,
			pivot    = {0.5, 0.5},
		})

		matchbox.draw_animated_sprite(coin)

		// ---- progress, as a bar ------------------------------------------
		//
		// get_animation_progress counts the part-frame sitting in the
		// accumulator, so this slides rather than stepping between frames.
		// get_animation_frame is the one to ask when the frame number itself
		// is the answer -- as the readout below does.
		progress := matchbox.get_animation_progress(coin)

		matchbox.draw_rect({position = {520, 150}, size = {360, 26},
		                    color = BAR_BG, pivot = {0.5, 0.5}})
		matchbox.draw_rect({position = {520, 150}, size = {360 * progress, 26},
		                    color = matchbox.LIME_GREEN, pivot = {0.5, 0.5}})

		// ---- the readout --------------------------------------------------
		matchbox.draw_text(font, "one chain, three clips", 520, 100, matchbox.WHITE)

		matchbox.draw_text(font,
			fmt.tprintf("frame %v of %v", matchbox.get_animation_frame(coin), coin.clip.frame_count),
			520, 220, matchbox.WHITE)

		matchbox.draw_text(font,
			fmt.tprintf("progress %.2f", progress), 520, 260, matchbox.WHITE)

		// Falls 2 -> 1 -> 0 with nothing in this loop touching it. That is the
		// whole point of the example.
		matchbox.draw_text(font,
			fmt.tprintf("queued %v", coin.queue_len), 520, 300, matchbox.WHITE)

		matchbox.draw_text(font,
			fmt.tprintf("frame %v crossed %v times", MARKED_FRAME, crossings),
			520, 340, matchbox.WHITE)

		matchbox.draw_text(font,
			fmt.tprintf("window %v..%v: %v", WINDOW_FIRST, WINDOW_LAST, in_window),
			520, 380, matchbox.PUMPKIN_ORANGE if in_window else matchbox.LIGHTGRAY)

		matchbox.draw_text(font, "SPACE restarts the chain", 520, 450, matchbox.LIGHTGRAY)
		matchbox.draw_text(font, "R replays the current clip", 520, 480, matchbox.LIGHTGRAY)

		matchbox.end_drawing()
	}
}
