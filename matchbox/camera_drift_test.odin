#+build windows

package matchbox

/*
	The drift camera's numbers, worked out by hand: the anchor stops a dead zone short of the character, a
	frame closes 1 - exp(-rate * dt) of the gap, and a walker is followed from dead_zone + speed / follow_speed
	back (checked against the same walk stepped in Python on main). None of these touch `mbi`.
*/

import "core:math"
import "core:math/linalg"
import "core:testing"

@(private="file")
DT :: f32(1.0 / 60.0)

// No height offset and a camera looking straight along -Z, so every number reads off an axis
@(private="file")
plain_rig :: proc() -> Drift_Camera {
	return create_drift_camera(yaw = 0, pitch = 0, distance = 5, dead_zone = 1.5, follow_speed = 3, focus_offset = {0, 0, 0})
}

@(private="file")
hold :: proc(rig:^Drift_Camera, position:[3]f32, seconds:f32) {
	for _ in 0 ..< int(math.round(seconds / DT)) do follow_drift_camera(rig, position, DT)
}

@(test)
drift_camera_is_seated_by_the_constructor :: proc(t:^testing.T) {
	rig := create_drift_camera({10, 0, 4}, yaw = 0, pitch = 0, distance = 5, focus_offset = {0, 1, 0})
	// Looking along -Z from 5 back: the camera stands at +Z, the target is the anchor plus the offset
	testing.expect(t, linalg.length(rig.camera.position - [3]f32{10, 1, 9}) < 1e-5)
	testing.expect(t, linalg.length(rig.camera.target - [3]f32{10, 1, 4}) < 1e-5)
}

@(test)
drift_camera_does_not_move_inside_the_dead_zone :: proc(t:^testing.T) {
	rig := plain_rig()
	hold(&rig, {1.4, 0, 0}, 1)
	testing.expect_value(t, rig.anchor, [3]f32{0, 0, 0})
}

@(test)
drift_camera_stops_a_dead_zone_short_of_the_character :: proc(t:^testing.T) {
	rig := plain_rig()
	hold(&rig, {5, 0, 0}, 5)
	testing.expectf(t, abs(rig.anchor.x - 3.5) < 1e-3, "anchor %v, wanted 3.5", rig.anchor.x)
	testing.expectf(t, rig.anchor.x <= 3.5, "anchor %v overran the leash", rig.anchor.x)
}

@(test)
drift_camera_closes_a_fraction_of_the_gap_each_frame :: proc(t:^testing.T) {
	rig := plain_rig()
	follow_drift_camera(&rig, {5, 0, 0}, DT)
	want := f32(3.5) * (1 - math.exp(f32(-3) * DT)) // 3.5 is the gap to the leash; Python: 0.17069701
	testing.expectf(t, abs(rig.anchor.x - want) < 1e-5 && abs(want - 0.170697) < 1e-5, "anchor %v, wanted %v", rig.anchor.x, want)
}

@(test)
drift_camera_settles_a_predictable_distance_behind_a_walk :: proc(t:^testing.T) {
	rig := plain_rig()
	speed:f32 = 4
	walked:f32
	for _ in 0 ..< int(math.round(20 / DT)) {
		walked += speed * DT
		follow_drift_camera(&rig, {walked, 0, 0}, DT)
	}
	trail := walked - rig.anchor.x
	want := rig.dead_zone + speed / rig.follow_speed // 1.5 + 1.333
	testing.expectf(t, abs(trail - want) <= speed * DT * 0.5 + 1e-4, "trailing by %v, predicted %v", trail, want)
}

@(test)
drift_camera_drifts_the_same_at_any_frame_rate :: proc(t:^testing.T) {
	stutter := plain_rig()
	smooth := plain_rig()
	follow_drift_camera(&stutter, {5, 0, 0}, 0.5)
	for _ in 0 ..< 50 do follow_drift_camera(&smooth, {5, 0, 0}, 0.01)
	testing.expectf(t, abs(stutter.anchor.x - smooth.anchor.x) < 1e-4, "0.5 gave %v, fifty of 0.01 gave %v", stutter.anchor.x, smooth.anchor.x)
}

@(test)
drift_camera_with_no_follow_speed_stays_put :: proc(t:^testing.T) {
	still := plain_rig()
	still.follow_speed = 0
	backwards := plain_rig()
	backwards.follow_speed = -3
	hold(&still, {20, 0, 20}, 2)
	hold(&backwards, {20, 0, 20}, 2)
	testing.expect_value(t, still.anchor, [3]f32{0, 0, 0})
	testing.expect_value(t, backwards.anchor, [3]f32{0, 0, 0})
}

@(test)
drift_camera_follows_height_with_no_dead_zone :: proc(t:^testing.T) {
	rig := plain_rig()
	hold(&rig, {0, 3, 0}, 5)
	testing.expectf(t, abs(rig.anchor.y - 3) < 1e-3, "anchor height %v", rig.anchor.y)
}

@(test)
drift_camera_keeps_its_angle_by_default_and_swings_when_asked :: proc(t:^testing.T) {
	rig := plain_rig()
	hold(&rig, {20, 0, 0}, 3)
	testing.expect_value(t, rig.yaw, f32(0))

	// Walking toward +X is a yaw of -90 (turning right from -Z); a swing of 1 rad/s gets there over time
	rig.swing_speed = 1
	hold(&rig, {40, 0, 0}, 2)
	testing.expectf(t, abs(rig.yaw + 1) < 0.05 || rig.yaw < -1, "yaw after 2 s of swing %v", rig.yaw)
	hold(&rig, {60, 0, 0}, 3)
	testing.expectf(t, abs(rig.yaw + math.PI * 0.5) < 1e-4, "settled yaw %v, wanted -pi/2", rig.yaw)
}

@(test)
drift_camera_does_not_swing_inside_the_dead_zone :: proc(t:^testing.T) {
	rig := plain_rig()
	rig.swing_speed = 5
	hold(&rig, {1, 0, 1}, 2)
	testing.expect_value(t, rig.yaw, f32(0))
}

@(test)
drift_camera_snap_takes_the_anchor_with_it :: proc(t:^testing.T) {
	rig := plain_rig()
	snap_drift_camera(&rig, {30, 2, -8})
	testing.expect_value(t, rig.anchor, [3]f32{30, 2, -8})
	testing.expect(t, linalg.length(rig.camera.target - [3]f32{30, 2, -8}) < 1e-5)
}

@(test)
drift_camera_survives_a_negative_dead_zone :: proc(t:^testing.T) {
	rig := plain_rig()
	rig.dead_zone = -4
	hold(&rig, {5, 0, 0}, 5)
	testing.expectf(t, abs(rig.anchor.x - 5) < 1e-3, "a negative dead zone is none: anchor %v", rig.anchor.x)
}
