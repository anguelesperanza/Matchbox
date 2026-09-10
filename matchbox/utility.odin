package matchbox

/*
	Utility
	-------
	Gameplay helpers that are neither rendering nor input, kept in one place
	rather than in a file each.

	**This was a holding pen, and is not one any more.** These were three
	separate files (`timer.odin`, `lerp.odin`, `look_at.odin`), which made
	three small things look like three subsystems; collecting them said what
	they actually are. But the reason they were described as "waiting on a
	decision" was that Matchbox's scope had been narrowed to rendering and
	input, and a cooldown, a position tween and an angle-to-face-a-target are
	none of those.

	That narrowing was reversed on 2026-09-09 -- see CLAUDE.md's own "Scope"
	section, and `refactor.md` for the history. Gameplay helpers are in scope,
	so nothing here is pending eviction. This file is a home rather than a
	waiting room, and the question for anything joining it is the ordinary one:
	does a game actually need it, and is it built the way the rest of this
	package is.

	Worth keeping from the old note, because it is measurement rather than
	opinion: `Cooldown_Timer` is used by a real game, `Lerp_Move` by nothing
	anywhere, and `look_at_point` only by an example. That says which of the
	three has earned its place, which is a different question from whether the
	file should exist.

	`look_at_sprite` is deliberately *not* here. Math that acts on a sprite
	lives in `sprite.odin` with the sprite, which is also where its inverse
	`sprite_forward_by_rotation` already was.
*/

import "core:math"

// -----------------------------------------------------------------------
// Cooldown timer
// -----------------------------------------------------------------------

Cooldown_Timer :: struct {
	duration:  f32, // total duration in seconds (set by start_cooldown)
	remaining: f32, // seconds left; counts down to 0
}

// Starts the cooldown. duration is in seconds and can be fractional (e.g. 0.5).
start_cooldown :: proc(cooldown: ^Cooldown_Timer, duration: f32) {
	cooldown.duration  = duration
	cooldown.remaining = duration
}

// Advances the cooldown by delta_time. Call once per frame.
// Clamps remaining to 0 — will not go negative.
update_cooldown :: proc(cooldown: ^Cooldown_Timer, delta_time: f32) {
	if cooldown.remaining > 0 {
		cooldown.remaining -= delta_time
		if cooldown.remaining < 0 do cooldown.remaining = 0
	}
}

// Returns true once the cooldown has fully elapsed.
is_cooldown_done :: proc(cooldown: Cooldown_Timer) -> bool {
	return cooldown.remaining <= 0
}

// Resets remaining back to the original duration, restarting the countdown.
reset_cooldown :: proc(cooldown: ^Cooldown_Timer) {
	cooldown.remaining = cooldown.duration
}

// Immediately expires the cooldown (sets remaining to 0).
stop_cooldown :: proc(cooldown: ^Cooldown_Timer) {
	cooldown.remaining = 0
}

// -----------------------------------------------------------------------
// Position lerp
// -----------------------------------------------------------------------

Lerp_Move :: struct {
    start:    [2]f32,
    dest:     [2]f32,
    elapsed:  f32,
    duration: f32,
}

// Creates a Lerp_Move anchored at position. Starts in the "arrived" state
// so nothing moves until lerp_move_to is first called.
create_lerp_move :: proc(position: [2]f32, duration: f32) -> Lerp_Move {
    return Lerp_Move{
        start    = position,
        dest     = position,
        elapsed  = duration,
        duration = duration,
    }
}

// Sets a new destination. Pass the sprite's current position so the move
// starts from wherever it is right now. Resets the timer to zero so the
// full duration is used for the new leg of travel.
lerp_move_to :: proc(lerp: ^Lerp_Move, current_position: [2]f32, dest: [2]f32) {
    lerp.start   = current_position
    lerp.dest    = dest
    lerp.elapsed = 0
}

// Advances the lerp by delta_time and returns the new position.
// Assign the result to sprite.position each frame.
// Returns dest exactly when the full duration has elapsed.
update_lerp_move :: proc(lerp: ^Lerp_Move, delta_time: f32) -> [2]f32 {
    lerp.elapsed += delta_time
    t := math.clamp(lerp.elapsed / lerp.duration, 0, 1)
    return lerp.start + t * (lerp.dest - lerp.start)
}

// -----------------------------------------------------------------------
// Look at
// -----------------------------------------------------------------------

// Returns the angle (radians) needed to face from a point toward target.
// forward controls which side of the sprite is treated as its forward direction.
look_at_point :: proc(from: [2]f32, target: [2]f32, forward: Sprite_Forward = .TOP) -> f32 {
	direction := target - from
	offset: f32
	switch forward {
	case .TOP:    offset =  math.PI / 2
	case .RIGHT:  offset =  0
	case .BOTTOM: offset = -math.PI / 2
	case .LEFT:   offset =  math.PI
	}
	return math.atan2(direction.y, direction.x) + offset
}

// The angle that points something at a target, given either a plain position
// or a sprite. `look_at_point` is here; `look_at_sprite` is in `sprite.odin`,
// with the rest of the sprite math.
look_at :: proc { look_at_point, look_at_sprite }
