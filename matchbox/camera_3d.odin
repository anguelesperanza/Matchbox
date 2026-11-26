package matchbox

import "core:math"
import "core:math/linalg"

/*
	3D cameras
	==========
	Helpers and the first- and third-person rigs, shared by all targets with no GPU code. A rig is one
	struct holding a `Camera` and the state that has to agree with it. Rigs never move a character: the
	position is passed in each frame, because a game with collision gets it from its solver.

	Angles are radians: yaw 0 looks down -Z and a positive yaw turns left; a positive pitch looks up.
	The drift and fixed cameras are in camera_drift.odin and camera_fixed.odin, steering in movement.odin.
*/

/*A perspective camera at `position` looking at `target`*/
create_camera_3d :: proc(position:[3]f32, target:[3]f32, fov_y:f32 = 70, near:f32 = 0.1, far:f32 = 1000) -> Camera {
	return Camera {
		position = position,
		target = target,
		up = {0, 1, 0},
		fov_y = fov_y,
		zoom = 1,
		near = near,
		far = far,
		projection = .PERSPECTIVE,
	}
}

/*The unit direction a camera looks along*/
calculate_camera_forward :: proc(camera:Camera) -> [3]f32 {
	return linalg.normalize(camera.target - camera.position)
}

/*The unit direction to the camera's right*/
calculate_camera_right :: proc(camera:Camera) -> [3]f32 {
	return linalg.normalize(linalg.cross(calculate_camera_forward(camera), camera.up))
}

/*The direction two angles look along: yaw 0 pitch 0 is -Z*/
calculate_direction_from_angles :: proc(yaw:f32, pitch:f32) -> [3]f32 {
	return {
		-math.sin(yaw) * math.cos(pitch),
		math.sin(pitch),
		-math.cos(yaw) * math.cos(pitch),
	}
}

/*The yaw and pitch a camera already looks along, to seed a rig so its first frame does not jump*/
calculate_camera_angles :: proc(camera:Camera) -> (yaw:f32, pitch:f32) {
	forward := calculate_camera_forward(camera)
	return math.atan2(-forward.x, -forward.z), math.asin(clamp(forward.y, -1, 1))
}

/*The yaw of a flat direction (its height is ignored); 0 for a zero direction*/
calculate_yaw_from_direction :: proc(direction:[3]f32) -> f32 {
	if direction.x == 0 && direction.z == 0 do return 0
	return math.atan2(-direction.x, -direction.z)
}

/*The flat direction W walks along for a yaw, and the direction D walks along*/
@(private)
calculate_yaw_axes :: proc(yaw:f32) -> (forward:[3]f32, right:[3]f32) {
	return {-math.sin(yaw), 0, -math.cos(yaw)}, {math.cos(yaw), 0, -math.sin(yaw)}
}

/*Where a movement push (x right, y forward, from get_movement_input) walks for a yaw: flat, at most one unit long, so a half push is a half step*/
calculate_walk_direction :: proc(yaw:f32, input:[2]f32) -> [3]f32 {
	forward, right := calculate_yaw_axes(yaw)

	direction := forward * input.y + right * input.x
	if linalg.length(direction) > 1 do direction = linalg.normalize(direction)
	return direction
}

/*Turns `angle` toward `target` the short way round, by at most `speed` radians a second*/
turn_angle_toward :: proc(angle:^f32, target:f32, speed:f32, delta_time:f32) {
	// Signed difference in (-pi, pi]: subtracting two raw angles can spin most of the way round
	difference := math.mod(target - angle^ + math.PI, math.TAU)
	if difference < 0 do difference += math.TAU
	difference -= math.PI

	step := speed * delta_time
	if abs(difference) <= step {
		angle^ = target
		return
	}
	angle^ += math.sign(difference) * step
}

/*Where an orbit camera sits: `distance` back from `focus` along the angles; cast a ray to it to keep the camera out of walls*/
calculate_orbit_position :: proc(focus:[3]f32, yaw:f32, pitch:f32, distance:f32) -> [3]f32 {
	return focus - calculate_direction_from_angles(yaw, pitch) * distance
}

/*Which way a model points in its own file; glTF's convention is -Z, VRoid models face +Z*/
Model_Facing :: enum {
	NEG_Z,
	POS_X,
	POS_Z,
	NEG_X,
}

/*The rotation that brings a model's own forward onto -Z*/
@(private)
calculate_model_facing_rotation :: proc(facing:Model_Facing) -> quaternion128 {
	angle:f32
	switch facing {
	case .NEG_Z: angle = 0
	case .POS_X: angle = math.PI * 0.5
	case .POS_Z: angle = math.PI
	case .NEG_X: angle = -math.PI * 0.5
	}
	return calculate_rotation_axis_angle({0, 1, 0}, angle)
}

