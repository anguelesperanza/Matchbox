package matchbox

/*
	Clock
	=====
	Frame timing, the same on every target. Each target reads its own counter (PC:
	QueryPerformanceCounter; 3DS: svcGetSystemTick; Vita: sceKernelGetProcessTimeWide) and hands
	it to start_clock in init and to tick_clock in poll_events. Everything else is here.

	Sampled once a frame, in poll_events, rather than read when asked. get_delta_time used to
	read the counter itself and restart from there, so a second call in the same frame got
	about 0, and anything that asked the time twice in a frame got two answers.

	Not core:time: on freestanding targets it has no clock (core/time/time_other.odin, ticks
	are always 0), which is what stopped every cooldown finishing on the 3DS and the Vita.
*/

Clock :: struct {
	frequency:u64, // counter ticks per second; 0 until init, and under `odin test`
	start:u64, // the counter at init, which get_time counts from
	now:u64, // the counter at the last poll_events
	delta_time:f32, // seconds between the last two poll_events
	ticked:bool, // poll_events has run once, so there is a previous frame to measure from
}

/*Seconds between the last two poll_events. The same all frame, however often it is asked. Multiply movement by it so speeds don't depend on the frame rate*/
get_delta_time :: proc() -> f32 {
	return mbi.clock.delta_time
}

/*
	Seconds since init, sampled at the last poll_events. Real time: it keeps going while a
	game pauses, so it suits what follows the wall clock (an auto-save every minute, how long
	a session has run). What should pause with the game wants delta time: a Cooldown
*/
get_time :: proc() -> f64 {
	return calculate_clock_time(mbi.clock)
}

@(private)
calculate_clock_time :: proc(clock:Clock) -> f64 {
	if clock.frequency == 0 do return 0
	return f64(clock.now - clock.start) / f64(clock.frequency)
}

/*Called by each target's init with its counter and how fast it counts*/
@(private)
start_clock :: proc(clock:^Clock, counter:u64, frequency:u64) {
	clock^ = {frequency = frequency, start = counter, now = counter}
}

/*
	Called at the top of each target's poll_events. The first one gives a delta of 0, not the
	time since init: that span holds the game's loading (Teddy loads its textures after init),
	and a first frame worth a second or two would move everything that far before the player
	sees a thing
*/
@(private)
tick_clock :: proc(clock:^Clock, counter:u64) {
	previous := clock.now
	clock.now = counter
	if clock.ticked == false || clock.frequency == 0 {
		clock.delta_time = 0
		clock.ticked = true
		return
	}
	clock.delta_time = f32(f64(counter - previous) / f64(clock.frequency))
}
