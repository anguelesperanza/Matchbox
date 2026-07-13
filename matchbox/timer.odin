package matchbox

// -----------------------------------------------------------------------
// Systems -- Cooldown Timer
// -----------------------------------------------------------------------

CooldownTimer :: struct {
	duration:  f32, // total duration in seconds (set by start_cooldown)
	remaining: f32, // seconds left; counts down to 0
}

// Starts the cooldown. duration is in seconds and can be fractional (e.g. 0.5).
start_cooldown :: proc(cooldown: ^CooldownTimer, duration: f32) {
	cooldown.duration  = duration
	cooldown.remaining = duration
}

// Advances the cooldown by delta_time. Call once per frame.
// Clamps remaining to 0 — will not go negative.
update_cooldown :: proc(cooldown: ^CooldownTimer, delta_time: f32) {
	if cooldown.remaining > 0 {
		cooldown.remaining -= delta_time
		if cooldown.remaining < 0 do cooldown.remaining = 0
	}
}

// Returns true once the cooldown has fully elapsed.
is_cooldown_done :: proc(cooldown: CooldownTimer) -> bool {
	return cooldown.remaining <= 0
}

// Resets remaining back to the original duration, restarting the countdown.
reset_cooldown :: proc(cooldown: ^CooldownTimer) {
	cooldown.remaining = cooldown.duration
}

// Immediately expires the cooldown (sets remaining to 0).
stop_cooldown :: proc(cooldown: ^CooldownTimer) {
	cooldown.remaining = 0
}
