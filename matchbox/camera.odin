package matchbox


import "core:math/linalg"


/*
	Camera
	=======
	This file contains data related to the camera for Matchbox.
	It's shared by all targets and has no GPU specific code

	This cmaera is right-handed, +Y for up and looks down on -Z

	2D games will use the orothgraphic projection whereas 3D games
	will use the perspective one
*/


Projection :: enum {
	PERSPECTIVE,
	ORTHOGRAPHIC,
}

Camera :: struct {
	position:[3]f32,
	target:[3]f32,
	up:[3]f32,
	fov_y:f32,
	view_height:f32,

	// orthographic
	near:f32,
	far:f32,
	projection:Projection, 
}

/*Moves the world opposite to the camera*/
camera_view_matrix :: proc(camera:Camera) -> matrix[4,4]f32 {
	return linalg.matrix4_look_at_f32(camera.position, camera.target, camera.up)
}

/*The projection in OpenGL clip space (depth -1..1). A backend with another depth range adapts it*/
camera_projection_gl :: proc(cam:Camera, aspect:f32) -> matrix[4, 4]f32 {
	switch cam.projection {
	case .PERSPECTIVE:
		return linalg.matrix4_perspective_f32(linalg.to_radians(cam.fov_y), aspect, cam.near, cam.far)
	case .ORTHOGRAPHIC:
		half_height := cam.view_height / 2
		half_width := half_height * aspect
		return linalg.matrix_ortho3d_f32(-half_width, half_width, -half_height, half_height, cam.near, cam.far)
	}
	return linalg.MATRIX4F32_IDENTITY
}

/*A 2D camera: orthographic, `view_height` world units tall, looking at the origin from z = +10*/
create_camera_2d:: proc(view_height:f32) -> Camera {
	return Camera {
		position = {0, 0, 10},
		target = {0, 0, 0},
		up = {0, 1, 0},
		view_height = view_height,
		near = 0.1,
		far = 100,
		projection = .ORTHOGRAPHIC,
	}
}


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
