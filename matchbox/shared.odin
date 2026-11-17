package matchbox

/*
	Shared
	======
	A series of procedures / structs
	shared accross all targets
*/

import "core:math/linalg"

create_model_matrix :: proc(
	position:[3]f32 = {0, 0, 0},
	rotation:quaternion128 = linalg.QUATERNIONF32_IDENTITY,
	scale:[3]f32 = {1, 1, 1},
) -> matrix[4, 4]f32 {
	return linalg.matrix4_translate_f32(position) * linalg.matrix4_from_quaternion_f32(rotation) * linalg.matrix4_scale_f32(scale)
}

/*A rotation of `angle` radians around `axis`*/
create_rotation_axis_angle :: proc(axis:[3]f32, angle:f32) -> quaternion128 {
	return linalg.quaternion_angle_axis_f32(angle, axis)
}

/*A rotation built from pitch (around X), yaw (around Y) and roll (around Z).
Roll is applied first, then pitch, then yaw*/
create_rotation_euler :: proc(pitch:f32 = 0, yaw:f32 = 0, roll:f32 = 0) -> quaternion128 {
	x := linalg.quaternion_angle_axis_f32(pitch, {1, 0, 0})
	y := linalg.quaternion_angle_axis_f32(yaw, {0, 1, 0})
	z := linalg.quaternion_angle_axis_f32(roll, {0, 0, 1})
	return y * x * z
}
