package matchbox

import "core:math"

// -----------------------------------------------------------------------
// Systems -- Position Lerp
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
