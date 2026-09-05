package matchbox

/*
	2D animation -- the clock and the frame queries
	----------------------------------------------
	These run without a GPU: `update_animation` and everything that asks where
	a clip has got to touch only the numbers on the sprite, so a clip needs
	nothing but its grid and its frame time filled in.

	Most of these use a `seconds_per_frame` of 0.125 rather than a realistic
	one. It is exact in binary, so `accumulator / seconds_per_frame` lands on a
	whole number instead of a hair under it -- which keeps a float truncation
	from looking like a logic mistake when a step count comes out one short.
	The catch-up test below is the exception, and uses real frame times on
	purpose.
*/

import "core:testing"

@(private = "file")
test_clip :: proc(frame_count: i32, seconds_per_frame: f32 = 0.125) -> Animation_Clip {
	return Animation_Clip{
		cols              = frame_count,
		rows              = 1,
		frame_count       = frame_count,
		seconds_per_frame = seconds_per_frame,
	}
}

/*
	A clip authored faster than the game renders still plays at its own rate.

	This is the regression: advancing at most one frame per call meant a 60fps
	clip on a 30fps machine ran at half speed, and the accumulator kept the
	unspent remainder every frame and grew without bound.
*/
@(test)
test_clock_catches_up_at_a_low_frame_rate :: proc(t: ^testing.T) {
	sprite := create_animated_sprite_from_clip(test_clip(8, 1.0 / 60.0))

	advanced: i32
	for _ in 0 ..< 30 {
		update_animation(&sprite, 1.0 / 30.0)
		advanced += sprite.stepped
	}

	testing.expect_value(t, advanced, 60)
	testing.expect(t, sprite.accumulator < 1.0 / 60.0,
		"the accumulator kept time it never spent, which is the leak")
}

// A one-shot lands on its last frame, says so, and stays there however long
// it is updated afterwards.
@(test)
test_one_shot_stops_on_its_last_frame :: proc(t: ^testing.T) {
	sprite := create_animated_sprite_from_clip(test_clip(4), looping = false)

	for _ in 0 ..< 10 do update_animation(&sprite, 0.125)

	testing.expect(t, !sprite.playing, "a finished one-shot should clear playing")
	testing.expect_value(t, get_animation_frame(sprite), 3)

	update_animation(&sprite, 0.125)
	testing.expect_value(t, get_animation_frame(sprite), 3)
	testing.expect_value(t, sprite.stepped, 0)
}

/*
	A frame crossed in the middle of a multi-frame step still counts as passed.

	The case an equality test misses: stepping 0 -> 3 never *shows* frame 2, so
	anything hung off it -- a footstep, a hitbox -- would fire in the editor and
	not on a slower machine.
*/
@(test)
test_frame_passed_fires_for_a_frame_crossed_mid_step :: proc(t: ^testing.T) {
	sprite := create_animated_sprite_from_clip(test_clip(8))

	update_animation(&sprite, 0.375) // three frames at once

	testing.expect_value(t, sprite.stepped, 3)
	testing.expect_value(t, get_animation_frame(sprite), 3)

	testing.expect(t, is_animation_frame_passed(sprite, 2),
		"frame 2 was crossed but never shown, and must still count")
	testing.expect(t, is_animation_frame_passed(sprite, 1), "frame 1 was crossed")
	testing.expect(t, is_animation_frame_passed(sprite, 3), "frame 3 is where it landed")

	testing.expect(t, !is_animation_frame_passed(sprite, 0),
		"frame 0 was where the step began, not somewhere it crossed into")
	testing.expect(t, !is_animation_frame_passed(sprite, 4), "frame 4 is past where it landed")
}

