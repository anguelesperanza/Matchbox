#+build windows

package matchbox

import "core:log"
import "core:testing"

// A sheet of 20 frames, no GPU needed: clips are only numbers
test_sheet :: proc() -> Animation_Clip {
	return create_animation_clip(Texture{frame_count = 20, columns = 5, rows = 4, pixels_per_unit = 1}, 0.1)
}

@(test)
range_is_inclusive_and_clamped :: proc(t:^testing.T) {
	sheet := test_sheet()

	r := animation_range(sheet, 3, 5)
	testing.expect_value(t, r.frame_start, 3)
	testing.expect_value(t, r.frame_count, 3)

	r = animation_range(sheet, 18, 99) // past the end
	testing.expect_value(t, r.frame_start, 18)
	testing.expect_value(t, r.frame_count, 2)

	r = animation_range(sheet, 7, 2) // last before first
	testing.expect_value(t, r.frame_start, 7)
	testing.expect_value(t, r.frame_count, 1)

	r = animation_range(sheet, 0, 3, 0.5)
	testing.expect_value(t, r.seconds_per_frame, 0.5)
	r = animation_range(sheet, 0, 3)
	testing.expect_value(t, r.seconds_per_frame, 0.1)
}

@(test)
starts_on_frame_start_not_zero :: proc(t:^testing.T) {
	clip := animation_range(test_sheet(), 6, 9)
	sprite := create_animated_sprite_from_clip(clip)
	testing.expect_value(t, sprite.frame, 6)
	testing.expect_value(t, sprite.playing, true)
}

@(test)
looping_wraps_inside_the_clip :: proc(t:^testing.T) {
	sprite := create_animated_sprite_from_clip(animation_range(test_sheet(), 6, 9))

	for _ in 0 ..< 3 do update_animation(&sprite, 0.1)
	testing.expect_value(t, sprite.frame, 9)
	update_animation(&sprite, 0.1)
	testing.expect_value(t, sprite.frame, 6) // back to the start of the clip, not frame 0
}

@(test)
big_step_keeps_the_rate :: proc(t:^testing.T) {
	sprite := create_animated_sprite_from_clip(animation_range(test_sheet(), 0, 3))
	update_animation(&sprite, 0.35) // 3 frames and a bit
	testing.expect_value(t, sprite.frame, 3)
	update_animation(&sprite, 0.06) // the leftover bit adds up to another whole frame
	testing.expect_value(t, sprite.frame, 0)
}

@(test)
one_shot_stops_on_last_frame :: proc(t:^testing.T) {
	sprite := create_animated_sprite_from_clip(animation_range(test_sheet(), 2, 4), 1, false)

	update_animation(&sprite, 100) // far more than the clip
	testing.expect_value(t, sprite.frame, 4)
	testing.expect_value(t, sprite.playing, false)

	update_animation(&sprite, 1)
	testing.expect_value(t, sprite.frame, 4) // stays
}

@(test)
queue_takes_over_when_one_shot_ends :: proc(t:^testing.T) {
	sheet := test_sheet()
	attack := animation_range(sheet, 0, 2)
	idle := animation_range(sheet, 10, 12)

	sprite := create_animated_sprite_from_clip(idle)
	switch_animation(&sprite, attack, looping = false)
	queue_animation(&sprite, idle, true)

	update_animation(&sprite, 0.1)
	testing.expect_value(t, sprite.frame, 1)
	update_animation(&sprite, 0.2) // runs out
	testing.expect_value(t, sprite.clip.frame_start, 10)
	testing.expect_value(t, sprite.frame, 10)
	testing.expect_value(t, sprite.playing, true)
	testing.expect_value(t, sprite.looping, true)
	testing.expect_value(t, sprite.queue_len, 0)
}

@(test)
pause_does_not_skip_the_queue :: proc(t:^testing.T) {
	sheet := test_sheet()
	sprite := create_animated_sprite_from_clip(animation_range(sheet, 0, 2), 1, false)
	queue_animation(&sprite, animation_range(sheet, 10, 12), true)

	sprite.playing = false
	update_animation(&sprite, 5)
	testing.expect_value(t, sprite.frame, 0)
	testing.expect_value(t, sprite.queue_len, 1)
}

