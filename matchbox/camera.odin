package matchbox


import "core:math"
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
	zoom:f32,
	pixel_snap:bool, // only for orthographic view

	// orthographic
	near:f32,
	far:f32,
	projection:Projection,

	// HUD
	screen:bool,
}


/*How many world units tall the view is, after zoom*/
camera_view_height :: proc(cam:Camera) -> f32 {
	if cam.zoom > 0 do return cam.view_height / cam.zoom
	return cam.view_height
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
		half_height := camera_view_height(cam) / 2
		half_width := half_height * aspect
		return linalg.matrix_ortho3d_f32(-half_width, half_width, -half_height, half_height, cam.near, cam.far)
	}
	return linalg.MATRIX4F32_IDENTITY
}

/*
	A 2D camera: orthographic
	view_height: is how many world unit (arbitruary number) the camera can see
	If a view_height is not provided, it defaults to 0 which will set the view height to the height of the window 
*/
create_camera_2d:: proc(view_height:f32 = 0) -> Camera {

	vh:f32 = view_height

	if view_height == 0 do vh = cast(f32)get_window_size()[1]
	
	return Camera {
		position = {0, 0, 10},
		target = {0, 0, 0},
		up = {0, 1, 0},
		view_height = vh,
		near = 0.1,
		far = 100,
		zoom = 1,
		projection = .ORTHOGRAPHIC,
	}
}


/*Whether `point` is inside the rectangle from `min` (bottom left) to `max` (top right), the edges
included. For clicking buttons and panels: `is_point_in_rect(get_mouse_screen_pos(), min, max)`*/
is_point_in_rect :: proc(point, min, max:[2]f32) -> bool {
	return point.x >= min.x && point.x <= max.x && point.y >= min.y && point.y <= max.y
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

/*Eases the camera toward `target` (world x, y). Call once per frame.
`speed` is how fast it catches up; 0 means it doesn't move.
The camera keeps looking straight ahead: position and target move together*/
camera_follow :: proc(cam:^Camera, target:[2]f32, speed:f32, delta_time:f32) {
	// Clamped to 1: a long frame or a high speed would otherwise overshoot and wobble
	t := min(speed * delta_time, 1)
	if t <= 0 do return

	dx := (target.x - cam.position.x) * t
	dy := (target.y - cam.position.y) * t

	cam.position.x += dx
	cam.position.y += dy
	cam.target.x += dx
	cam.target.y += dy
}

/*Converts a point in window pixels (top-left origin, y down) to world units.
For cameras from create_camera_2d: looking straight down -Z with +Y up*/
screen_to_world_2d :: proc(camera:Camera, screen:[2]f32, window:[2]f32) -> [2]f32 {
	if window.y <= 0 do return {camera.position.x, camera.position.y}

	// The view is camera_view_height tall and the window is window.y pixels tall,
	// so one pixel is the same size in units on both axes
	units_per_pixel := camera_view_height(camera) / window.y

	return {
		camera.position.x + (screen.x - window.x * 0.5) * units_per_pixel,
		camera.position.y - (screen.y - window.y * 0.5) * units_per_pixel, // screen y is down, world y is up
	}
}

/*Screen pixels to world unit*/
camera_snap_scale :: proc(camera:Camera, window_height:f32) -> f32 {
	if camera.pixel_snap == false || camera.projection != .ORTHOGRAPHIC || window_height <= 0 {
		return 0
	}

	return window_height / camera_view_height(camera)
}

snap_to_pixel :: proc(value:f32, scale:f32) -> f32 {
	return math.round(value * scale) / scale
}

camera_snapped :: proc(camera:Camera, window:[2]f32) -> Camera {
	result := camera
	scale := camera_snap_scale(camera, window.y)

	if scale == 0 do return result

	 
	origin_x := math.round(window.x * 0.5 - camera.position.x * scale)
	origin_y := math.round(window.y * 0.5 + camera.position.y * scale)

	snapped_x := (window.x * 0.5 - origin_x) / scale
	snapped_y := (origin_y - window.y * 0.5) / scale

	// Move the target by the same amount so the cameraera keeps looking straight ahead
	result.target.x += snapped_x - camera.position.x
	result.target.y += snapped_y - camera.position.y
	result.position.x = snapped_x
	result.position.y = snapped_y
	
	return result	
}

camera_set_pixel_scale :: proc(cam:^Camera, pixels_per_unit:f32, scale:f32, window_height:f32) {
	cam.zoom = 1
	cam.view_height = window_height / (pixels_per_unit * scale)
}

/*A HUD camera: like a 2D camera, `view_height` units tall, but drawn with depth off.
Use it through screen_start, or pass it to camera_start*/
create_screen_camera :: proc(view_height:f32) -> Camera {
	cam := create_camera_2d(view_height)
	cam.screen = true
	return cam
}

/*Where on the visible rectangle something is pinned*/
Anchor :: enum {
	TOP_LEFT,
	TOP,
	TOP_RIGHT,
	LEFT,
	CENTER,
	RIGHT,
	BOTTOM_LEFT,
	BOTTOM,
	BOTTOM_RIGHT,
}

/*The corners of what an orthographic camera sees, in world units, for a window `aspect` (width / height) wide.
`min` is the bottom left corner and `max` the top right*/
camera_visible_rect :: proc(cam:Camera, aspect:f32) -> (min, max:[2]f32) {
	half_height := camera_view_height(cam) / 2
	half_width := half_height * aspect

	min = {cam.position.x - half_width, cam.position.y - half_height}
	max = {cam.position.x + half_width, cam.position.y + half_height}
	return
}

/*A point on the camera's visible rectangle, pinned to `anchor` and then moved by `offset`
(plain addition, +Y up, so a TOP_LEFT offset of {1, -1} sits one unit in from the corner).
z is 0; set it afterwards to put things in front of or behind each other*/
camera_anchor_position :: proc(cam:Camera, aspect:f32, anchor:Anchor, offset:[2]f32 = {}) -> [3]f32 {
	min, max := camera_visible_rect(cam, aspect)

	// How far across (x) and up (y) the rectangle the anchor sits, 0 to 1
	fraction:[2]f32
	switch anchor {
	case .TOP_LEFT:     fraction = {0, 1}
	case .TOP:          fraction = {0.5, 1}
	case .TOP_RIGHT:    fraction = {1, 1}
	case .LEFT:         fraction = {0, 0.5}
	case .CENTER:       fraction = {0.5, 0.5}
	case .RIGHT:        fraction = {1, 0.5}
	case .BOTTOM_LEFT:  fraction = {0, 0}
	case .BOTTOM:       fraction = {0.5, 0}
	case .BOTTOM_RIGHT: fraction = {1, 0}
	}

	return {
		min.x + (max.x - min.x) * fraction.x + offset.x,
		min.y + (max.y - min.y) * fraction.y + offset.y,
		0,
	}
}
