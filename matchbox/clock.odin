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
	start_ts:          u64, // counter value when init finished, which get_time counts from
	delta_time:        f32, // seconds since the previous poll_events, clamped
	max_delta_time:    f32, // delta_time ceiling, so a stalled frame can't teleport everything
	target_frame_time: f32, // 0 = unlimited; set via set_target_fps

	// The counter value the next frame is due to start at, advanced by exactly
	// one frame period each time whatever the last one actually cost. That is
	// what stops the limiter drifting -- see poll_events.
	next_frame_ts:     u64,

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

/*
	Seconds since init. A clock: it only ever goes up.

	Sampled at the last poll_events rather than read live, so every call during
	one frame gives the same answer. Two things asking the time in the same frame
	and getting different answers is a bug waiting to happen.

	It reports real elapsed time, which is **not** always the same as summing
	`delta_time`. delta_time is clamped by `max_delta_time` so that a stalled
	frame cannot teleport everything across the screen; this is a clock and does
	not get to lie about a stall. Measured over 120 ordinary frames the two
	parted company by about fourteen milliseconds -- one clamped frame -- so
	anything mixing the two will drift by however long it has spent stuttering.
	Pick one and stay with it: delta_time to move things, this to schedule them.

	This exists because there was no way to ask. `delta_time` and `frame_count`
	were the whole of it, and an emulator ported from raylib reached for the
	nearest thing to GetTime(), which is a clock, and got the frame delta:

		current := matchbox.delta_time() * 1000   // wrong: a duration, not a time
		elapsed := current - last                 // the *change* in frame length
		last     = current                        // which is about zero

	That compiles, looks right, and quietly stops the accumulator it feeds. With
	this the same shape is correct, because the subtraction it wants is what the
	two readings differ by:

		now     := matchbox.get_time()
		elapsed := now - last
		last     = now

	For a stopwatch around something inside a single frame this is the wrong
	tool -- it will not have moved. seconds_since and the performance counter are
	what that wants.
*/
get_time :: proc() -> f64 {
	if mbi.ts_freq == 0 do return 0
	return f64(mbi.now_ts - mbi.start_ts) / f64(mbi.ts_freq)
}

// Limits the frame rate to `fps` frames per second by sleeping in poll_events.
// Pass 0 to remove the limit (default).
set_target_fps :: proc(fps: i32) {
	mbi.target_frame_time = 1.0 / f32(fps) if fps > 0 else 0
}
