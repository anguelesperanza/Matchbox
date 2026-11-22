#+build windows

package matchbox

import "core:testing"

/*A zero Cooldown is neither running nor finished, and updating it changes nothing*/
@(test)
test_cooldown_zero_value :: proc(t:^testing.T) {
	cooldown:Cooldown
	update_cooldown(&cooldown, 10)
	testing.expect(t, !is_cooldown_running(cooldown))
	testing.expect(t, !is_cooldown_finished(cooldown))
	testing.expect_value(t, calculate_cooldown_progress(cooldown), 0)
}

/*Finishes on the update that reaches 0, and stays finished until started again. Quarters are exact in binary, so the comparisons are exact*/
@(test)
test_cooldown_counts_down :: proc(t:^testing.T) {
	cooldown:Cooldown
	start_cooldown(&cooldown, 1)
	for _ in 0 ..< 3 do update_cooldown(&cooldown, 0.25)
	testing.expect(t, is_cooldown_running(cooldown))
	testing.expect(t, !is_cooldown_finished(cooldown))
	testing.expect_value(t, calculate_cooldown_progress(cooldown), 0.75)

	update_cooldown(&cooldown, 0.25)
	testing.expect(t, !is_cooldown_running(cooldown))
	testing.expect(t, is_cooldown_finished(cooldown))
	testing.expect_value(t, cooldown.remaining, 0)
	testing.expect_value(t, calculate_cooldown_progress(cooldown), 1)

	update_cooldown(&cooldown, 0.25)
	testing.expect(t, is_cooldown_finished(cooldown))

	start_cooldown(&cooldown, 2)
	testing.expect(t, !is_cooldown_finished(cooldown))
	testing.expect(t, is_cooldown_running(cooldown))
	testing.expect_value(t, cooldown.remaining, 2)
}

/*stop_cooldown is not finishing: back to never started, duration kept*/
@(test)
test_cooldown_stop :: proc(t:^testing.T) {
	cooldown:Cooldown
	start_cooldown(&cooldown, 1)
	update_cooldown(&cooldown, 0.5)
	stop_cooldown(&cooldown)
	testing.expect(t, !is_cooldown_running(cooldown))
	testing.expect(t, !is_cooldown_finished(cooldown))
	testing.expect_value(t, calculate_cooldown_progress(cooldown), 0)
	testing.expect_value(t, cooldown.duration, 1)

	update_cooldown(&cooldown, 5)
	testing.expect(t, !is_cooldown_finished(cooldown))
}

/*One long frame finishes it once, rather than falling behind as the old one did*/
@(test)
test_cooldown_long_frame :: proc(t:^testing.T) {
	cooldown:Cooldown
	start_cooldown(&cooldown, 1)
	update_cooldown(&cooldown, 5)
	testing.expect(t, is_cooldown_finished(cooldown))
	testing.expect_value(t, cooldown.remaining, 0)
}

/*A duration of 0 finishes on the first update, not at start*/
@(test)
test_cooldown_zero_duration :: proc(t:^testing.T) {
	cooldown:Cooldown
	start_cooldown(&cooldown, 0)
	testing.expect(t, !is_cooldown_finished(cooldown))
	update_cooldown(&cooldown, 0)
	testing.expect(t, is_cooldown_finished(cooldown))
}
