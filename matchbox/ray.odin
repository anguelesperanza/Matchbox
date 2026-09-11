package matchbox

/*
	Rays
	----
	A line from a point in a direction, and the questions a 3D game asks with
	one: what is under the pointer, what did this hit, where on the floor is
	that. Added for Stargate's level editor, which picks and drags with them;
	any 3D game that clicks on things wants the same.

	**Every screen question takes a viewport**: the rectangle the 3D is shown
	in, in the coordinates 2D is laid out in -- the whole window when left at
	zero, or the rectangle a render target is drawn into with
	`draw_render_target`. The projection is built from that rectangle's shape,
	not from whatever is bound when the question is asked. A ray is usually
	cast between frames, when nothing is bound, and the window's shape is the
	wrong one for a viewport that is not the window.
*/

import "core:math"
import "core:math/linalg"

Ray :: struct {
	origin:    [3]f32,
	direction: [3]f32, // unit length, from every procedure here that makes one
}

// The point `distance` along a ray.
ray_point :: proc(ray: Ray, distance: f32) -> [3]f32 {
	return ray.origin + ray.direction * distance
}

/*
	The ray from the camera through a point on the screen.

	It starts on the near plane rather than at the camera's position, which is
	what makes it right for an orthographic camera too: those rays are
	parallel, and start across the whole near plane rather than from one point.
*/
ray_from_screen :: proc(camera: Camera3D, point: [2]f32, viewport: Rectangle = {}) -> Ray {
	view     := viewport_or_window(viewport)
	top_left := rect_top_left(view)

	ndc := [2]f32{
		(point.x - top_left.x) / view.size.x * 2 - 1,
		1 - (point.y - top_left.y) / view.size.y * 2, // screen y runs down, clip y up
	}

	inverse := linalg.matrix4_inverse(view_projection_for_viewport(camera, view))

	// The projections here put the near plane at depth 0 and the far plane at 1.
	near := inverse * [4]f32{ndc.x, ndc.y, 0, 1}
	far  := inverse * [4]f32{ndc.x, ndc.y, 1, 1}

	start := near.xyz / near.w
	end   := far.xyz / far.w

	return Ray{origin = start, direction = linalg.normalize(end - start)}
}

// The ray under the pointer. `ray_from_screen` at `get_mouse_position`.
get_mouse_ray :: proc(camera: Camera3D, viewport: Rectangle = {}) -> Ray {
	return ray_from_screen(camera, get_mouse_position(), viewport)
}

/*
	Where a point in the world lands on the screen, and whether it is in front
	of the camera at all.

	A point behind the camera still projects somewhere -- mirrored through the
	middle of the screen -- so `in_front` is the half to check before drawing
	anything there. What a gizmo handle, a name tag over a head or an
	off-screen arrow needs.
*/
world_to_screen :: proc(camera: Camera3D, point: [3]f32, viewport: Rectangle = {}) -> (screen: [2]f32, in_front: bool) {
	view := viewport_or_window(viewport)

	// In view space the camera looks down -Z, so in front is a negative z --
	// true for both projections, where the clip w is only a depth for one.
	in_front = (camera3d_view(camera) * [4]f32{point.x, point.y, point.z, 1}).z < 0

	clip := view_projection_for_viewport(camera, view) * [4]f32{point.x, point.y, point.z, 1}
	w    := clip.w if math.abs(clip.w) > 1e-6 else 1e-6

	top_left := rect_top_left(view)
	screen = {
		top_left.x + (clip.x / w + 1) * 0.5 * view.size.x,
		top_left.y + (1 - clip.y / w) * 0.5 * view.size.y,
	}
	return
}

/*
	Where a ray meets the plane through `point` facing `normal`, as a distance
	along the ray.

	Either side counts: a floor is hit from above and from below. No hit when
	the ray runs along the plane, or when the plane is behind where the ray
	starts.
*/
ray_plane :: proc(ray: Ray, point, normal: [3]f32) -> (distance: f32, hit: bool) {
	facing := linalg.dot(ray.direction, normal)
	if math.abs(facing) < 1e-6 do return 0, false

	t := linalg.dot(point - ray.origin, normal) / facing
	if t < 0 do return 0, false
	return t, true
}

/*
	Where a ray first meets a sphere, as a distance along the ray. A ray that
	starts inside hits where it leaves.
*/
ray_sphere :: proc(ray: Ray, center: [3]f32, radius: f32) -> (distance: f32, hit: bool) {
	offset := ray.origin - center
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
	Where a ray first enters a box whose sides run along the axes, as a distance
	along the ray; 0 when it starts inside.

	The slab method: each pair of opposite faces bounds the ray to a stretch of
	distances, and the box is where all three stretches overlap. A ray parallel
	to a pair of faces is inside that pair's stretch everywhere or nowhere,
	which is tested directly rather than divided by zero.

	For a box that is turned or scaled, `ray_oriented_box` carries the ray into
	the box's own space first.
*/
ray_box :: proc(ray: Ray, lower, upper: [3]f32) -> (distance: f32, hit: bool) {
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

		enter = max(enter, t0)
		leave = min(leave, t1)
		if enter > leave do return 0, false
	}

	if leave < 0 do return 0, false
	return max(enter, 0), true
}

/*
	`ray_box` for a box placed by `transform`: `lower` and `upper` are in the
	box's own space, and the distance comes back in the world's.

	The ray is carried into the box's space by the inverse transform and its
	direction deliberately left unnormalised. A point a distance t along the
	world ray lands a distance t along the carried one, so the answer needs no
	converting back -- and one test covers rotation, scale and even the skew a
	stretched parent gives a turned child.
*/
ray_oriented_box :: proc(ray: Ray, lower, upper: [3]f32, transform: matrix[4, 4]f32) -> (distance: f32, hit: bool) {
	if math.abs(linalg.determinant(transform)) < 1e-12 do return 0, false

	inverse := linalg.matrix4_inverse(transform)
	origin    := inverse * [4]f32{ray.origin.x, ray.origin.y, ray.origin.z, 1}
	direction := inverse * [4]f32{ray.direction.x, ray.direction.y, ray.direction.z, 0}

	return ray_box(Ray{origin = origin.xyz, direction = direction.xyz}, lower, upper)
}

/*
	Where a ray meets a model drawn at `transform`, against the model's bounding
	box: what clicking on a model wants.

	The box, not the triangles -- a model's parts keep only their GPU buffers,
	so there are no triangles on this side to test. A click in the empty corner
	of an L-shaped model's box is a click on the model.
*/
ray_model :: proc(ray: Ray, model: Model, transform: Transform) -> (distance: f32, hit: bool) {
	return ray_oriented_box(ray, model.bounds_min, model.bounds_max, transform_matrix(transform))
}

@(private)
viewport_or_window :: proc(viewport: Rectangle) -> Rectangle {
	if viewport.size.x > 0 && viewport.size.y > 0 do return viewport
	return Rectangle{size = {f32(max(mbi.width, 1)), f32(max(mbi.height, 1))}, pivot = {0.5, 0.5}}
}

@(private)
view_projection_for_viewport :: proc(camera: Camera3D, viewport: Rectangle) -> matrix[4, 4]f32 {
	return camera3d_projection_for_aspect(camera, viewport.size.x / viewport.size.y) * camera3d_view(camera)
}
