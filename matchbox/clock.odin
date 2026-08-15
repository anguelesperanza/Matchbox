package matchbox

/*
	Clock
	-----
	Frame timing. Updated once per poll_events.

	This is engine timing -- see timer.odin for CooldownTimer, which is a
	gameplay utility built on top of delta_time.
*/

Clock :: struct {
	ts_freq:           u64, // performance counter ticks per second
	now_ts:            u64, // counter value at the most recent poll_events
	delta_time:        f32, // seconds since the previous poll_events, clamped
	max_delta_time:    f32, // delta_time ceiling, so a stalled frame can't teleport everything
	target_frame_time: f32, // 0 = unlimited; set via set_target_fps

	// Frames since the program started, counted by poll_events. Anything caching
	// something for the length of a frame compares against this -- get_font does,
	// so a font handed out this frame cannot be evicted underneath its caller.
	frame:             u64,
}

// How many frames poll_events has run. Starts at 0 and is 1 during the first
// frame, so a zero recorded anywhere means "never".
frame_count :: proc() -> u64 {
	return mbi.frame
}

// Seconds elapsed during the previous frame. Multiply per-frame movement by
// this so speeds stay the same regardless of frame rate.
delta_time :: proc() -> f32 {
	return mbi.delta_time
}

// Limits the frame rate to `fps` frames per second by sleeping in poll_events.
// Pass 0 to remove the limit (default).
set_target_fps :: proc(fps: i32) {
	mbi.target_frame_time = 1.0 / f32(fps) if fps > 0 else 0
}
