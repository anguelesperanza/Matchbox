package matchbox

/*
	Tank and camera-relative movement
	---------------------------------
	Every direction here is a sign that can be wrong without anything looking
	broken on a symmetrical test scene: a right that is left, a camera-relative
	up that is down, a basis that is let go a frame too early. So each one is
	asserted as a number -- and where Matchbox already has an independent answer
	for a direction, `camera3d_right`, the test checks against that rather than
	against the formula being tested.

	`character_steer` takes its input as an argument, so almost nothing here
	touches `mbi`. The last two tests drive `get_movement_input` with synthetic
	key and pad state and put it back afterwards.
*/

import "core:math"
import "core:math/linalg"
import "core:testing"

@(private="file")
DT :: f32(1.0 / 60.0)

// Close enough for directions built out of sin and cos.
@(private="file")
near :: proc(a, b: [3]f32) -> bool {
	return linalg.length(a - b) < 1e-4
}

// Behind the origin on +z, looking toward -z: away from this camera is -z.
@(private="file")
facing_north :: proc() -> Camera3D {
	return create_camera3d({0, 5, 10}, {0, 0, 0})
}

// The opposite camera, looking toward +z -- what a cut to the far end of a
// corridor puts on screen.
@(private="file")
facing_south :: proc() -> Camera3D {
	return create_camera3d({0, 5, -10}, {0, 0, 0})
}

// -----------------------------------------------------------------------
// Tank
// -----------------------------------------------------------------------

@(test)
test_tank_up_walks_along_the_heading :: proc(t: ^testing.T) {
	controls := create_character_controls(facing = 0)
	character_steer(&controls, {0, 1}, facing_north(), DT)
	testing.expectf(t, near(controls.move, {1, 0, 0}), "facing +x, up moved %v", controls.move)

	controls = create_character_controls(facing = math.PI * 0.5)
	character_steer(&controls, {0, 1}, facing_north(), DT)
	testing.expectf(t, near(controls.move, {0, 0, 1}), "facing +z, up moved %v", controls.move)
}

// Left and right turn on the spot, at `tank_turn_speed`, and do not walk.
// Right increases the yaw, which is the same turn `walk_direction`'s D key
// steps toward.
@(test)
test_tank_turns_on_the_spot :: proc(t: ^testing.T) {
	controls := create_character_controls(facing = 0)

	character_steer(&controls, {1, 0}, facing_north(), 0.5)
	testing.expect_value(t, controls.facing, controls.tank_turn_speed * 0.5)
	testing.expect_value(t, controls.move, [3]f32{0, 0, 0})

	character_steer(&controls, {-1, 0}, facing_north(), 0.5)
	testing.expect_value(t, controls.facing, f32(0))
}

@(test)
test_tank_backwards_is_slower :: proc(t: ^testing.T) {
	controls := create_character_controls(facing = 0, backward_speed = 0.5)
	character_steer(&controls, {0, -1}, facing_north(), DT)

	testing.expectf(t, near(controls.move, {-0.5, 0, 0}), "backing up moved %v", controls.move)
}

/*
	The reason for per-axis rather than length: a diagonal of keys under tank
	controls is walking at full speed while turning at full speed. Normalising
	{1, 1} to a length of one would cut both to about 71%.
*/
@(test)
test_tank_diagonal_is_full_walk_and_full_turn :: proc(t: ^testing.T) {
	controls := create_character_controls(facing = 0)
	character_steer(&controls, {1, 1}, facing_north(), 0.1)

	testing.expect_value(t, controls.facing, controls.tank_turn_speed * 0.1)
	testing.expectf(t, abs(linalg.length(controls.move) - 1) < 1e-5,
		"a diagonal walked at length %v", linalg.length(controls.move))
}

// Tank controls do not know there is a camera. The same input under two
// opposite cameras gives the same answer.
@(test)
test_tank_ignores_the_camera :: proc(t: ^testing.T) {
	north := create_character_controls(facing = 0.3)
	south := create_character_controls(facing = 0.3)

	character_steer(&north, {0.4, 0.8}, facing_north(), DT)
	character_steer(&south, {0.4, 0.8}, facing_south(), DT)

	testing.expect_value(t, north.facing, south.facing)
	testing.expect_value(t, north.move, south.move)
}

// -----------------------------------------------------------------------
// Camera-relative
// -----------------------------------------------------------------------

// Up walks away from the camera; right walks along `camera3d_right`, which is
// worked out by a cross product rather than by the sin and cos under test.
@(test)
test_camera_relative_reads_the_stick_against_the_camera :: proc(t: ^testing.T) {
	for camera in ([]Camera3D{facing_north(), facing_south()}) {
		forward := camera.target - camera.position
		forward  = linalg.normalize([3]f32{forward.x, 0, forward.z})

		controls := create_character_controls(scheme = .CAMERA_RELATIVE)
		character_steer(&controls, {0, 1}, camera, DT)
		testing.expectf(t, near(controls.move, forward), "up moved %v, away from the camera is %v", controls.move, forward)

		controls = create_character_controls(scheme = .CAMERA_RELATIVE)
		character_steer(&controls, {1, 0}, camera, DT)
		right := camera3d_right(camera)
		testing.expectf(t, near(controls.move, right), "right moved %v, camera3d_right is %v", controls.move, right)
	}
}

