package matchbox

/*
	Thumbstick
	==========
	What a stick reports when nobody touches it. The 3DS circle pad rests at a few counts off zero (about 15 of 156 on
	the one that found this), and libctru gives it as it is, so a character crept along at 0.1 a frame once the finger
	was off. Shared so the maths is tested on PC; the 3DS's poll_events is what calls it
*/

import "core:math/linalg"

Thumbstick_Settings :: struct {
	dead_zone:f32, // how far from the centre a stick must go, as a fraction of its full travel, before it counts
}

/*
	A stick's `axis` (each -1..1) with the middle ignored: zero inside `dead_zone` of the centre, and the rest of the
	travel stretched back to 0..1, so the value starts at 0 where the dead zone ends instead of jumping to `dead_zone`.
	The dead zone is a circle, not a square, so a stick resting off to one corner is caught as well as one off one axis.
	The direction is kept, so a diagonal stays a diagonal
*/
calculate_thumbstick_dead_zone :: proc(axis:[2]f32, dead_zone:f32 = mbi.thumbstick_settings.dead_zone) -> [2]f32 {
	length := linalg.length(axis)
	if length <= dead_zone || length == 0 do return {}

	// Past full travel counts as full: the 3DS clamps its diagonals the same way
	stretched := (min(length, 1) - dead_zone) / (1 - dead_zone)
	return axis / length * stretched
}
