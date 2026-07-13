package matchbox


/*
	Camera
	------
	This file has information for the camera
*/

import "core:math"
import "core:math/linalg"

Camera :: struct {
	eye: [3]f32,
	target:[3]f32,
	up:[3]f32,
	aspect:f32,
	fovy:f32,
	znear:f32,
	zfar:f32,
}

CameraUniform :: struct {
	view_proj:linalg.Matrix4f32
}

CameraController :: struct {
	speed:f32,
	is_forward_pressed:bool,
	is_backward_Pressed:bool,
	is_left_pressed:bool,
	is_right_pressed:bool,
}