@(test)
test_camera_relative_diagonal_is_not_faster :: proc(t: ^testing.T) {
	controls := create_character_controls(scheme = .CAMERA_RELATIVE)
	character_steer(&controls, {1, 1}, facing_north(), DT)

	testing.expectf(t, abs(linalg.length(controls.move) - 1) < 1e-5,
		"a diagonal walked at length %v", linalg.length(controls.move))
}

/*
	The bug `hold_basis` exists for, with it on. Hold up under one camera, cut
	to a camera looking the other way, keep holding up: the character must keep
	walking the way it was, not turn round.
*/
@(test)
test_hold_basis_walks_straight_through_a_cut :: proc(t: ^testing.T) {
	controls := create_character_controls(scheme = .CAMERA_RELATIVE)

	character_steer(&controls, {0, 1}, facing_north(), DT)
	testing.expect(t, near(controls.move, {0, 0, -1}), "up under the first camera did not walk away from it")
	testing.expect(t, controls.basis_held, "pushing the stick did not take a basis")

	for _ in 0 ..< 30 {
		character_steer(&controls, {0, 1}, facing_south(), DT)
		testing.expectf(t, near(controls.move, {0, 0, -1}), "after the cut, up moved %v", controls.move)
	}
}

// The same cut with the hold off turns the run round on the spot, which is
// the behaviour being prevented -- asserted so the test above cannot pass by
// accident, for instance with two cameras that happen to agree.
@(test)
test_without_hold_basis_a_cut_turns_the_run_round :: proc(t: ^testing.T) {
	controls := create_character_controls(scheme = .CAMERA_RELATIVE, hold_basis = false)

	character_steer(&controls, {0, 1}, facing_north(), DT)
	testing.expect(t, near(controls.move, {0, 0, -1}), "up under the first camera did not walk away from it")

	character_steer(&controls, {0, 1}, facing_south(), DT)
	testing.expectf(t, near(controls.move, {0, 0, 1}), "without the hold, up after the cut moved %v", controls.move)
	testing.expect(t, !controls.basis_held, "a basis was held with hold_basis off")
}

// Letting go is what hands the stick to the new camera.
@(test)
test_releasing_the_stick_takes_the_new_camera :: proc(t: ^testing.T) {
	controls := create_character_controls(scheme = .CAMERA_RELATIVE)

	character_steer(&controls, {0, 1}, facing_north(), DT)
	character_steer(&controls, {0, 1}, facing_south(), DT)

	character_steer(&controls, {0, 0}, facing_south(), DT)
	testing.expect_value(t, controls.move, [3]f32{0, 0, 0})
	testing.expect(t, !controls.basis_held, "a resting stick still held a basis")

	character_steer(&controls, {0, 1}, facing_south(), DT)
	testing.expectf(t, near(controls.move, {0, 0, 1}), "pushing up again after letting go moved %v", controls.move)
}

/*
	Swinging the stick further than `hold_tolerance` is a new intention, and
	takes the camera on screen. Up to right is a quarter turn, past the
	default of a sixth of a turn.
*/
@(test)
test_swinging_past_the_tolerance_takes_the_new_camera :: proc(t: ^testing.T) {
	controls := create_character_controls(scheme = .CAMERA_RELATIVE)

	character_steer(&controls, {0, 1}, facing_north(), DT)
	character_steer(&controls, {0, 1}, facing_south(), DT)
	character_steer(&controls, {1, 0}, facing_south(), DT)

	right := camera3d_right(facing_south())
	testing.expectf(t, near(controls.move, right), "right after the swing moved %v, the new camera's right is %v", controls.move, right)
}

/*
	Adding a diagonal key to a held one is a correction, not a new intention --
	45 degrees, inside the default tolerance -- and keeps the old camera. This
	is the case the tolerance's number was chosen for.
*/
@(test)
test_adding_a_diagonal_keeps_the_held_basis :: proc(t: ^testing.T) {
	controls := create_character_controls(scheme = .CAMERA_RELATIVE)

	character_steer(&controls, {0, 1}, facing_north(), DT)
	character_steer(&controls, {0, 1}, facing_south(), DT)
	character_steer(&controls, {1, 1}, facing_south(), DT)

	old_forward := [3]f32{0, 0, -1}
	old_right   := camera3d_right(facing_north())
	expected    := linalg.normalize(old_forward + old_right)

	testing.expectf(t, near(controls.move, expected), "up-right after the cut moved %v, expected %v", controls.move, expected)
}

