package matchbox

/*
	Cooldown
	========
	Waits a number of seconds of game time and answers whether the wait is over. Driven by the
	delta time the game passes to update_cooldown, like update_animation, not by a clock:

	- it pauses with the game. A cooldown nobody updates waits, so a pause menu or a death
	  screen needs no extra code, where a clock would run on and finish everything behind it
	- it moves at the speed the world does. Pass a scaled or clamped delta and it follows, so
	  a spawn timer cannot get ahead of the obstacles it spaces out
	- it is plain arithmetic, so its tests drive it with numbers and no clock

	get_time (clock.odin) is there for what wants real time instead.

	The one before this stood on core:time's Stopwatch, which has no clock on freestanding
	targets, so on the 3DS and the Vita a cooldown never finished. It also took whole seconds
	only, finished half a second early (it rounded), and fell behind on a frame longer than
	a second.

	Finished is its own state, apart from never started: a zero Cooldown is neither, so a
	spawner whose start_cooldown was forgotten does nothing rather than firing on frame one.
	It stays finished until started again, so asking a frame late still gets the answer
*/

Cooldown :: struct {
	duration:f32, // seconds, as given to start_cooldown
	remaining:f32, // seconds left; counts down to 0
	running:bool, // counting down: from start_cooldown until it reaches 0, or stop_cooldown
	finished:bool, // reached 0, and not started again since
}

/*Starts the cooldown, or starts it again from the top. `duration` is in seconds, fractions included; 0 or less finishes on the next update_cooldown*/
start_cooldown :: proc(cooldown:^Cooldown, duration:f32) {
	cooldown^ = {duration = duration, remaining = duration, running = true}
}

/*Counts the cooldown down by `delta_time` seconds. Call once a frame; a cooldown that is not updated waits*/
update_cooldown :: proc(cooldown:^Cooldown, delta_time:f32) {
	if cooldown.running == false do return
	cooldown.remaining -= delta_time
	if cooldown.remaining <= 0 {
		cooldown.remaining = 0
		cooldown.running = false
		cooldown.finished = true
	}
}

/*Stops the cooldown without finishing it: it is back to never started, and keeps its duration*/
stop_cooldown :: proc(cooldown:^Cooldown) {
	cooldown^ = {duration = cooldown.duration}
}

/*True from the update that reached 0 until the cooldown is started again*/
is_cooldown_finished :: proc(cooldown:Cooldown) -> bool {
	return cooldown.finished
}

/*True while counting down*/
is_cooldown_running :: proc(cooldown:Cooldown) -> bool {
	return cooldown.running
}

/*How far through the cooldown is, 0 to 1: 0 before it starts and after stop_cooldown, 1 once finished. For a bar, or a button that brightens as it recharges*/
calculate_cooldown_progress :: proc(cooldown:Cooldown) -> f32 {
	if cooldown.finished do return 1
	if cooldown.running == false || cooldown.duration <= 0 do return 0
	return clamp(1 - cooldown.remaining / cooldown.duration, 0, 1)
}
