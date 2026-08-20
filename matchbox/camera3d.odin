package matchbox

/*
	Camera -- 3D
	------------
	Where the scene is looked at from, and the two matrices that follow from
	that.

	Deliberately the same five fields raylib's Camera3D has, because both games
	already fill them in and the port should be a rename rather than a rethink.
	`near` and `far` are the additions, and only because raylib hides them and
	then gives you no way to change them when you want fog to reach further than
	1000 units.
*/

import "core:math"
import "core:math/linalg"

Camera3D_Projection :: enum {
	PERSPECTIVE,
	ORTHOGRAPHIC,
}

/*
	A point to look from, a point to look at, and how much fits in the frame.

	`fov` is vertical and in **degrees**, matching what both games already
	write. Everything else angular in Matchbox is radians; this is the exception
	and it is the same exception every engine makes.

	`near`, `far` and `up` may be left zero. A camera with a zero `up` has no
	idea which way is up and a camera with `near == far` has no depth at all, so
	rather than draw nothing and say nothing, the defaults below are filled in
	at use: up is +y, near is 0.1 and far is 1000, which is what raylib picks
	and what both games have been running on without knowing it.
*/
Camera3D :: struct {
	position:   [3]f32,
	target:     [3]f32,
	up:         [3]f32,
	fov:        f32,
	projection: Camera3D_Projection,
	near:       f32,
	far:        f32,
}

// A camera at `position` looking at `target`, with everything else left to the
// defaults. The short way to get a scene on screen.
camera3d_at :: proc(position, target: [3]f32, fov: f32 = 70) -> Camera3D {
	return Camera3D{
		position   = position,
		target     = target,
		up         = {0, 1, 0},
		fov        = fov,
		projection = .PERSPECTIVE,
		near       = 0.1,
		far        = 1000,
	}
}

// Fills in whatever was left zero. Called by the matrix builders rather than by
// the game, so a struct literal with three fields set still works.
@(private)
camera3d_defaults :: proc(camera: Camera3D) -> Camera3D {
	c := camera

	if c.up == {0, 0, 0} do c.up = {0, 1, 0}
	if c.fov <= 0        do c.fov = 70
	if c.near <= 0       do c.near = 0.1
	if c.far <= c.near   do c.far = 1000

	return c
}

// The matrix that moves the world in front of the camera.
camera3d_view :: proc(camera: Camera3D) -> matrix[4, 4]f32 {
	c := camera3d_defaults(camera)
	return look_at_matrix(c.position, c.target, c.up)
}

/*
	The matrix that turns view space into clip space, for the window as it is
	now.

	Aspect comes from the window rather than from the logical size, because the
	3D pass draws into the swapchain at its real pixel dimensions -- a 3D scene
	is not letterboxed the way `set_logical_size` letterboxes 2D.

	An orthographic camera reads `fov` as the height of the visible box in world
	units rather than as an angle, which is what raylib does with the same
	field.
*/
camera3d_projection :: proc(camera: Camera3D) -> matrix[4, 4]f32 {
	c := camera3d_defaults(camera)

	width  := f32(mbi.window_width)
	height := f32(mbi.window_height)

	// A minimised window reports zero and would divide by it.
	aspect: f32 = 1
	if height > 0 do aspect = width / height

	switch c.projection {
	case .ORTHOGRAPHIC:
		half_h := c.fov * 0.5
		half_w := half_h * aspect
		return ortho(-half_w, half_w, -half_h, half_h, c.near, c.far)

	case .PERSPECTIVE:
		fallthrough
	case:
		return perspective(c.fov, aspect, c.near, c.far)
	}
}

// Both at once, in the order a vertex shader wants them.
camera3d_view_projection :: proc(camera: Camera3D) -> matrix[4, 4]f32 {
	return camera3d_projection(camera) * camera3d_view(camera)
}

// -----------------------------------------------------------------------
// Which way it is facing
// -----------------------------------------------------------------------

/*
	The direction the camera looks.

	Both games need this and neither needs it for rendering: `CoffeeGame` walks
	along it, and both cast along it -- Box3D's `World_CastRayClosest` takes an
	origin and a translation, and the translation is this multiplied by how far
	you can reach.
*/
camera3d_forward :: proc(camera: Camera3D) -> [3]f32 {
	return linalg.normalize(camera.target - camera.position)
}

// Sideways from the camera, to the right. What strafing moves along, and what
// an item held in front of the player is offset by.
camera3d_right :: proc(camera: Camera3D) -> [3]f32 {
	c := camera3d_defaults(camera)
	return linalg.normalize(linalg.cross(camera3d_forward(c), c.up))
}

// -----------------------------------------------------------------------
// First person
// -----------------------------------------------------------------------

