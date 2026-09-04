package matchbox

/*
	Clock
	-----
	Frame timing. Updated once per poll_events.

	This is engine timing -- see `utility.odin` for Cooldown_Timer, which is a
	gameplay utility built on top of delta_time.

	`poll_events` drives the two private procedures at the bottom of this file
	rather than doing the work itself. They cannot be one procedure: the frame
	limiter has to run before the touch state is closed off for the frame and
	the tick has to run after it, so `poll_events` calls them either side.
*/

import sdl "vendor:sdl3"

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
get_frame_count :: proc() -> u64 {
	return mbi.frame
}

// Seconds elapsed during the previous frame. Multiply per-frame movement by
// this so speeds stay the same regardless of frame rate.
get_delta_time :: proc() -> f32 {
	return mbi.delta_time
}

/*
	Seconds since init. A clock: it only ever goes up.

	Sampled at the last poll_events rather than read live, so every call during
	one frame gives the same answer. Two things asking the time in the same frame
	and getting different answers is a bug waiting to happen.

	It reports real elapsed time, which is **not** always the same as summing
	`get_delta_time`. That value is clamped by `max_delta_time` so that a
	stalled frame cannot teleport everything across the screen; this is a clock
	and does not get to lie about a stall. Measured over 120 ordinary frames the
	two parted company by about fourteen milliseconds -- one clamped frame -- so
	anything mixing the two will drift by however long it has spent stuttering.
	Pick one and stay with it: `get_delta_time` to move things, this to schedule
	them.

	This exists because there was no way to ask. `get_delta_time` and
	`get_frame_count`
	were the whole of it, and an emulator ported from raylib reached for the
	nearest thing to GetTime(), which is a clock, and got the frame delta:

		current := matchbox.get_delta_time() * 1000   // wrong: a duration, not a time
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

// -----------------------------------------------------------------------
// Driven by poll_events
// -----------------------------------------------------------------------

/*
	Frame limiting, against an absolute deadline.

	Two things were wrong with waiting for "the frame time minus however long
	this frame took". The wait went through sdl.Delay, which takes whole
	milliseconds, so a rate that is not a whole number of them -- a Game Boy
	frame is 16.742706 ms -- lost the remainder every frame. And, which
	matters more, nothing ever made up for a wait that came back late: the
	error was measured fresh each frame and any overshoot was simply kept.

	Measured over 180 frames at a Game Boy's 16.742706 ms, that ran 1.4 to
	1.6 percent fast -- about 60.6 fps against a target of 59.7275, and
	repeatable to within a fifth of a percent run to run, so it was the model
	and not noise. The version below comes in at 0.22 percent under.

	So the deadline is absolute and advances by exactly one period whatever
	the last frame cost, which lets a long frame be followed by a short wait
	and leaves the average where it was asked to be. DelayPrecise takes
	nanoseconds and spins down the last fraction rather than handing the whole
	wait to the scheduler.

	The catch-up limit is what keeps that from turning into a stampede. A
	window dragged for two seconds would otherwise leave a deadline two
	seconds in the past and a hundred frames owed, and the loop would run flat
	out with no wait at all trying to serve them. Past four frames behind the
	debt is written off and the deadline starts again from now.
*/
@(private)
clock_wait_for_frame :: proc() {
	if mbi.target_frame_time > 0 && mbi.ts_freq > 0 {
		period := u64(f64(mbi.target_frame_time) * f64(mbi.ts_freq))
		now    := sdl.GetPerformanceCounter()

		switch {
		case mbi.next_frame_ts == 0, now > mbi.next_frame_ts + period * 4:
			mbi.next_frame_ts = now + period

		case now < mbi.next_frame_ts:
			wait := f64(mbi.next_frame_ts - now) / f64(mbi.ts_freq)
			sdl.DelayPrecise(u64(wait * 1_000_000_000))
			fallthrough

		case:
			mbi.next_frame_ts += period
		}
	}
}

// Takes the frame's timestamp and works out how long the last one lasted.
// Runs at the very end of poll_events, after the frame limiter has slept, so
// delta_time counts the wait as part of the frame it paced.
@(private)
clock_tick :: proc() {
	last_ts := mbi.now_ts
	mbi.now_ts = sdl.GetPerformanceCounter()

	// Seconds elapsed since the previous poll_events, clamped so a slow/stalled
	// frame can't teleport everything. Without this, delta_time stays 0 and the
	// whole game appears frozen on the first frame.
	mbi.delta_time = min(
		mbi.max_delta_time,
		f32(f64((mbi.now_ts - last_ts) * 1000) / f64(mbi.ts_freq)) / 1000.0,
	)
}
