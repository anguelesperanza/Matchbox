package matchbox

import "core:math"
import "core:math/linalg"

/*
	Character movement: tank and camera-relative
	============================================
	How a character is steered when the player is not holding the camera (a fixed, drift or scripted one).
	Tank controls read the stick against the character: up walks forward, left and right turn on the spot.
	Camera-relative controls read it against the camera: up walks away from it, and the body turns to face
	where it goes. Nothing is moved here: steer_character writes `move`, and adding it to a position is the game's.
*/

/*What the stick is read against*/
Control_Scheme :: enum {
	TANK, // against the character; a cut to a camera looking the other way changes nothing
	CAMERA_RELATIVE, // against the camera; see Character_Controls.hold_basis for what a cut does
}

/*A character's heading and how the stick steers it*/
Character_Controls :: struct {
	facing:f32, // which way the character faces, as a yaw; draw it with calculate_facing_rotation
	move:[3]f32, // which way this frame's input asked to go, flat, 0 to 1 long; written by steer_character
	scheme:Control_Scheme,
	tank_turn_speed:f32, // TANK: radians per second at a full turn; three is a half turn in about a second
	backward_speed:f32, // TANK: the fraction of forward speed that walking backwards gets
	turn_speed:f32, // CAMERA_RELATIVE: radians per second the body turns to face where it runs

	// CAMERA_RELATIVE: keep reading the stick against the camera it was first pushed under until it is
	// let go or swings further than `hold_tolerance`. Without it, walking through a cut to a camera that
	// looks the other way turns the character round and back into the shot it just left, forever.
	hold_basis:bool,
	hold_tolerance:f32, // radians the stick may swing from where it started; a correction is not a new intention

	basis_yaw:f32, // the camera heading the stick is being read against
	basis_input:[2]f32, // the stick as it was when that heading was taken
	basis_held:bool, // whether a basis is currently held: true while the stick is pushed
}

/*Character controls facing `facing`; tank unless told otherwise, since it works under any camera*/
create_character_controls :: proc(
	facing:f32 = 0,
	scheme:Control_Scheme = .TANK,
	tank_turn_speed:f32 = 3,
	backward_speed:f32 = 0.6,
	turn_speed:f32 = 12,
	hold_basis:bool = true,
	hold_tolerance:f32 = math.PI / 3, // a little over the 45 degrees between keyboard directions
) -> Character_Controls {
	return Character_Controls {
		facing = facing,
		scheme = scheme,
		tank_turn_speed = tank_turn_speed,
		backward_speed = backward_speed,
		turn_speed = turn_speed,
		hold_basis = hold_basis,
		hold_tolerance = hold_tolerance,
	}
}

/*Turns the character and works out `move` from `input` (x right, y up, as get_movement_input gives) under `camera`; TANK ignores the camera*/
steer_character :: proc(controls:^Character_Controls, input:[2]f32, camera:Camera, delta_time:f32) {
	switch controls.scheme {
	case .TANK:
		// Per axis: walk at full speed and turn at full speed are two controls, not one direction
		stick := [2]f32{clamp(input.x, -1, 1), clamp(input.y, -1, 1)}

		// No basis is held under tank, so switching scheme mid-stride reads the camera on screen at the next push
		controls.basis_held = false

		// Right turns clockwise seen from above, which is a smaller yaw; walking backwards does not reverse it
		controls.facing -= stick.x * controls.tank_turn_speed * delta_time

		throttle := stick.y
		if throttle < 0 do throttle *= controls.backward_speed

		// After the turn, so this frame's step goes the way the character now faces
		forward, _ := calculate_yaw_axes(controls.facing)
		controls.move = forward * throttle

	case .CAMERA_RELATIVE:
		// By length: a diagonal is one direction and must not be faster than a straight line
		stick := input
		if length := linalg.length(stick); length > 1 do stick /= length

		yaw := calculate_character_basis_yaw(controls, stick, camera)
		forward, right := calculate_yaw_axes(yaw)
		controls.move = forward * stick.y + right * stick.x

		// Only while running: a character who stops keeps its heading
		if controls.move != {0, 0, 0} {
			turn_angle_toward(&controls.facing, calculate_yaw_from_direction(controls.move), controls.turn_speed, delta_time)
		}
	}
}

/*steer_character with this frame's get_movement_input and the move added to `position`, for a character nothing else drives; `speed` is units per second*/
walk_character :: proc(controls:^Character_Controls, position:^[3]f32, speed:f32, camera:Camera, delta_time:f32) {
	steer_character(controls, get_movement_input(), camera, delta_time)
	position^ += controls.move * speed * delta_time
}

/*The heading to read a camera-relative stick against this frame, holding a basis through cuts when `hold_basis` is on*/
@(private)
calculate_character_basis_yaw :: proc(controls:^Character_Controls, stick:[2]f32, camera:Camera) -> f32 {
	camera_yaw, ok := calculate_camera_ground_yaw(camera)

	// A camera with no usable heading reads as the basis already held, not as straight ahead
	if !ok do camera_yaw = controls.basis_yaw

	// A basis is only ever taken from a pushed stick, so every later angle test has a real direction
	resting := linalg.length2(stick) < 1e-6

	if !controls.hold_basis || resting {
		controls.basis_yaw = camera_yaw
		controls.basis_input = stick
		controls.basis_held = false
		return camera_yaw
	}

	if !controls.basis_held || calculate_stick_swing(stick, controls.basis_input) > controls.hold_tolerance {
		controls.basis_yaw = camera_yaw
		controls.basis_input = stick
		controls.basis_held = true
	}

	return controls.basis_yaw
}

/*Which way "away from the camera" points on the ground, as a yaw; a camera looking straight down uses its `up` instead, and `ok` is false only when both are vertical*/
@(private)
calculate_camera_ground_yaw :: proc(camera:Camera) -> (yaw:f32, ok:bool) {
	forward := camera.target - camera.position
	if forward.x * forward.x + forward.z * forward.z > 1e-6 * linalg.length2(forward) && linalg.length2(forward) > 0 {
		return calculate_yaw_from_direction(forward), true
	}

	up := camera.up
	if up.x * up.x + up.z * up.z > 1e-6 {
		return calculate_yaw_from_direction(up), true
	}
	return 0, false
}

/*The angle between two non-zero stick directions, in radians*/
@(private)
calculate_stick_swing :: proc(a:[2]f32, b:[2]f32) -> f32 {
	cosine := linalg.dot(a, b) / (linalg.length(a) * linalg.length(b))
	return math.acos(clamp(cosine, -1, 1))
}