/*
	The pieces of a first-person camera, kept separate on purpose.

	A game with physics does not want its camera moved for it. `CoffeeGame`
	drives a Box3D body with a velocity, steps the world, and only then reads
	the body's position back out -- so the camera's position is decided by the
	solver and the camera's *direction* is decided by the mouse. Those are two
	different jobs and a single procedure that did both would be useless to it.

	So: `camera3d_look` turns mouse motion into angles, `camera3d_aim` points
	the camera along them from wherever it now is, and `walk_direction` says
	which way the keys are asking to go. A game with physics uses all three and
	moves nothing itself. `camera3d_first_person` is those three plus the move,
	for a camera that nothing else is driving.

	Yaw and pitch belong to the game rather than to the Camera3D, because they
	are the source and `target` is derived from them. Storing both on the camera
	would be storing the same fact twice and inviting them to disagree.
*/

// Radians per unit of mouse motion. CoffeeGame's number, which felt right.
MOUSE_SENSITIVITY :: f32(0.003)

// Just short of straight up or straight down. Exactly vertical is where the
// forward direction becomes parallel to `up`, the cross product that makes the
// view matrix collapses, and the picture rolls over.
PITCH_LIMIT :: f32(1.56) // a little under pi/2

// Which way you are facing, from the two angles. Yaw 0 looks along +x.
direction_from_angles :: proc(yaw, pitch: f32) -> [3]f32 {
	return {
		math.cos(pitch) * math.cos(yaw),
		math.sin(pitch),
		math.cos(pitch) * math.sin(yaw),
	}
}

// The angles that would produce the direction a camera is already looking in.
// What to seed yaw and pitch with, so the first frame of mouse look does not
// snap the view somewhere else.
camera3d_angles :: proc(camera: Camera3D) -> (yaw, pitch: f32) {
	forward := camera3d_forward(camera)
	return math.atan2(forward.z, forward.x), math.asin(clamp(forward.y, -1, 1))
}

/*
	Turns this frame's mouse motion into a change in yaw and pitch.

	Touches no camera. A game that never moves its own camera still needs the
	angles, because the angles are what a Box3D ray is cast along.

	Pitch is clamped; yaw is not, and is free to wind past a full turn. Nothing
	downstream cares -- sin and cos do not -- and clamping it would put an
	invisible wall in the middle of turning around.
*/
camera3d_look :: proc(yaw, pitch: ^f32, sensitivity: f32 = MOUSE_SENSITIVITY) {
	delta := get_mouse_delta()

	yaw^   += delta.x * sensitivity
	pitch^ += delta.y * sensitivity // mouse_dy is already up-positive
	pitch^  = clamp(pitch^, -PITCH_LIMIT, PITCH_LIMIT)
}

// Points the camera along `yaw` and `pitch` from wherever it currently is.
// Call it after moving the position, which for a game with physics means after
// reading the body back out of the solver.
camera3d_aim :: proc(camera: ^Camera3D, yaw, pitch: f32) {
	camera.target = camera.position + direction_from_angles(yaw, pitch)
}

/*
	Which way WASD is asking to go, flattened onto the ground and normalised.

	Flattened because looking at your feet should not walk you into the floor:
	the forward the keys use is the facing direction with the pitch taken out,
	which is what every first-person game does and what `CoffeeGame` writes by
	hand as `flat_forward`.

	Normalised, so holding two keys is not faster than holding one. Zero when
	nothing is pressed, which is a length a caller has to expect before
	multiplying by a speed.

	The keys are fixed. A game wanting different ones builds the same vector out
	of `camera3d_forward` and `camera3d_right` in two lines, which is less than
	it would take to describe a rebinding.
*/
walk_direction :: proc(yaw: f32) -> [3]f32 {
	forward := [3]f32{math.cos(yaw), 0, math.sin(yaw)}
	right   := [3]f32{-math.sin(yaw), 0, math.cos(yaw)}

	direction: [3]f32

	if is_key_held(.W) do direction += forward
	if is_key_held(.S) do direction -= forward
	if is_key_held(.D) do direction += right
	if is_key_held(.A) do direction -= right

	if direction == {0, 0, 0} do return direction
	return linalg.normalize(direction)
}

/*
	Mouse look and WASD, moving the camera directly.

	For a camera nothing else is driving: a free camera, a level viewer, an
	example. A game with collision wants the three procedures above instead, so
	that the solver decides where the camera ends up and this does not overwrite
	it -- see the note at the top of this section.

	`speed` is units per second.
*/
camera3d_first_person :: proc(
	camera:      ^Camera3D,
	yaw, pitch:  ^f32,
	speed:       f32,
	delta_time:  f32,
	sensitivity: f32 = MOUSE_SENSITIVITY,
) {
	camera3d_look(yaw, pitch, sensitivity)

	camera.position += walk_direction(yaw^) * speed * delta_time

	camera3d_aim(camera, yaw^, pitch^)
}
