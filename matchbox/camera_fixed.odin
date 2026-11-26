package matchbox

/*
	Fixed-angle cameras
	===================
	The camera a PlayStation-era survival horror game is built on: shots placed by hand, each covering a
	box of the level, with a cut to the next as the character walks between them. Cuts, not blends, since
	two shots are often on opposite sides of a wall. `cut` is true for the one frame a shot changed.
*/

/*The most shots a Fixed_Camera holds; a fixed array so no heap is needed on the handhelds*/
MAX_CAMERA_SHOTS :: 32

/*What a shot does with the character in frame*/
Camera_Shot_Aim :: enum {
	FIXED, // looks at the shot's own `target` and never moves
	TRACK, // stays put and turns to keep the character in frame
}

/*One camera placement and the box of the world it covers; give zones some height and let neighbours overlap by about a stride*/
Camera_Shot :: struct {
	position:[3]f32,
	target:[3]f32,
	fov_y:f32, // 0 reads as 70
	aim:Camera_Shot_Aim,
	zone_min:[3]f32, // opposite corners of the zone, in either order
	zone_max:[3]f32,
}

/*A set of fixed shots and which one is on screen*/
Fixed_Camera :: struct {
	camera:Camera, // written by follow_fixed_camera, and seated on the first shot as soon as one is added
	shots:[MAX_CAMERA_SHOTS]Camera_Shot,
	shot_count:int,
	shot:int, // which shot is on screen, an index into `shots`
	cut:bool, // true for exactly the frame `shot` changed
	focus_offset:[3]f32, // added to the followed position to get the point a TRACK shot looks at
}

/*An empty fixed camera, waiting for shots*/
create_fixed_camera :: proc(focus_offset:[3]f32 = {0, 1.6, 0}, near:f32 = 0.1, far:f32 = 1000) -> Fixed_Camera {
	return Fixed_Camera {
		camera = create_camera_3d({}, {0, 0, -1}, 70, near, far),
		focus_offset = focus_offset,
	}
}

/*Adds a shot and answers its index, or -1 if MAX_CAMERA_SHOTS are already held; the first shot is put on screen at once*/
add_fixed_camera_shot :: proc(rig:^Fixed_Camera, shot:Camera_Shot) -> int {
	if rig.shot_count >= MAX_CAMERA_SHOTS do return -1

	index := rig.shot_count
	rig.shots[index] = shot
	rig.shot_count += 1

	if index == 0 {
		rig.shot = 0
		seat_fixed_camera(rig, shot, shot.target)
	}
	return index
}

/*Puts the camera at the shot covering `position` (the character's feet) and aims it; call it every frame after the character has moved*/
follow_fixed_camera :: proc(rig:^Fixed_Camera, position:[3]f32) {
	rig.cut = false
	if rig.shot_count == 0 do return

	// The shot on screen keeps it while the character is inside its zone, so an overlap is a buffer and not a tie
	holding := rig.shot >= 0 && rig.shot < rig.shot_count && is_point_in_camera_shot(rig.shots[rig.shot], position)

	if !holding {
		for index in 0 ..< rig.shot_count {
			if !is_point_in_camera_shot(rig.shots[index], position) do continue

			if index != rig.shot {
				rig.shot = index
				rig.cut = true
			}
			break
		}
	}

	// A shot index the game wrote out of range, with the character in no zone to replace it: keep the camera as it was
	if rig.shot < 0 || rig.shot >= rig.shot_count do return

	seat_fixed_camera(rig, rig.shots[rig.shot], position + rig.focus_offset)
}

/*Whether `point` is inside a shot's zone, edges included so zones sharing a face leave no gap*/
@(private)
is_point_in_camera_shot :: proc(shot:Camera_Shot, point:[3]f32) -> bool {
	for axis in 0 ..< 3 {
		low := min(shot.zone_min[axis], shot.zone_max[axis])
		high := max(shot.zone_min[axis], shot.zone_max[axis])
		if point[axis] < low || point[axis] > high do return false
	}
	return true
}

@(private)
seat_fixed_camera :: proc(rig:^Fixed_Camera, shot:Camera_Shot, focus:[3]f32) {
	rig.camera.position = shot.position
	rig.camera.fov_y = shot.fov_y if shot.fov_y > 0 else 70

	switch shot.aim {
	case .TRACK: rig.camera.target = focus
	case .FIXED: rig.camera.target = shot.target
	}
}
