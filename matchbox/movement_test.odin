#+build windows

package matchbox

/*
	Every direction is a sign that can be wrong without anything looking broken on a symmetrical test scene,
	so each is a number worked out by hand, and where Matchbox already has an independent answer
	(`calculate_camera_right`) the test checks against that. steer_character takes its input as an argument,
	so none of these touch `mbi`.
*/

import "core:math"
import "core:math/linalg"
import "core:testing"

@(private="file")
DT :: f32(1.0 / 60.0)

@(private="file")
near :: proc(a:[3]f32, b:[3]f32) -> bool {
	return linalg.length(a - b) < 1e-4
}

// Behind the origin on +Z looking toward -Z: away from this camera is -Z
@(private="file")
facing_north :: proc() -> Camera {
	return create_camera_3d({0, 5, 10}, {0, 0, 0})
}

// What a cut to the far end of a corridor puts on screen
@(private="file")
facing_south :: proc() -> Camera {
	return create_camera_3d({0, 5, -10}, {0, 0, 0})
}

@(test)
tank_up_walks_along_the_heading :: proc(t:^testing.T) {
	controls := create_character_controls(facing = 0)
	steer_character(&controls, {0, 1}, facing_north(), DT)
	testing.expectf(t, near(controls.move, {0, 0, -1}), "facing -Z, up moved %v", controls.move)

	controls = create_character_controls(facing = math.PI * 0.5)
	steer_character(&controls, {0, 1}, facing_north(), DT)
	testing.expectf(t, near(controls.move, {-1, 0, 0}), "facing -X, up moved %v", controls.move)
}

// Right turns clockwise seen from above, which is a smaller yaw here; 3 rad/s for a frame is 0.05
@(test)
tank_right_turns_clockwise_on_the_spot :: proc(t:^testing.T) {
	controls := create_character_controls()
	steer_character(&controls, {1, 0}, facing_north(), DT)
	testing.expectf(t, abs(controls.facing + 3 * DT) < 1e-6, "facing %v", controls.facing)
	testing.expect_value(t, controls.move, [3]f32{0, 0, 0})

	// Walking backwards does not reverse the turn, as the genre has it
	controls = create_character_controls()
	steer_character(&controls, {1, -1}, facing_north(), DT)
	testing.expectf(t, controls.facing < 0, "facing %v", controls.facing)
}

@(test)
tank_backwards_is_slower :: proc(t:^testing.T) {
	controls := create_character_controls()
	steer_character(&controls, {0, -1}, facing_north(), DT)
	testing.expectf(t, near(controls.move, {0, 0, 0.6}), "moved %v", controls.move)
}

@(test)
tank_ignores_the_camera :: proc(t:^testing.T) {
	a := create_character_controls(facing = 0.4)
	b := create_character_controls(facing = 0.4)
	steer_character(&a, {0.3, 1}, facing_north(), DT)
	steer_character(&b, {0.3, 1}, facing_south(), DT)
	testing.expect_value(t, a.move, b.move)
	testing.expect_value(t, a.facing, b.facing)
}

@(test)
camera_relative_up_walks_away_from_the_camera :: proc(t:^testing.T) {
	controls := create_character_controls(scheme = .CAMERA_RELATIVE)
	steer_character(&controls, {0, 1}, facing_north(), DT)
	testing.expectf(t, near(controls.move, {0, 0, -1}), "north camera, up moved %v", controls.move)

	controls = create_character_controls(scheme = .CAMERA_RELATIVE)
	steer_character(&controls, {0, 1}, facing_south(), DT)
	testing.expectf(t, near(controls.move, {0, 0, 1}), "south camera, up moved %v", controls.move)
}

@(test)
camera_relative_right_is_the_cameras_right :: proc(t:^testing.T) {
	for camera in ([]Camera{facing_north(), facing_south(), create_camera_3d({6, 4, 6}, {0, 0, 0})}) {
		controls := create_character_controls(scheme = .CAMERA_RELATIVE)
		steer_character(&controls, {1, 0}, camera, DT)
		right := calculate_camera_right(camera)
		right.y = 0
		right = linalg.normalize(right)
		testing.expectf(t, near(controls.move, right), "camera right %v, moved %v", right, controls.move)
	}
}