// The span is the clip's, so a step that runs off the end wraps with it.
@(test)
test_frame_passed_wraps_past_the_end_of_a_loop :: proc(t: ^testing.T) {
	sprite := create_animated_sprite_from_clip(test_clip(8))

	update_animation(&sprite, 0.75)  // to frame 6
	testing.expect_value(t, get_animation_frame(sprite), 6)

	update_animation(&sprite, 0.375) // 7, 0, 1
	testing.expect_value(t, get_animation_frame(sprite), 1)

	testing.expect(t, is_animation_frame_passed(sprite, 7), "7 was crossed before the wrap")
	testing.expect(t, is_animation_frame_passed(sprite, 0), "0 was crossed by the wrap")
	testing.expect(t, is_animation_frame_passed(sprite, 1), "1 is where it landed")

	testing.expect(t, !is_animation_frame_passed(sprite, 6), "6 was the frame it started on")
	testing.expect(t, !is_animation_frame_passed(sprite, 5), "5 was not in the span")
}

// A step longer than the clip crossed everything, and says so without walking
// the span several times over.
@(test)
test_frame_passed_reports_all_when_a_step_covers_the_clip :: proc(t: ^testing.T) {
	sprite := create_animated_sprite_from_clip(test_clip(4))

	update_animation(&sprite, 1.25) // ten frames of a four frame clip

	testing.expect(t, sprite.stepped >= 4, "the step should have covered the clip")
	for frame in i32(0) ..< 4 {
		testing.expect(t, is_animation_frame_passed(sprite, frame),
			"every frame of the clip was crossed")
	}
	testing.expect(t, !is_animation_frame_passed(sprite, 4), "there is no frame 4")
}

/*
	The queries count from the clip, not from the sheet.

	Where an absolute-versus-relative mistake shows up: this range starts at
	frame 8, so a game asking for "frame 2 of the attack" and a query answering
	"cell 10 of the sheet" would disagree by exactly `frame_start` and only on
	clips cut out of the middle.
*/
@(test)
test_frame_queries_are_relative_to_a_cut_range :: proc(t: ^testing.T) {
	sheet := Animation_Clip{cols = 4, rows = 4, frame_count = 16, seconds_per_frame = 0.125}
	sprite := create_animated_sprite_from_clip(animation_range(sheet, 8, 11))

	testing.expect_value(t, sprite.current_frame, 8)
	testing.expect_value(t, get_animation_frame(sprite), 0)

	update_animation(&sprite, 0.25) // two frames on

	testing.expect_value(t, sprite.current_frame, 10)
	testing.expect_value(t, get_animation_frame(sprite), 2)

	testing.expect(t, is_animation_in_window(sprite, 1, 3), "frame 2 is inside 1..=3")
	testing.expect(t, is_animation_in_window(sprite, 2, 2), "a window of one frame counts")
	testing.expect(t, !is_animation_in_window(sprite, 0, 1), "frame 2 is past 0..=1")
	testing.expect(t, !is_animation_in_window(sprite, 3, 1), "last before first is empty")

	testing.expect(t, is_animation_frame_passed(sprite, 2),
		"the span is relative to the clip as well")
}

// Progress runs 0 to 1 across the clip and counts the part-frame, so it climbs
// steadily rather than jumping a quarter at a time.
@(test)
test_progress_at_start_middle_and_end :: proc(t: ^testing.T) {
	sprite := create_animated_sprite_from_clip(test_clip(4), looping = false)

	testing.expect_value(t, get_animation_progress(sprite), 0)

	update_animation(&sprite, 0.25) // frame 2 of 4, nothing in the accumulator
	testing.expect_value(t, get_animation_progress(sprite), 0.5)

	// Half a frame further on, which is an eighth of a four frame clip.
	update_animation(&sprite, 0.0625)
	mid := get_animation_progress(sprite)
	testing.expect(t, mid > 0.5 && mid < 0.75,
		"the part-frame should move progress between one frame and the next")

	for _ in 0 ..< 10 do update_animation(&sprite, 0.125)
	testing.expect(t, !sprite.playing, "the one-shot should have finished")
	testing.expect_value(t, get_animation_progress(sprite), 1)
}
