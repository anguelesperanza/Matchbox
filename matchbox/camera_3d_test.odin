package matchbox

/*
	Every direction here is a sign that can be wrong without anything looking broken on a symmetrical
	scene, so each is asserted as a number worked out by hand or in Python (not by the formula under test).
	None of these touch `mbi`; the ones that read input are in camera_input_test.odin.
*/

import "core:math"
import "core:math/linalg"
import "core:testing"

@(private="file")
near :: proc(a:[3]f32, b:[3]f32, tolerance:f32 = 1e-4) -> bool {
	return linalg.length(a - b) < tolerance
}

@(test)
direction_from_angles_matches_hand_worked_values :: proc(t:^testing.T) {
	testing.expect(t, near(calculate_direction_from_angles(0, 0), {0, 0, -1}))
	// Positive yaw turns left: from -Z toward -X
	testing.expect(t, near(calculate_direction_from_angles(math.PI * 0.5, 0), {-1, 0, 0}))
	testing.expect(t, near(calculate_direction_from_angles(0, math.PI * 0.5), {0, 1, 0}))
	// Python: yaw = pitch = pi/6
	testing.expect(t, near(calculate_direction_from_angles(math.PI / 6, math.PI / 6), {-0.4330127, 0.5, -0.75}))
}

@(test)
camera_angles_undo_direction_from_angles :: proc(t:^testing.T) {
	camera := create_camera_3d({1, 2, 3}, {1, 2, 3} + calculate_direction_from_angles(0.7, -0.4) * 5)
	yaw, pitch := calculate_camera_angles(camera)
	testing.expectf(t, abs(yaw - 0.7) < 1e-4 && abs(pitch + 0.4) < 1e-4, "got yaw %v pitch %v", yaw, pitch)
}

// A point five units ahead of the eye must land five units down -Z in view space, whichever way it looks
@(test)
view_matrix_puts_the_point_ahead_on_the_minus_z_axis :: proc(t:^testing.T) {
	rig := create_first_person_camera(position = {0, 0, 0}, yaw = 0)
	view := calculate_camera_view_matrix(rig.camera)
	ahead := view * [4]f32{0, 1.7, -5, 1}
	testing.expectf(t, near(ahead.xyz, {0, 0, -5}), "looking down -Z: %v", ahead)

	// Turned a quarter left the same point is down -X
	rig = create_first_person_camera(position = {0, 0, 0}, yaw = math.PI * 0.5)
	view = calculate_camera_view_matrix(rig.camera)
	ahead = view * [4]f32{-5, 1.7, 0, 1}
	testing.expectf(t, near(ahead.xyz, {0, 0, -5}), "looking down -X: %v", ahead)

	// And a point to the camera's right sits on +X in view space
	right := view * [4]f32{-0, 1.7, -2, 1} // yaw 90: world -Z is the camera's right
	testing.expectf(t, near(right.xyz, {2, 0, 0}), "right of the camera: %v", right)
}

@(test)
first_person_eye_sits_above_the_position :: proc(t:^testing.T) {
	rig := create_first_person_camera(position = {4, 0, -2}, eye_offset = {0, 1.5, 0})
	testing.expect(t, near(rig.camera.position, {4, 1.5, -2}))
	testing.expect(t, near(rig.camera.target, {4, 1.5, -3}))

	// The pitch is clamped short of straight up, where the view matrix would collapse
	rig = create_first_person_camera(pitch = 5)
	testing.expect_value(t, rig.look.pitch, 1.56)
}

// Python: focus (0, 1.6, 0), distance 6, pitch -0.3 => (0, 3.3731212, 5.7320189)
@(test)
third_person_camera_sits_behind_and_above :: proc(t:^testing.T) {
	rig := create_third_person_camera()
	testing.expect(t, near(rig.camera.position, {0, 3.3731212, 5.7320189}))
	testing.expect(t, near(rig.camera.target, {0, 1.6, 0}))

	// Yaw 45: the camera moves to +X +Z, behind a character looking toward -X -Z. Python: 4.0531495
	rig = create_third_person_camera(facing = math.PI / 4)
	testing.expect(t, near(rig.camera.position, {4.0531495, 3.3731212, 4.0531495}))
}

@(test)
shoulder_slides_position_and_target_together :: proc(t:^testing.T) {
	centre := create_third_person_camera()
	right := create_third_person_camera(shoulder = .RIGHT)
	left := create_third_person_camera(shoulder = .LEFT)

	// Camera-right at yaw 0 is +X; the view direction does not change, so nothing turns
	testing.expect(t, near(right.camera.position - centre.camera.position, {0.75, 0, 0}))
	testing.expect(t, near(right.camera.target - centre.camera.target, {0.75, 0, 0}))
	testing.expect(t, near(left.camera.position - centre.camera.position, {-0.75, 0, 0}))

	// Checked against the camera's own right vector rather than the formula in the rig
	testing.expect(t, near(calculate_camera_right(centre.camera), {1, 0, 0}))
}

