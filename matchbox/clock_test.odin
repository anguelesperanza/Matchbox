#+build windows

package matchbox

import "core:testing"

/*The first tick measures nothing; later ticks measure the gap since the last. A local Clock, so mbi is not written*/
@(test)
test_clock_ticks :: proc(t:^testing.T) {
	clock:Clock
	start_clock(&clock, 5000, 1000)
	testing.expect_value(t, calculate_clock_time(clock), 0)

	tick_clock(&clock, 6000) // a second of loading after init
	testing.expect_value(t, clock.delta_time, 0)
	testing.expect_value(t, calculate_clock_time(clock), 1)

	tick_clock(&clock, 6016)
	testing.expect_value(t, clock.delta_time, f32(0.016))
	tick_clock(&clock, 6033)
	testing.expect_value(t, clock.delta_time, f32(0.017))
	testing.expect_value(t, calculate_clock_time(clock), 1.033)
}

/*Before init (and under odin test) the frequency is 0: no division by it*/
@(test)
test_clock_without_frequency :: proc(t:^testing.T) {
	clock:Clock
	tick_clock(&clock, 100)
	tick_clock(&clock, 200)
	testing.expect_value(t, clock.delta_time, 0)
	testing.expect_value(t, calculate_clock_time(clock), 0)
}