@(test)
camera_relative_diagonal_is_not_faster_and_a_half_push_is_half :: proc(t:^testing.T) {
	controls := create_character_controls(scheme = .CAMERA_RELATIVE)
	steer_character(&controls, {1, 1}, facing_north(), DT)
	testing.expect(t, abs(linalg.length(controls.move) - 1) < 1e-5)

	steer_character(&controls, {0, 0.5}, facing_north(), DT)
	testing.expect(t, abs(linalg.length(controls.move) - 0.5) < 1e-5)
}

@(test)
camera_relative_turns_the_body_toward_the_run_and_stops_turning_when_it_stops :: proc(t:^testing.T) {
	controls := create_character_controls(scheme = .CAMERA_RELATIVE, turn_speed = 1000)
	steer_character(&controls, {1, 0}, facing_north(), DT) // east: yaw -90
	testing.expectf(t, abs(controls.facing + math.PI * 0.5) < 1e-4, "facing %v", controls.facing)

	steer_character(&controls, {0, 0}, facing_south(), DT)
	testing.expectf(t, abs(controls.facing + math.PI * 0.5) < 1e-4, "a character who stops keeps its heading: %v", controls.facing)
}

// The famous bug: hold up through a cut to a camera looking the other way
@(test)
a_held_basis_keeps_the_run_going_through_a_cut :: proc(t:^testing.T) {
	controls := create_character_controls(scheme = .CAMERA_RELATIVE)
	steer_character(&controls, {0, 1}, facing_north(), DT)
	testing.expect(t, near(controls.move, {0, 0, -1}))

	steer_character(&controls, {0, 1}, facing_south(), DT)
	testing.expectf(t, near(controls.move, {0, 0, -1}), "through the cut the run turned to %v", controls.move)
	testing.expect(t, controls.basis_held)

	// Let go, push again: up now means away from the camera on screen
	steer_character(&controls, {0, 0}, facing_south(), DT)
	testing.expect(t, !controls.basis_held)
	steer_character(&controls, {0, 1}, facing_south(), DT)
	testing.expectf(t, near(controls.move, {0, 0, 1}), "after letting go, up moved %v", controls.move)
}

@(test)
without_a_held_basis_the_run_turns_round_at_a_cut :: proc(t:^testing.T) {
	controls := create_character_controls(scheme = .CAMERA_RELATIVE, hold_basis = false)
	steer_character(&controls, {0, 1}, facing_north(), DT)
	steer_character(&controls, {0, 1}, facing_south(), DT)
	testing.expectf(t, near(controls.move, {0, 0, 1}), "moved %v", controls.move)
}

// Up to right is 90 degrees, past the 60 degree tolerance; up to up-and-a-little-right is a correction
@(test)
a_held_basis_is_let_go_only_when_the_stick_swings_far_enough :: proc(t:^testing.T) {
	controls := create_character_controls(scheme = .CAMERA_RELATIVE)
	steer_character(&controls, {0, 1}, facing_north(), DT)

	steer_character(&controls, {0.3, 1}, facing_south(), DT) // 16.7 degrees
	testing.expect(t, controls.move.z < 0, "a small correction kept the basis")

	steer_character(&controls, {1, 0}, facing_south(), DT) // 90 degrees from the start
	testing.expectf(t, near(controls.move, {-1, 0, 0}), "a new intention took the camera on screen: %v", controls.move)
}

@(test)
a_camera_looking_straight_down_is_read_by_its_up :: proc(t:^testing.T) {
	camera := create_camera_3d({0, 10, 0}, {0, 0, 0})
	camera.up = {0, 0, -1} // the top of the screen is -Z
	yaw, ok := calculate_camera_ground_yaw(camera)
	testing.expect(t, ok)
	testing.expectf(t, abs(yaw) < 1e-5, "yaw %v", yaw)

	camera.up = {0, 1, 0}
	_, ok = calculate_camera_ground_yaw(camera)
	testing.expect(t, !ok)
}

@(test)
stick_swing_is_the_angle_between_two_directions :: proc(t:^testing.T) {
	testing.expect(t, abs(calculate_stick_swing({0, 1}, {1, 0}) - math.PI * 0.5) < 1e-5)
	testing.expect(t, abs(calculate_stick_swing({0, 2}, {0, 0.1})) < 1e-3)
	testing.expect(t, abs(calculate_stick_swing({0, 1}, {0, -1}) - math.PI) < 1e-5)
}
