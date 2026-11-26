#+build windows

package matchbox

import "core:math/linalg"
import "core:testing"

@(private="file")
near :: proc(a, b:[2]f32, tolerance:f32 = 1e-5) -> bool {
	return linalg.length(a - b) < tolerance
}

@(test)
a_stick_at_rest_is_zero :: proc(t:^testing.T) {
	// The circle pad that found this rested at about 15 counts of its 156, which is 0.096 and was 0.1 a frame of walking
	for rest in ([?][2]f32{{15, 0}, {0, -15}, {-12, 11}, {10, 10}, {14, 6}}) {
		axis := rest / 156
		testing.expectf(t, calculate_thumbstick_dead_zone(axis, 0.15) == {}, "rest %v read as %v", rest, calculate_thumbstick_dead_zone(axis, 0.15))
	}
	testing.expect(t, calculate_thumbstick_dead_zone({0.1, 0}, 0.15) == {})
	testing.expect(t, calculate_thumbstick_dead_zone({0.15, 0}, 0.15) == {}) // the edge itself is still inside
	testing.expect(t, calculate_thumbstick_dead_zone({0, 0}, 0.15) == {})
}

@(test)
travel_past_the_dead_zone_is_stretched_back_to_the_full_range :: proc(t:^testing.T) {
	// Worked by hand: (0.575 - 0.15) / 0.85 = 0.5, and full travel is full
	testing.expect(t, near(calculate_thumbstick_dead_zone({0.575, 0}, 0.15), {0.5, 0}))
	testing.expect(t, near(calculate_thumbstick_dead_zone({0, -1}, 0.15), {0, -1}))
	testing.expect(t, near(calculate_thumbstick_dead_zone({-1, 0}, 0.15), {-1, 0}))

	// Starts from 0 where the dead zone ends: no jump to 0.15 the moment it is crossed
	just_outside := calculate_thumbstick_dead_zone({0.1501, 0}, 0.15)
	testing.expect(t, just_outside.x > 0 && just_outside.x < 0.001)

	// A diagonal stays one: the direction is kept, 0.8 of travel along (0.6, 0.8) is 0.76 -> (0.6, 0.8) * (0.8 - 0.15) / 0.85
	testing.expect(t, near(calculate_thumbstick_dead_zone({0.48, 0.64}, 0.15), {0.6, 0.8} * 0.76470588))

	// Past full travel (a clamped diagonal can read a hair over) is full, not more
	testing.expect(t, near(calculate_thumbstick_dead_zone({1.2, 0}, 0.15), {1, 0}))
}

@(test)
a_dead_zone_of_zero_changes_nothing :: proc(t:^testing.T) {
	testing.expect(t, near(calculate_thumbstick_dead_zone({0.3, -0.4}, 0), {0.3, -0.4}))
}
