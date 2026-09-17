package matchbox

/*
	Drift camera -- the leash, the lag and the swing
	-----------------------------------------------
	Everything this rig does is a number that is nearly right: an anchor that
	catches up a little too fast, a leash that quietly pulls to the character
	instead of stopping short of them, a camera that drifts at one speed at 60fps
	and another at 30. None of those look like a bug on a test scene -- they look
	like the camera, and you tune around them for an afternoon before finding out
	the maths was wrong. So each is pinned to a number here.

	The rig is set up with `pitch = 0`, `distance = 6` and no `focus_offset`, so
	the camera sits at `anchor + {-6, 0, 0}` and its target is the anchor itself.
	That makes every assertion below about the anchor an assertion about the
	picture, without a sin or a cos in the way.

	No GPU and no `init`: the rig only writes a `Camera3D`.
*/

import "core:math"
import "core:math/linalg"
import "core:testing"

@(private="file")
DT :: f32(1.0 / 60.0)

// A rig whose camera is 6 units west of its anchor, looking east at it.
@(private="file")
plain_rig :: proc(position: [3]f32 = {0, 0, 0}, dead_zone: f32 = 1.5) -> Drift_Camera {
	return create_drift_camera(position,
		yaw          = 0,
		pitch        = 0,
		distance     = 6,
		dead_zone    = dead_zone,
		follow_speed = 3,
		focus_offset = {0, 0, 0})
}

@(private="file")
near :: proc(a, b: [3]f32) -> bool {
	return linalg.length(a - b) < 1e-4
}

// Walks the rig for `seconds` with the character standing still at `position`.
//
// Rounded rather than truncated: `DT` is a float, `1 / DT` is a hair under 60,
// and a test asking for a second of frames would silently get 59 of them --
// which is exactly enough to miss a `turn_toward` landing on its target.
@(private="file")
hold :: proc(rig: ^Drift_Camera, position: [3]f32, seconds: f32) {
	for _ in 0 ..< int(math.round(seconds / DT)) {
		drift_camera_follow(rig, position, DT)
	}
}

// The rig is a real camera before the first follow, rather than the zero
// Camera3D -- whose position and target are the same point.
@(test)
test_drift_camera_is_seated_by_the_constructor :: proc(t: ^testing.T) {
	rig := plain_rig({4, 0, 0})

	testing.expect_value(t, rig.anchor, [3]f32{4, 0, 0})
	testing.expect(t, near(rig.camera.position, {-2, 0, 0}), "camera 6 west of the anchor")
	testing.expect(t, near(rig.camera.target, {4, 0, 0}), "looking at the anchor")
}

// The offset is added to the anchor, not to the character: the camera aims
// above the feet and stays exactly `distance` from what it aims at.
@(test)
test_drift_camera_looks_at_the_anchor_plus_the_offset :: proc(t: ^testing.T) {
	rig := create_drift_camera({0, 0, 0}, yaw = 0, pitch = 0, distance = 6,
		focus_offset = {0, 1.6, 0})

	testing.expectf(t, near(rig.camera.target, {0, 1.6, 0}), "target %v", rig.camera.target)
	testing.expectf(t, abs(linalg.length(rig.camera.target - rig.camera.position) - 6) < 1e-4,
		"distance %v", linalg.length(rig.camera.target - rig.camera.position))
}

// The whole point of the dead zone: a step that stays inside it moves the
// camera not a little but not at all. A rig that eased toward the character
// here would slide the scene on every footfall.
@(test)
test_drift_camera_does_not_move_inside_the_dead_zone :: proc(t: ^testing.T) {
	rig := plain_rig()
	seated := rig.camera.position

	hold(&rig, {1.4, 0, 0}, 5)

	testing.expect_value(t, rig.anchor, [3]f32{0, 0, 0})
	testing.expect_value(t, rig.camera.position, seated)
}