// The body turns to face the run at `turn_speed`, lands exactly on it, and a
// character who stops keeps the heading they had.
@(test)
test_camera_relative_turns_the_body_toward_the_run :: proc(t: ^testing.T) {
	controls := create_character_controls(facing = 0, scheme = .CAMERA_RELATIVE, turn_speed = 12)

	// One second at 12 radians per second is far more than the quarter turn
	// needed, so the heading lands on the run: toward -z, yaw -pi/2.
	character_steer(&controls, {0, 1}, facing_north(), 1)
	testing.expectf(t, abs(controls.facing - (-math.PI * 0.5)) < 1e-5, "facing %v after turning toward -z", controls.facing)

	before := controls.facing
	character_steer(&controls, {0, 0}, facing_south(), 1)
	testing.expect_value(t, controls.facing, before)
}

/*
	A camera looking straight down has no forward left once the height is
	taken out. Its `up` is the top of the screen, so that is what up on the
	stick follows -- and the answer must be a number, not a NaN out of
	normalising a zero vector.
*/
@(test)
test_straight_down_camera_reads_its_up :: proc(t: ^testing.T) {
	camera := Camera3D{position = {0, 10, 0}, target = {0, 0, 0}, up = {0, 0, -1}}

	controls := create_character_controls(scheme = .CAMERA_RELATIVE)
	character_steer(&controls, {0, 1}, camera, DT)

	testing.expectf(t, near(controls.move, {0, 0, -1}), "up under a straight-down camera moved %v", controls.move)
}

// A camera with no heading at all keeps whatever basis was already there,
// rather than producing a NaN or snapping the run east.
@(test)
test_headingless_camera_keeps_the_previous_basis :: proc(t: ^testing.T) {
	controls := create_character_controls(scheme = .CAMERA_RELATIVE)
	character_steer(&controls, {0, 1}, facing_north(), DT)

	// Released under a camera with no heading, then pushed again under it.
	nothing := Camera3D{position = {0, 5, 0}, target = {0, 5, 0}, up = {0, 1, 0}}
	character_steer(&controls, {0, 0}, nothing, DT)
	character_steer(&controls, {0, 1}, nothing, DT)

	testing.expectf(t, near(controls.move, {0, 0, -1}), "under a headingless camera, up moved %v", controls.move)
}

// Switching to tank controls lets go of a held basis, so switching back takes
// the camera on screen at the next push rather than one from before.
@(test)
test_switching_scheme_lets_go_of_the_basis :: proc(t: ^testing.T) {
	controls := create_character_controls(scheme = .CAMERA_RELATIVE)
	character_steer(&controls, {0, 1}, facing_north(), DT)

	controls.scheme = .TANK
	character_steer(&controls, {0, 1}, facing_south(), DT)
	testing.expect(t, !controls.basis_held, "tank controls kept a camera-relative basis")

	controls.scheme = .CAMERA_RELATIVE
	character_steer(&controls, {0, 1}, facing_south(), DT)
	testing.expectf(t, near(controls.move, {0, 0, 1}), "after switching back, up moved %v", controls.move)
}

// -----------------------------------------------------------------------
// Reading the input
// -----------------------------------------------------------------------

@(test)
test_movement_input_reads_the_keys :: proc(t: ^testing.T) {
	saved := mbi.input.keys
	defer mbi.input.keys = saved
	mbi.input.keys = {}

	testing.expect_value(t, get_movement_input(-1), [2]f32{0, 0})

	mbi.input.keys[.W].pressing = true
	mbi.input.keys[.D].pressing = true
	testing.expect_value(t, get_movement_input(-1), [2]f32{1, 1})

	// The arrow and the letter for the same direction are one direction, not two.
	mbi.input.keys[.UP].pressing = true
	testing.expect_value(t, get_movement_input(-1), [2]f32{1, 1})

	// Opposite keys cancel.
	mbi.input.keys = {}
	mbi.input.keys[.LEFT].pressing  = true
	mbi.input.keys[.RIGHT].pressing = true
	mbi.input.keys[.S].pressing     = true
	testing.expect_value(t, get_movement_input(-1), [2]f32{0, -1})
}

/*
	A stick pushed up reports a negative y from `get_gamepad_stick`, and
	must come out of here as walking forward. Keys and stick together still
	clamp at one.
*/
@(test)
test_movement_input_reads_a_pad_up_as_forward :: proc(t: ^testing.T) {
	saved_pad, saved_keys, saved_deadzone := mbi.input.gamepads[0], mbi.input.keys, mbi.input.gamepad_deadzone
	defer {
		mbi.input.gamepads[0]      = saved_pad
		mbi.input.keys             = saved_keys
		mbi.input.gamepad_deadzone = saved_deadzone
	}

	mbi.input.keys = {}
	mbi.input.gamepad_deadzone = GAMEPAD_DEFAULTS.stick_deadzone
	mbi.input.gamepads[0] = Gamepad{connected = true}
	mbi.input.gamepads[0].axes[.LEFTY] = -1

	testing.expect_value(t, get_movement_input(0), [2]f32{0, 1})

	// pad -1 leaves the pad out.
	testing.expect_value(t, get_movement_input(-1), [2]f32{0, 0})

	mbi.input.keys[.W].pressing = true
	mbi.input.gamepads[0].buttons[.DPAD_UP].pressing = true
	testing.expect_value(t, get_movement_input(0), [2]f32{0, 1})
}
