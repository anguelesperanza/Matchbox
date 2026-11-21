package GameSystems


/*
	Cooldown
	========
	This file handles creating cooldowns for things
*/

import "core:time"


CooldownTimer :: struct {
	stopwatch:time.Stopwatch, // actual timer
	max_cooldown_time:i64, // how long it will run for in seconds
	cooldown_counter:i64,
	previous_time:time.Duration,
}

start_cooldown :: proc(cooldown:^CooldownTimer, duration_in_seconds:i64) {
	/*Starts the cooldown*/
	time.stopwatch_start(&cooldown.stopwatch)
	cooldown.max_cooldown_time = duration_in_seconds
	cooldown.previous_time = cast(time.Duration)time.duration_seconds(0)

}

stop_cooldown :: proc(cooldown:^CooldownTimer) {
	/*stops the cooldown and resets the state (keeps the max cooldown time set in start_cooldown)*/
	time.stopwatch_stop(&cooldown.stopwatch)
	time.stopwatch_reset(&cooldown.stopwatch)
	cooldown.cooldown_counter = 0
	cooldown.previous_time = cast(time.Duration)time.duration_seconds(0)
	
}

check_cooldown_time :: proc(cooldown:^CooldownTimer) {
	/**/
	duration := time.duration_round(time.stopwatch_duration(cooldown.stopwatch), time.Second)

	if duration > cooldown.previous_time {
		cooldown.previous_time = duration
		cooldown.cooldown_counter += 1
		
		if cooldown.cooldown_counter == cooldown.max_cooldown_time {
			stop_cooldown(cooldown)
		}
	}
}