/*
	Outside it, the anchor is dragged to `dead_zone` short of the character and
	no further -- the leash. Pulling all the way onto them is the mistake that
	turns this rig into a lagging third-person camera: the character would end up
	centred in frame once they stopped, instead of standing off to the side they
	walked in from.
*/
@(test)
test_drift_camera_stops_a_dead_zone_short_of_the_character :: proc(t: ^testing.T) {
	rig := plain_rig()

	hold(&rig, {5, 0, 0}, 5)

	testing.expectf(t, abs(rig.anchor.x - 3.5) < 1e-3, "anchor %v, wanted 3.5", rig.anchor.x)
	testing.expectf(t, rig.anchor.x <= 3.5, "anchor %v overran the leash", rig.anchor.x)
	testing.expect_value(t, rig.anchor.z, f32(0))
}

// And it gets there gradually. A single frame closes a fraction of the gap,
// which is the lag `follow_speed` describes -- 1 - exp(-3/60) of it, or about
// five per cent.
@(test)
test_drift_camera_lags_rather_than_snapping :: proc(t: ^testing.T) {
	rig := plain_rig()

	drift_camera_follow(&rig, {5, 0, 0}, DT)

	want := f32(3.5) * (1 - math.exp(f32(-3) * DT))
	testing.expectf(t, abs(rig.anchor.x - want) < 1e-5, "anchor %v, wanted %v", rig.anchor.x, want)
}

/*
	What the camera settles to while the character keeps walking, which is the
	number to tune with and the one a game notices: `dead_zone + speed /
	follow_speed`, off the back of the character.

	Not the dead zone on its own. The leash is where the anchor is being pulled
	to, and at `follow_speed` it never quite gets there while the target keeps
	moving -- so a character who walks off at 4 units a second under a rate of 3
	is followed from 1.5 + 1.33 units back, not 1.5. Halve the rate and they are
	followed from 4.2, which is a different shot.

	Checked against the same walk stepped in Python, which agreed to within
	`speed * dt / 2` -- half a frame of walking, and exactly the gap you would
	expect between a continuous prediction and a loop that moves the character
	before it eases the camera.
*/
@(test)
test_drift_camera_settles_a_predictable_distance_behind_a_walk :: proc(t: ^testing.T) {
	rig := plain_rig()

	speed := f32(4)
	walked := f32(0)
	for _ in 0 ..< int(math.round(20 / DT)) {
		walked += speed * DT
		drift_camera_follow(&rig, {walked, 0, 0}, DT)
	}

	trail := walked - rig.anchor.x
	want  := rig.dead_zone + speed / rig.follow_speed

	testing.expectf(t, abs(trail - want) <= speed * DT * 0.5 + 1e-4,
		"trailing by %v, predicted %v", trail, want)
}

/*
	The same drift however the frame time is chopped up.

	This is what `1 - exp(-rate * dt)` buys over the linear form, and it is
	checked rather than asserted because the linear form passes every other test
	in this file: fifty steps of 0.01 at rate 3 close 78.2% of the gap while one
	step of 0.5 closes all of it, clamped, so a stalled frame snaps the camera to
	the leash. The exponential is exactly composable, and the two runs below
	agree to float precision.
*/
@(test)
test_drift_camera_drifts_the_same_at_any_frame_rate :: proc(t: ^testing.T) {
	stutter := plain_rig()
	smooth  := plain_rig()

	drift_camera_follow(&stutter, {5, 0, 0}, 0.5)
	for _ in 0 ..< 50 {
		drift_camera_follow(&smooth, {5, 0, 0}, 0.01)
	}

	testing.expectf(t, abs(stutter.anchor.x - smooth.anchor.x) < 1e-4,
		"one frame of 0.5 gave %v, fifty of 0.01 gave %v", stutter.anchor.x, smooth.anchor.x)
}

// A rate of zero is "does not follow", the reading camera.odin's `camera_follow`
// already gives it. A negative one is the same rather than an ease away from the
// character, which is the shape the arithmetic would otherwise take.
@(test)
test_drift_camera_with_no_follow_speed_stays_put :: proc(t: ^testing.T) {
	still := plain_rig()
	still.follow_speed = 0

	backwards := plain_rig()
	backwards.follow_speed = -3

	hold(&still, {20, 0, 20}, 2)
	hold(&backwards, {20, 0, 20}, 2)

	testing.expect_value(t, still.anchor, [3]f32{0, 0, 0})
	testing.expect_value(t, backwards.anchor, [3]f32{0, 0, 0})
}

