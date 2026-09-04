package matchbox

/*
	Shapes
	------
	Lines, circles, ellipses and triangles.

	For a long time the whole of Matchbox's drawing was draw_rect,
	draw_rect_border, draw_text and draw_sprite. The cost of that showed up
	inside Matchbox itself rather than in a game: Dropdown drew its open/closed
	caret as the ASCII characters `v` and `^`, because there was no triangle to
	draw it with and the font is whatever the game happened to load.

	A line is a rotated rect and goes through the rect pipeline. The other three
	go through shape.frag, which cuts them out of the same unit quad by testing
	a distance field per pixel -- see the shader for why that is the shape of it
	rather than a second vertex format.

	Everything here takes coordinates in the space you draw in, and every
	`thickness` is in pixels. Edges are smoothed.
*/

import "core:math"
import "core:math/linalg"

/*
	A straight line `thickness` pixels wide.

	This is a rotated rectangle rather than a shape, because that is genuinely
	all it is and the rect pipeline is one draw with no distance field in it.
	The ends are square and cut off flush, so a polyline turned through a sharp
	angle has a notch on the outside of the corner. draw_lines rounds them over.
*/
draw_line :: proc(from: [2]f32, to: [2]f32, color: [4]f32, thickness: f32 = 1) {
	delta  := to - from
	length := linalg.length(delta)
	if length <= 0 do return

	// atan2 of a y-down delta and a y-down rotation agree: the vertex shader
	// rotates in the same screen space it translates in, and only negates y on
	// the way to clip space, after the rotation has happened.
	draw_rect({
		position = (from + to) * 0.5,
		size     = {length, thickness * logical_per_pixel()},
		rotation = math.atan2(delta.y, delta.x),
		color    = color,
	})
}

/*
	A run of connected line segments.

	The joins are covered with a dot the width of the line, which is the cheap
	way to round a corner and is why this is not just a loop over draw_line at
	the call site. Fewer than two points draws nothing.
*/
draw_lines :: proc(points: [][2]f32, color: [4]f32, thickness: f32 = 1) {
	if len(points) < 2 do return

	for i in 0 ..< len(points) - 1 {
		draw_line(points[i], points[i + 1], color, thickness)
	}

	// Interior joins only. Rounding the two free ends would make every line
	// longer than it was asked to be.
	for i in 1 ..< len(points) - 1 {
		draw_circle(points[i], thickness * 0.5 * logical_per_pixel(), color)
	}
}

// A filled circle. Radius is in the space you draw in, like every other size.
draw_circle :: proc(center: [2]f32, radius: f32, color: [4]f32) {
	draw_ellipse(center, {radius, radius}, color)
}

// A circle drawn as a ring `thickness` pixels wide, centred on the radius.
draw_circle_outline :: proc(center: [2]f32, radius: f32, color: [4]f32, thickness: f32 = 1) {
	draw_ellipse_outline(center, {radius, radius}, color, thickness)
}

// A filled ellipse. `radii` is the half-extent on each axis.
draw_ellipse :: proc(center: [2]f32, radii: [2]f32, color: [4]f32, rotation: f32 = 0) {
	draw_ellipse_shape(center, radii, color, 0, rotation)
}

// An ellipse drawn as a ring `thickness` pixels wide, centred on the edge.
draw_ellipse_outline :: proc(center: [2]f32, radii: [2]f32, color: [4]f32, thickness: f32 = 1, rotation: f32 = 0) {
	draw_ellipse_shape(center, radii, color, max(thickness, 0.01), rotation)
}

@(private)
draw_ellipse_shape :: proc(center: [2]f32, radii: [2]f32, color: [4]f32, thickness: f32, rotation: f32) {
	if radii.x <= 0 || radii.y <= 0 do return

	// The quad is larger than the ellipse by enough to hold the smoothed edge,
	// and the ring if there is one. Without the margin the outer half of that
	// edge falls outside the quad and is never rasterised, which brings back
	// exactly the hard edge the distance field is there to avoid.
	pad  := shape_padding(thickness)
	half := radii + pad

	shape_quad(center, half * 2, rotation, Shape_Frag_Data{
		color     = color,
		p0        = {0.5, 0.5},
		p1        = radii / (half * 2), // the ellipse's radii as a share of the quad
		kind      = f32(Shape_Kind.ELLIPSE),
		thickness = thickness,
	})
}

// A filled triangle through three points, in any winding order.
draw_triangle :: proc(a, b, c: [2]f32, color: [4]f32) {
	draw_triangle_shape(a, b, c, color, 0)
}

// The same three points joined by a line `thickness` pixels wide.
draw_triangle_outline :: proc(a, b, c: [2]f32, color: [4]f32, thickness: f32 = 1) {
	draw_triangle_shape(a, b, c, color, max(thickness, 0.01))
}

@(private)
draw_triangle_shape :: proc(a, b, c: [2]f32, color: [4]f32, thickness: f32) {
	pad := shape_padding(thickness)

	// The quad is the triangle's bounding box with room for the smoothed edge
	// added. The padding also takes care of three points on one line, which
	// would otherwise ask for a quad with no width or no height at all.
	low  := [2]f32{min(a.x, b.x, c.x), min(a.y, b.y, c.y)} - pad
	high := [2]f32{max(a.x, b.x, c.x), max(a.y, b.y, c.y)} + pad
	size := high - low

	// The corners as a fraction of the quad, which is the space shape.frag
	// works in -- it never sees where any of this is on screen.
	uv :: proc(p, low, size: [2]f32) -> [2]f32 { return (p - low) / size }

	shape_quad((low + high) * 0.5, size, 0, Shape_Frag_Data{
		color     = color,
		p0        = uv(a, low, size),
		p1        = uv(b, low, size),
		p2        = uv(c, low, size),
		kind      = f32(Shape_Kind.TRIANGLE),
		thickness = thickness,
	})
}

/*
	How much room to leave round a shape for its smoothed edge, in the space
	being drawn in.

	Two pixels, plus half the thickness of a ring, which straddles the edge. The
	conversion out of pixels is the same one the shader does in the other
	direction, and it has to happen here because only the caller's side knows
	the shape before the quad has been sized round it.
*/
@(private)
shape_padding :: proc(thickness: f32) -> f32 {
	return (thickness * 0.5 + 2) * logical_per_pixel()
}

// One logical unit per window pixel: what a pixel is worth in the coordinates
// games draw in, once the letterbox scale and the camera zoom are taken off.
@(private)
logical_per_pixel :: proc() -> f32 {
	scale := mbi.draw_scale
	if mbi.camera.active && mbi.camera.zoom > 0 do scale *= mbi.camera.zoom
	if scale <= 0 do return 1
	return 1 / scale
}

@(private)
shape_quad :: proc(center: [2]f32, size: [2]f32, rotation: f32, frag_data: Shape_Frag_Data) {
	frag_data := frag_data

	vert_data := Vert_Data{
		position = screen_pos(center),
		size     = screen_size(size),
		screen   = get_screen_dims(),
		uv_min   = {0, 0},
		uv_max   = {1, 1},
		rotation = rotation,
	}

	draw_quad(mbi.renderer.pipelines.shape, &vert_data, &frag_data, size_of(frag_data))
}