@(test)
switch_to_same_clip_does_nothing_but_tuning :: proc(t:^testing.T) {
	sheet := test_sheet()
	walk := animation_range(sheet, 4, 8)
	sprite := create_animated_sprite_from_clip(walk)

	update_animation(&sprite, 0.25)
	frame := sprite.frame
	queue_animation(&sprite, animation_range(sheet, 0, 1), true)

	switch_animation(&sprite, animation_range(sheet, 4, 8, 0.5)) // same frames, new speed
	testing.expect_value(t, sprite.frame, frame) // not restarted
	testing.expect_value(t, sprite.clip.seconds_per_frame, 0.5)
	testing.expect_value(t, sprite.queue_len, 1) // queue kept
}

@(test)
real_switch_clears_queue_and_keeps_flip :: proc(t:^testing.T) {
	sheet := test_sheet()
	sprite := create_animated_sprite_from_clip(animation_range(sheet, 4, 8))
	sprite.flip_x = true
	queue_animation(&sprite, animation_range(sheet, 0, 1), true)

	switch_animation(&sprite, animation_range(sheet, 10, 12))
	testing.expect_value(t, sprite.frame, 10)
	testing.expect_value(t, sprite.queue_len, 0)
	testing.expect_value(t, sprite.flip_x, true) // the old seat_first_frame lost this
}

@(test)
full_queue_drops_the_new_clip :: proc(t:^testing.T) {
	sheet := test_sheet()
	sprite := create_animated_sprite_from_clip(sheet)
	context.logger = log.nil_logger() // the full queue logs an error on purpose
	for _ in 0 ..< MAX_ANIMATION_QUEUE + 2 {
		queue_animation(&sprite, sheet, true)
	}
	testing.expect_value(t, sprite.queue_len, MAX_ANIMATION_QUEUE)
}

@(test)
frozen_clip_does_not_move :: proc(t:^testing.T) {
	clip := animation_range(test_sheet(), 2, 5)
	clip.seconds_per_frame = 0
	sprite := create_animated_sprite_from_clip(clip)
	update_animation(&sprite, 10)
	testing.expect_value(t, sprite.frame, 2)
}

@(test)
offset_scales_with_the_sprite_and_mirrors_with_flip :: proc(t:^testing.T) {
	clip := animation_range(test_sheet(), 0, 3)
	clip.offset = {32, 8}
	sprite := create_animated_sprite_from_clip(clip, 2, true, 64) // 64 pixels per unit, twice as big

	shift := calculate_animation_render_offset(sprite)
	testing.expect_value(t, shift.x, 1) // 32 pixels = half a unit, doubled by the scale
	testing.expect_value(t, shift.y, 0.25)

	sprite.flip_x = true
	shift = calculate_animation_render_offset(sprite)
	testing.expect_value(t, shift.x, -1)
	testing.expect_value(t, shift.y, 0.25)
}

@(test)
no_offset_moves_nothing :: proc(t:^testing.T) {
	sprite := create_animated_sprite_from_clip(test_sheet())
	testing.expect_value(t, calculate_animation_render_offset(sprite), [2]f32{0, 0})
}

@(test)
switching_to_the_same_clip_updates_the_offset :: proc(t:^testing.T) {
	clip := animation_range(test_sheet(), 4, 8)
	sprite := create_animated_sprite_from_clip(clip)

	nudged := clip
	nudged.offset = {5, 0}
	switch_animation(&sprite, nudged)
	testing.expect_value(t, sprite.clip.offset, [2]f32{5, 0})
}

@(test)
window_is_relative_to_the_clip :: proc(t:^testing.T) {
	sprite := create_animated_sprite_from_clip(animation_range(test_sheet(), 10, 15))
	update_animation(&sprite, 0.25) // frame 12, which is frame 2 of the clip

	testing.expect_value(t, calculate_animation_frame(sprite), 2)
	testing.expect_value(t, is_animation_in_window(sprite, 2, 4), true)
	testing.expect_value(t, is_animation_in_window(sprite, 3, 5), false)
	testing.expect_value(t, is_animation_in_window(sprite, 4, 1), false) // empty window
}