/*The rotation that turns a model to face `yaw` (it turns but never tips)*/
calculate_facing_rotation :: proc(yaw:f32, facing:Model_Facing = .NEG_Z) -> quaternion128 {
	return calculate_rotation_axis_angle({0, 1, 0}, yaw) * calculate_model_facing_rotation(facing)
}

/*The rotation that tips a model along both angles, for first-person arms or a held weapon*/
calculate_aim_rotation :: proc(yaw:f32, pitch:f32, facing:Model_Facing = .NEG_Z) -> quaternion128 {
	turn := calculate_rotation_axis_angle({0, 1, 0}, yaw)
	// The pitch is about the yawed right axis, not world X, or a turned model would roll
	right := linalg.quaternion_mul_vector3(turn, [3]f32{1, 0, 0})
	return calculate_rotation_axis_angle(right, pitch) * turn * calculate_model_facing_rotation(facing)
}

/*How a view is turned and limited; yaw and pitch are the source and the camera's target is derived from them*/
Camera_Look :: struct {
	yaw:f32,
	pitch:f32,
	sensitivity:f32, // radians per pixel of drag
	stick_speed:f32, // radians per second at a full right-stick push
	pitch_min:f32, // just short of straight down or up, where the view matrix would collapse
	pitch_max:f32,
}

/*Turns the angles by this frame's drag and right stick and clamps the pitch; yaw is free to wind past a full turn*/
@(private)
update_camera_look :: proc(look:^Camera_Look, delta_time:f32) {
	turn := get_camera_look_input(look.sensitivity, look.stick_speed, delta_time)
	look.yaw += turn.x
	look.pitch = clamp(look.pitch + turn.y, look.pitch_min, look.pitch_max)
}

/*A first-person camera: the eye sits `eye_offset` above the body's position*/
First_Person_Camera :: struct {
	camera:Camera, // written by aim_first_person_camera
	look:Camera_Look,
	move:[3]f32, // which way the controls asked to go this frame, at most one unit long; written by update_first_person_input
	eye_offset:[3]f32, // added to the position being followed to get the eye
}

/*A first-person camera at `position` facing `yaw`, already seated so it can be drawn with this frame*/
create_first_person_camera :: proc(
	position:[3]f32 = {0, 0, 0},
	yaw:f32 = 0,
	pitch:f32 = 0,
	eye_offset:[3]f32 = {0, 1.7, 0},
	fov_y:f32 = 70,
	near:f32 = 0.1,
	far:f32 = 1000,
	sensitivity:f32 = 0.003,
	stick_speed:f32 = 2.5,
	pitch_min:f32 = -1.56,
	pitch_max:f32 = 1.56,
) -> First_Person_Camera {
	rig := First_Person_Camera {
		camera = create_camera_3d({}, {0, 0, -1}, fov_y, near, far),
		look = {yaw = yaw, pitch = clamp(pitch, pitch_min, pitch_max), sensitivity = sensitivity, stick_speed = stick_speed, pitch_min = pitch_min, pitch_max = pitch_max},
		eye_offset = eye_offset,
	}
	aim_first_person_camera(&rig, position)
	return rig
}

/*Reads the drag, right stick and walk controls into the rig without moving anything; step a solver with `move`*/
update_first_person_input :: proc(rig:^First_Person_Camera) {
	update_camera_look(&rig.look, get_delta_time())
	rig.move = calculate_walk_direction(rig.look.yaw, get_movement_input())
}

/*Puts the eye above `position` and points it along the angles; call it after the body has moved*/
aim_first_person_camera :: proc(rig:^First_Person_Camera, position:[3]f32) {
	rig.camera.position = position + rig.eye_offset
	rig.camera.target = rig.camera.position + calculate_direction_from_angles(rig.look.yaw, rig.look.pitch)
}

/*Input, the move and the aim in one call, for a body nothing else drives; `speed` is units per second*/
walk_first_person_camera :: proc(rig:^First_Person_Camera, position:^[3]f32, speed:f32, delta_time:f32) {
	update_first_person_input(rig)
	position^ += rig.move * speed * delta_time
	aim_first_person_camera(rig, position^)
}

/*Which side of the character a third-person camera sits on; the view direction is unchanged, the camera just slides*/
Camera_Shoulder :: enum {
	CENTER,
	LEFT,
	RIGHT,
}

/*Whether turning the camera turns the run*/
Camera_Steering :: enum {
	CAMERA, // W walks away from the camera and the character turns to face where it goes
	CHARACTER, // W walks along the character's heading; nothing turns the character but the game
	STRAFE, // as CAMERA, but the character always faces the camera, so A and D side-step
}

