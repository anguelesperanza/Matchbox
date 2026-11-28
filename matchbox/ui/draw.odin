#+build windows

package ui

/*
	Flat drawing
	============
	Rectangles, borders, lines, circles, triangles and textures in screen units, and a clip stack that nests. Each is
	Matchbox's own shape drawn flat at z = 0, so what is drawn later lands on top (the screen pass paints in submission order).

	**Why the clip is kept here as well as in Matchbox.** Matchbox's clip_start cuts the picture. A hit test is a separate
	question (a row scrolled out of a panel must not answer the pointer), and it has to work in a test with no screen pass
	running, where clip_start would refuse. So the stack here always keeps the rectangles, and forwards to Matchbox only
	while something is being drawn.

	Nothing draws outside a screen pass: a test can run a whole panel for its input and its layout, and the drawing half
	quietly does nothing.
*/

import mb ".."

Clip_Stack :: struct {
	rectangles: [mb.MAX_CLIP_DEPTH]Rectangle, // units, each already inside the one below
	forwarded:  [mb.MAX_CLIP_DEPTH]bool, // whether Matchbox was told, which end_clip has to undo
	depth:      int,
}

@(private)
is_drawing :: proc() -> bool {
	return mb.mbi.camera_active && mb.mbi.screen_pass
}

render_rectangle :: proc(rectangle: Rectangle, fill: [4]f32) {
	if !is_drawing() || fill.a <= 0 do return
	mb.render_rectangle({rectangle.min.x, rectangle.min.y, 0}, calculate_rectangle_size(rectangle), fill, pivot = {0, 0})
}

/*A border of one even thickness all the way round, inside the rectangle*/
render_rectangle_border :: proc(rectangle: Rectangle, color: [4]f32, thickness: f32) {
	if !is_drawing() || color.a <= 0 do return
	mb.render_rectangle_outline(rectangle.min, rectangle.max, 0, thickness, color)
}

render_line :: proc(from, to: [2]f32, color: [4]f32, thickness: f32 = 1) {
	if !is_drawing() do return
	mb.render_line({from.x, from.y, 0}, {to.x, to.y, 0}, thickness, color)
}

render_circle :: proc(centre: [2]f32, radius: f32, color: [4]f32) {
	if !is_drawing() do return
	mb.render_circle({centre.x, centre.y, 0}, radius, color)
}

render_circle_outline :: proc(centre: [2]f32, radius: f32, color: [4]f32, thickness: f32 = 1) {
	if !is_drawing() do return
	mb.render_circle_outline({centre.x, centre.y, 0}, radius, thickness, color)
}

/*A filled triangle, whichever way round its corners are given*/
render_triangle :: proc(a, b, c: [2]f32, fill: [4]f32) {
	if !is_drawing() do return
	mb.render_triangle({a.x, a.y, 0}, {b.x, b.y, 0}, {c.x, c.y, 0}, fill)
}

/*A texture, such as a render target's, filling a rectangle the right way up*/
render_texture :: proc(texture: mb.Texture, rectangle: Rectangle, tint: [4]f32 = WHITE) {
	if !is_drawing() || texture.width <= 0 do return
	mb.render_texture_rectangle(texture, rectangle.min, rectangle.max, 0, tint)
}

// ---- clipping -------------------------------------------------------------------

/*
	Confines every draw, and every is_pointer_over_rectangle, to `rectangle` until the matching end_clip. Nesting intersects
	rather than replaces, so a list clipped inside a panel clipped inside a window cannot escape the panel.

		ui.begin_clip(panel)
		defer ui.end_clip()
*/
begin_clip :: proc(rectangle: Rectangle) {
	stack := &ui_state.clip
	ensure(stack.depth < mb.MAX_CLIP_DEPTH, "too many nested begin_clip calls: is an end_clip missing?")

	clipped := rectangle
	if stack.depth > 0 do clipped = calculate_rectangle_intersection(rectangle, stack.rectangles[stack.depth - 1])

	stack.rectangles[stack.depth] = clipped
	stack.forwarded[stack.depth] = is_drawing()
	if stack.forwarded[stack.depth] do mb.clip_start(clipped.min, clipped.max)
	stack.depth += 1
}

end_clip :: proc() {
	stack := &ui_state.clip
	ensure(stack.depth > 0, "end_clip without a matching begin_clip")
	stack.depth -= 1
	if stack.forwarded[stack.depth] do mb.clip_end()
}

/*Whether a point is inside the clip in force, or true when there is none*/
is_point_in_clip :: proc(point: [2]f32) -> bool {
	stack := &ui_state.clip
	if stack.depth == 0 do return true
	return is_point_in_rectangle(point, stack.rectangles[stack.depth - 1])
}