@(test)
third_person_distance_is_clamped_by_the_constructor :: proc(t:^testing.T) {
	testing.expect_value(t, create_third_person_camera(distance = 100).distance, 20)
	testing.expect_value(t, create_third_person_camera(distance = 0.1).distance, 1.5)
}

@(test)
walk_direction_is_flat_and_never_longer_than_one :: proc(t:^testing.T) {
	// Forward at yaw 0 is -Z; right is +X
	testing.expect(t, near(calculate_walk_direction(0, {0, 1}), {0, 0, -1}))
	testing.expect(t, near(calculate_walk_direction(0, {1, 0}), {1, 0, 0}))
	// Yaw 90 (turned left): forward is -X, right is -Z
	testing.expect(t, near(calculate_walk_direction(math.PI * 0.5, {0, 1}), {-1, 0, 0}))
	testing.expect(t, near(calculate_walk_direction(math.PI * 0.5, {1, 0}), {0, 0, -1}))
	// A diagonal is not faster than a straight line, and half a push is half a step
	testing.expect(t, abs(linalg.length(calculate_walk_direction(0.3, {1, 1})) - 1) < 1e-5)
	testing.expect(t, near(calculate_walk_direction(0, {0, 0.5}), {0, 0, -0.5}))
	testing.expect(t, calculate_walk_direction(0, {0, 0}) == {0, 0, 0})
}

@(test)
yaw_from_direction_undoes_the_walk_direction :: proc(t:^testing.T) {
	for yaw in ([]f32{0, 0.5, 1.5, -2, 3}) {
		forward, _ := calculate_yaw_axes(yaw)
		testing.expectf(t, abs(math.angle_diff(calculate_yaw_from_direction(forward), yaw)) < 1e-4, "yaw %v", yaw)
	}
	testing.expect_value(t, calculate_yaw_from_direction({0, 3, 0}), 0)
}

@(test)
turn_angle_toward_takes_the_short_way_round :: proc(t:^testing.T) {
	// 3.0 to -3.0 is 0.283 radians across the wrap, not 6 the other way; one step of 0.1 goes up
	angle:f32 = 3.0
	turn_angle_toward(&angle, -3.0, 1, 0.1)
	testing.expectf(t, abs(angle - 3.1) < 1e-5, "stepped to %v", angle)

	// Within one step it lands exactly on the target
	angle = 3.0
	turn_angle_toward(&angle, -3.0, 10, 0.1)
	testing.expect_value(t, angle, -3.0)

	angle = 0
	turn_angle_toward(&angle, -1, 1, 0.25)
	testing.expectf(t, abs(angle + 0.25) < 1e-6, "stepped to %v", angle)
}

@(test)
facing_rotation_points_a_model_along_the_yaw :: proc(t:^testing.T) {
	// A model that faces -Z turned to yaw 90 faces -X
	turned := linalg.quaternion_mul_vector3(calculate_facing_rotation(math.PI * 0.5), [3]f32{0, 0, -1})
	testing.expect(t, near(turned, {-1, 0, 0}))

	// Each authored facing is brought onto -Z first, so yaw 0 always looks down -Z
	for own_forward, facing in ([Model_Facing][3]f32{.NEG_Z = {0, 0, -1}, .POS_X = {1, 0, 0}, .POS_Z = {0, 0, 1}, .NEG_X = {-1, 0, 0}}) {
		result := linalg.quaternion_mul_vector3(calculate_facing_rotation(0, facing), own_forward)
		testing.expectf(t, near(result, {0, 0, -1}), "%v became %v", facing, result)
	}
}

@(test)
aim_rotation_pitches_about_the_yawed_right_axis :: proc(t:^testing.T) {
	// Yaw 90 then pitch 90 up: forward (-X) must tip to straight up, not roll
	tipped := linalg.quaternion_mul_vector3(calculate_aim_rotation(math.PI * 0.5, math.PI * 0.5), [3]f32{0, 0, -1})
	testing.expect(t, near(tipped, {0, 1, 0}))

	level := linalg.quaternion_mul_vector3(calculate_aim_rotation(math.PI * 0.5, 0), [3]f32{0, 0, -1})
	testing.expect(t, near(level, {-1, 0, 0}))
}
