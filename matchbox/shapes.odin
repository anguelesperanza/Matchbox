package matchbox

/*
	Shapes
	======
	Filled shapes in world units, drawn through the same queue as sprites.
	Positions are [3]f32 where z is the layer.

	A color with alpha below 1 is drawn blended and sorted.
	Anything else is	rawn solid with depth
	Overlapping solid shapes need different z values
*/

import "core:math/linalg"

/*A matrix that sends the unit axes to x, y and z, and the origin to `origin`*/
@(private)
calculate_basis_matrix :: proc(x, y, z, origin:[3]f32) -> matrix[4, 4]f32 {
	return matrix[4, 4]f32 {
		x.x, y.x, z.x, origin.x,
		x.y, y.y, z.y, origin.y,
		x.z, y.z, z.z, origin.z,
		0,   0,   0,   1,
	}
}

@(private)
shape_blend :: proc(color:[4]f32) -> Blend_Mode {
	if color.a < 1 {
		return .ALPHA
	}
	return .NONE
}

/*A filled rectangle. `pivot` is the point of the rectangle that sits at `position`
and that `rotation` (radians, counter-clockwise) turns about*/
render_rectangle :: proc(position:[3]f32, size:[2]f32, color:[4]f32, rotation:f32 = 0, pivot:[2]f32 = {0.5, 0.5}) {
	turn := calculate_rotation_axis_angle({0, 0, 1}, rotation)
	model := calculate_model_matrix(position, turn, {size.x, size.y, 1}) *
		linalg.matrix4_translate_f32({0.5 - pivot.x, 0.5 - pivot.y, 0})

	queue_render(mbi.sprite_mesh, model, color, shape_blend(color), .NONE, {}, {0, 0, 1, 1}, 0)
}

/*A filled circle centred on `position`*/
render_circle :: proc(position:[3]f32, radius:f32, color:[4]f32) {
	model := calculate_model_matrix(position, linalg.QUATERNIONF32_IDENTITY, {radius, radius, 1})

	queue_render(mbi.circle_mesh, model, color, shape_blend(color), .NONE, {}, {0, 0, 1, 1}, 0)
}

/*A filled triangle through three points. Either winding works*/
render_triangle :: proc(a, b, c:[3]f32, color:[4]f32) {
	// The unit triangle's x axis becomes a->b and its y axis becomes a->c
	model := calculate_basis_matrix(b - a, c - a, {0, 0, 1}, a)

	queue_render(mbi.triangle_mesh, model, color, shape_blend(color), .NONE, {}, {0, 0, 1, 1}, 0)
}

/*A line of `thickness` world units, with flat ends. Lies in the XY plane, facing the camera*/
render_line :: proc(start, end:[3]f32, thickness:f32, color:[4]f32) {
	direction := end - start
	if direction.x == 0 && direction.y == 0 {
		return // no length to draw (or pointing straight at the camera)
	}

	// Sideways from the line, in the XY plane, as long as the thickness
	sideways := linalg.normalize([3]f32{-direction.y, direction.x, 0}) * thickness
	centre := (start + end) * 0.5

	// The unit quad runs -0.5..0.5, so its axes are the full length and thickness
	model := calculate_basis_matrix(direction, sideways, {0, 0, 1}, centre)

	queue_render(mbi.sprite_mesh, model, color, shape_blend(color), .NONE, {}, {0, 0, 1, 1}, 0)
}

/*
	A hollow rectangle from `min` (bottom left) to `max` (top right) at depth `z`, its
	sides `thickness` world units wide, drawn inside the edges so the outer edge is
	exactly the box. A thickness of half the smaller side or more fills it.

	Four filled strips rather than a shader: the bottom and top run the full width and
	the sides fit between them, so no corner is drawn twice and a see-through colour
	stays even all the way round.

	`main` drew this with an outline shader and measured `thickness` in pixels, after an
	earlier fraction-of-the-size version drew long boxes with fat sides. World units
	here, like render_line: the camera decides how many pixels that is.
*/
render_rectangle_outline :: proc(min, max:[2]f32, z:f32, thickness:f32, color:[4]f32) {
	size := max - min
	if size.x <= 0 || size.y <= 0 || thickness <= 0 do return

	if thickness * 2 >= size.x || thickness * 2 >= size.y {
		render_rectangle({min.x, min.y, z}, size, color, pivot = {0, 0})
		return
	}

	side_height := size.y - thickness * 2
	render_rectangle({min.x, min.y, z}, {size.x, thickness}, color, pivot = {0, 0}) // bottom
	render_rectangle({min.x, max.y - thickness, z}, {size.x, thickness}, color, pivot = {0, 0}) // top
	render_rectangle({min.x, min.y + thickness, z}, {thickness, side_height}, color, pivot = {0, 0}) // left
	render_rectangle({max.x - thickness, min.y + thickness, z}, {thickness, side_height}, color, pivot = {0, 0}) // right
}
