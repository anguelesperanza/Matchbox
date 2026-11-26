package matchbox

import "core:math"
import "core:math/linalg"

/*
	Drifting camera
	===============
	The camera an early survival-horror game uses outdoors: it keeps the angle the level gave it and
	slides along after the character. Nothing here reads the controls, and the camera is only dragged
	once the character leaves the `dead_zone` around the anchor, so a step does not slide the scene.
*/

/*A camera at a fixed angle, dragged along behind what it watches; `yaw` and `pitch` are the direction it looks along*/
Drift_Camera :: struct {
	camera:Camera, // written by follow_drift_camera and snap_drift_camera
	anchor:[3]f32, // the point the camera orbits: where the character was last watched from, their feet
	yaw:f32,
	pitch:f32,
	distance:f32,
	dead_zone:f32, // how far the character may stray on the ground before the camera is dragged; height has no dead zone
	follow_speed:f32, // rate per second the anchor closes on its goal; 0 or less means the camera does not follow
	swing_speed:f32, // radians per second the camera turns to look the way the character walks; 0 never turns it
	focus_offset:[3]f32, // added to the anchor to get the point the camera looks at, so the feet are not at the bottom of the frame
}

/*A drift camera watching `position`, seated so the first frame is already framed; the camera stands opposite `yaw`'s direction*/
create_drift_camera :: proc(
	position:[3]f32 = {0, 0, 0},
	yaw:f32 = 0,
	pitch:f32 = -0.3,
	distance:f32 = 6,
	dead_zone:f32 = 1.5, // a stride and a half of slack
	follow_speed:f32 = 3,
	swing_speed:f32 = 0,
	focus_offset:[3]f32 = {0, 1.6, 0},
	fov_y:f32 = 70,
	near:f32 = 0.1,
	far:f32 = 1000,
) -> Drift_Camera {
	rig := Drift_Camera {
		camera = create_camera_3d({}, {0, 0, -1}, fov_y, near, far),
		yaw = yaw,
		pitch = pitch,
		distance = distance,
		dead_zone = dead_zone,
		follow_speed = follow_speed,
		swing_speed = swing_speed,
		focus_offset = focus_offset,
	}
	snap_drift_camera(&rig, position)
	return rig
}

/*Drags the camera after `position` (the character's feet), once a frame after the character has moved*/
follow_drift_camera :: proc(rig:^Drift_Camera, position:[3]f32, delta_time:f32) {
	// Height goes straight into the goal; only x and z are on the leash
	goal := [3]f32{rig.anchor.x, position.y, rig.anchor.z}

	leash := max(rig.dead_zone, 0)
	away := [3]f32{position.x - rig.anchor.x, 0, position.z - rig.anchor.z}

	if reach := linalg.length(away); reach > leash && reach > 0 {
		direction := away / reach

		// The goal is a leash's length short of the character, so the camera is pulled by what they overran
		goal.x = position.x - direction.x * leash
		goal.z = position.z - direction.z * leash

		// Only while dragged: shuffling inside the dead zone must not swing the shot
		if rig.swing_speed > 0 {
			turn_angle_toward(&rig.yaw, calculate_yaw_from_direction(direction), rig.swing_speed, delta_time)
		}
	}

	// 1 - exp(-rate * dt) is the same curve at any frame rate and cannot overshoot
	if rig.follow_speed > 0 && delta_time > 0 {
		rig.anchor += (goal - rig.anchor) * (1 - math.exp(-rig.follow_speed * delta_time))
	}

	seat_drift_camera(rig)
}

/*Puts the anchor on `position` with no easing, for a teleport or a level load*/
snap_drift_camera :: proc(rig:^Drift_Camera, position:[3]f32) {
	rig.anchor = position
	seat_drift_camera(rig)
}

@(private)
seat_drift_camera :: proc(rig:^Drift_Camera) {
	focus := rig.anchor + rig.focus_offset
	rig.camera.target = focus
	rig.camera.position = calculate_orbit_position(focus, rig.yaw, rig.pitch, rig.distance)
}