/*
	Height is not on the leash. A character dropping three units without moving
	horizontally is followed down; a leash in three dimensions would have left
	the camera a metre and a half above them, framing the ceiling they just
	walked out from under.
*/
@(test)
test_drift_camera_follows_height_with_no_dead_zone :: proc(t: ^testing.T) {
	rig := plain_rig()

	hold(&rig, {0, -3, 0}, 5)

	testing.expectf(t, abs(rig.anchor.y - (-3)) < 1e-3, "anchor y %v, wanted -3", rig.anchor.y)
	testing.expect_value(t, rig.anchor.x, f32(0))
	testing.expect_value(t, rig.anchor.z, f32(0))
}

// The default rig never turns: the angle is the level's. This is the difference
// between this and every camera that sits behind the character's heading.
@(test)
test_drift_camera_keeps_its_angle_by_default :: proc(t: ^testing.T) {
	rig := plain_rig()

	hold(&rig, {0, 0, 20}, 5)

	testing.expect_value(t, rig.yaw, f32(0))
	testing.expectf(t, rig.camera.position.x - rig.camera.target.x < -5.9,
		"camera still west of the anchor, at %v", rig.camera.position)
}

// With a swing it creeps round to look the way the character is walking, and
// lands exactly on it rather than easing in forever. Walking north is yaw
// pi/2; a radian a second gets there inside two seconds and stops.
@(test)
test_drift_camera_swings_toward_the_walk :: proc(t: ^testing.T) {
	rig := plain_rig()
	rig.swing_speed = 1

	hold(&rig, {0, 0, 20}, 1)
	testing.expectf(t, abs(rig.yaw - 1) < 1e-4, "a radian after a second, got %v", rig.yaw)

	hold(&rig, {0, 0, 20}, 2)
	testing.expectf(t, abs(rig.yaw - math.PI * 0.5) < 1e-5,
		"landed on pi/2, got %v", rig.yaw)
}

// The swing is driven by the drag, not by the character's feet: someone pacing
// about inside the dead zone is walking somewhere every frame, and a camera that
// swung for it would never be still.
@(test)
test_drift_camera_does_not_swing_inside_the_dead_zone :: proc(t: ^testing.T) {
	rig := plain_rig()
	rig.swing_speed = 4

	hold(&rig, {0, 0, 1.4}, 5)

	testing.expect_value(t, rig.yaw, f32(0))
}

// A warp puts the camera where it would have settled, rather than sending it
// across the level to catch up.
@(test)
test_drift_camera_snap_takes_the_anchor_with_it :: proc(t: ^testing.T) {
	rig := plain_rig()
	hold(&rig, {5, 0, 0}, 1)

	drift_camera_snap(&rig, {20, 0, 20})

	testing.expect_value(t, rig.anchor, [3]f32{20, 0, 20})
	testing.expectf(t, near(rig.camera.position, {14, 0, 20}), "camera %v", rig.camera.position)
	testing.expectf(t, near(rig.camera.target, {20, 0, 20}), "target %v", rig.camera.target)
}

// A dead zone written negative is read as none. The interesting part is the
// character standing exactly on the anchor, where the direction of the drag is
// a zero vector waiting to be normalised.
@(test)
test_drift_camera_survives_a_negative_dead_zone :: proc(t: ^testing.T) {
	rig := plain_rig({0, 0, 0}, dead_zone = -2)
	rig.swing_speed = 1

	drift_camera_follow(&rig, {0, 0, 0}, DT)
	testing.expect_value(t, rig.anchor, [3]f32{0, 0, 0})
	testing.expect_value(t, rig.yaw, f32(0))

	// And with none, the anchor is pulled to the character rather than short of
	// them: a plain damped follow, which is what dead_zone = 0 means.
	hold(&rig, {5, 0, 0}, 5)
	testing.expectf(t, abs(rig.anchor.x - 5) < 1e-3, "anchor %v, wanted 5", rig.anchor.x)
}