/*A third-person camera that orbits the character; with the character standing still it is an orbit camera*/
Third_Person_Camera :: struct {
	camera:Camera, // written by follow_third_person_camera
	look:Camera_Look,
	distance:f32, // how far back the camera sits
	distance_min:f32,
	distance_max:f32,
	zoom_speed:f32, // units per wheel notch, and four times that per second on L and R
	facing:f32, // which way the character is turned, as a yaw; draw it with calculate_facing_rotation
	move:[3]f32, // which way the controls asked to go this frame; written by update_third_person_input
	shoulder:Camera_Shoulder,
	shoulder_offset:f32, // how far sideways the camera slides off a shoulder, in units
	focus_offset:[3]f32, // added to the position being followed to get the point the camera looks at
	steering:Camera_Steering,
	turn_speed:f32, // radians per second the body turns to face where it runs
}

/*A third-person camera behind a character at `position` facing `facing`, already seated*/
create_third_person_camera :: proc(
	position:[3]f32 = {0, 0, 0},
	facing:f32 = 0,
	focus_offset:[3]f32 = {0, 1.6, 0},
	distance:f32 = 6,
	pitch:f32 = -0.3,
	shoulder:Camera_Shoulder = .CENTER,
	shoulder_offset:f32 = 0.75,
	steering:Camera_Steering = .CAMERA,
	turn_speed:f32 = 12,
	fov_y:f32 = 70,
	near:f32 = 0.1,
	far:f32 = 1000,
	sensitivity:f32 = 0.003,
	stick_speed:f32 = 2.5,
	pitch_min:f32 = -1.30, // overhead is a useful view; far below the character is the floor
	pitch_max:f32 = 0.30,
	zoom_speed:f32 = 1,
	distance_min:f32 = 1.5,
	distance_max:f32 = 20,
) -> Third_Person_Camera {
	rig := Third_Person_Camera {
		camera = create_camera_3d({}, {0, 0, -1}, fov_y, near, far),
		look = {yaw = facing, pitch = clamp(pitch, pitch_min, pitch_max), sensitivity = sensitivity, stick_speed = stick_speed, pitch_min = pitch_min, pitch_max = pitch_max},
		distance = clamp(distance, distance_min, distance_max),
		distance_min = distance_min,
		distance_max = distance_max,
		zoom_speed = zoom_speed,
		facing = facing,
		shoulder = shoulder,
		shoulder_offset = shoulder_offset,
		focus_offset = focus_offset,
		steering = steering,
		turn_speed = turn_speed,
	}
	seat_third_person_camera(&rig, position)
	return rig
}

/*Reads the drag, right stick, zoom and walk controls into the rig without moving anything; step a solver with `move`*/
update_third_person_input :: proc(rig:^Third_Person_Camera) {
	delta_time := get_delta_time()
	update_camera_look(&rig.look, delta_time)
	rig.distance = clamp(rig.distance + get_camera_zoom_input(rig.zoom_speed, delta_time), rig.distance_min, rig.distance_max)

	// STRAFE and CAMERA both read the controls against the camera; they differ in how the body turns
	rig.move = calculate_walk_direction(rig.facing if rig.steering == .CHARACTER else rig.look.yaw, get_movement_input())
}

/*Turns the character and seats the camera behind it at `position`; call it after the body has moved*/
follow_third_person_camera :: proc(rig:^Third_Person_Camera, position:[3]f32, delta_time:f32) {
	switch rig.steering {
	case .CAMERA:
		// Only while the controls ask for something, so a standing character keeps its heading
		if rig.move != {0, 0, 0} {
			turn_angle_toward(&rig.facing, calculate_yaw_from_direction(rig.move), rig.turn_speed, delta_time)
		}
	case .STRAFE:
		// Moving or not: aiming does not stop when the feet do
		turn_angle_toward(&rig.facing, rig.look.yaw, rig.turn_speed, delta_time)
	case .CHARACTER:
		// The heading is the game's under this setting
	}
	seat_third_person_camera(rig, position)
}

/*Input, the move and the follow in one call, for a character nothing else drives; `speed` is units per second*/
walk_third_person_camera :: proc(rig:^Third_Person_Camera, position:^[3]f32, speed:f32, delta_time:f32) {
	update_third_person_input(rig)
	position^ += rig.move * speed * delta_time
	follow_third_person_camera(rig, position^, delta_time)
}

/*The camera's position and target for the rig's angles around `position`; a shoulder slides both by the same vector*/
@(private)
seat_third_person_camera :: proc(rig:^Third_Person_Camera, position:[3]f32) {
	_, right := calculate_yaw_axes(rig.look.yaw)

	slide:f32
	switch rig.shoulder {
	case .LEFT: slide = -rig.shoulder_offset
	case .RIGHT: slide = rig.shoulder_offset
	case .CENTER: slide = 0
	}

	focus := position + rig.focus_offset + right * slide
	rig.camera.target = focus
	rig.camera.position = calculate_orbit_position(focus, rig.look.yaw, rig.look.pitch, rig.distance)
}
