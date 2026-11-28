package matchbox

import "core:math"
import "core:math/linalg"

/*
	Rays
	====
	What the pointer is over in a 3D view: a ray from the camera through a point of the screen, where a world point lands on
	the screen, and where a ray meets a plane, a sphere or a box. Pure maths, so every target has it.

	The screen side is in the units of the screen pass (set_screen_height's): +Y up, a point is measured the way
	render_line takes one, and the rectangle is where the 3D view is drawn. A gizmo's lines go from calculate_world_to_screen
	straight into render_line.

	Everything uses calculate_camera_view_matrix and calculate_camera_projection_gl, which is what camera_start draws with, so
	a click and the picture cannot disagree. The GL-to-D3D depth change camera_start makes does not touch x or y
*/

Ray :: struct {
	origin:    [3]f32,
	direction: [3]f32, // unit length, from every procedure here that makes one
}

/*The point `distance` along a ray*/
calculate_ray_point :: proc(ray: Ray, distance: f32) -> [3]f32 {
	return ray.origin + ray.direction * distance
}

/*
	The ray from the camera through `point`, a position inside the rectangle `min` (bottom left) to `max` (top right), in
	screen-pass units. It starts on the near plane rather than at the camera, which is what makes it right for an
	orthographic camera too, whose rays are parallel. The aspect is the rectangle's, not the window's
*/
calculate_ray_from_screen :: proc(camera: Camera, point, min, max: [2]f32) -> Ray {
	size := calculate_rectangle_size(min, max)

	ndc := [2]f32{
		(point.x - min.x) / size.x * 2 - 1,
		(point.y - min.y) / size.y * 2 - 1, // already +Y up, the way clip space runs
	}

	inverse := linalg.matrix4_inverse(calculate_view_projection(camera, size.x / size.y))

	// OpenGL's depth range: the near plane is -1 and the far plane 1
	near := inverse * [4]f32{ndc.x, ndc.y, -1, 1}
	far := inverse * [4]f32{ndc.x, ndc.y, 1, 1}

	start := near.xyz / near.w
	end := far.xyz / far.w
	return Ray{origin = start, direction = linalg.normalize(end - start)}
}

/*
	Where a world point lands in the rectangle `min` to `max`, in screen-pass units, and whether it is in front of the camera
	at all. A point behind the camera still projects somewhere, mirrored through the middle, so `in_front` is what to check
	before drawing anything there
*/
calculate_world_to_screen :: proc(camera: Camera, point: [3]f32, min, max: [2]f32) -> (screen: [2]f32, in_front: bool) {
	size := calculate_rectangle_size(min, max)
	homogeneous := [4]f32{point.x, point.y, point.z, 1}

	// In view space the camera looks down -Z, so in front is a negative z: true for both projections, where the clip w is
	// only a depth for one
	in_front = (calculate_camera_view_matrix(camera) * homogeneous).z < 0

	clip := calculate_view_projection(camera, size.x / size.y) * homogeneous
	w := clip.w if math.abs(clip.w) > 1e-6 else 1e-6

	screen = {
		min.x + (clip.x / w + 1) * 0.5 * size.x,
		min.y + (clip.y / w + 1) * 0.5 * size.y,
	}
	return
}

/*
	Where a ray meets the plane through `point` facing `normal`, as a distance along the ray. Either side counts. No hit when
	the ray runs along the plane or the plane is behind the ray's start
*/
calculate_ray_plane :: proc(ray: Ray, point, normal: [3]f32) -> (distance: f32, hit: bool) {
	facing := linalg.dot(ray.direction, normal)
	if math.abs(facing) < 1e-6 do return 0, false

	t := linalg.dot(point - ray.origin, normal) / facing
	if t < 0 do return 0, false
	return t, true
}

/*Where a ray first meets a sphere. A ray that starts inside hits where it leaves*/
calculate_ray_sphere :: proc(ray: Ray, centre: [3]f32, radius: f32) -> (distance: f32, hit: bool) {
	offset := ray.origin - centre
	b := linalg.dot(offset, ray.direction)
	c := linalg.dot(offset, offset) - radius * radius

	discriminant := b * b - c
	if discriminant < 0 do return 0, false

	root := math.sqrt(discriminant)
	t := -b - root
	if t < 0 do t = -b + root
	if t < 0 do return 0, false
	return t, true
}

/*
	Where a ray first enters a box whose sides run along the axes; 0 when it starts inside. The slab method, with a ray
	parallel to a pair of faces tested directly rather than divided by zero
*/
calculate_ray_box :: proc(ray: Ray, lower, upper: [3]f32) -> (distance: f32, hit: bool) {
	enter := f32(-math.F32_MAX)
	leave := f32(math.F32_MAX)

	for axis in 0 ..< 3 {
		d := ray.direction[axis]
		o := ray.origin[axis]

		if math.abs(d) < 1e-12 {
			if o < lower[axis] || o > upper[axis] do return 0, false
			continue
		}

		t0 := (lower[axis] - o) / d
		t1 := (upper[axis] - o) / d
		if t0 > t1 do t0, t1 = t1, t0

		enter = math.max(enter, t0)
		leave = math.min(leave, t1)
		if enter > leave do return 0, false
	}

	if leave < 0 do return 0, false
	return math.max(enter, 0), true
}

/*
	calculate_ray_box for a box placed by `model`: `lower` and `upper` are in the box's own space, and the distance comes back
	in the world's. The ray is carried into the box's space with its direction deliberately left unnormalised, so a distance
	along the carried ray is the same distance along the world one: one test covers rotation, scale and the skew a stretched
	parent gives a turned child
*/
calculate_ray_oriented_box :: proc(ray: Ray, lower, upper: [3]f32, model: matrix[4, 4]f32) -> (distance: f32, hit: bool) {
	if math.abs(linalg.determinant(model)) < 1e-12 do return 0, false

	inverse := linalg.matrix4_inverse(model)
	origin := inverse * [4]f32{ray.origin.x, ray.origin.y, ray.origin.z, 1}
	direction := inverse * [4]f32{ray.direction.x, ray.direction.y, ray.direction.z, 0}

	return calculate_ray_box(Ray{origin = origin.xyz, direction = direction.xyz}, lower, upper)
}

// What both screen procedures project with, so they cannot differ
@(private)
calculate_view_projection :: proc(camera: Camera, aspect: f32) -> matrix[4, 4]f32 {
	return calculate_camera_projection_gl(camera, aspect) * calculate_camera_view_matrix(camera)
}

// A rectangle with no size would divide by zero everywhere above; one unit square is a wrong answer rather than a NaN
@(private)
calculate_rectangle_size :: proc(min, max: [2]f32) -> [2]f32 {
	return {math.max(max.x - min.x, 1e-3), math.max(max.y - min.y, 1e-3)}
}
