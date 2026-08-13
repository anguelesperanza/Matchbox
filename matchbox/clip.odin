package matchbox

/*
	Clipping
	--------
	Confines drawing to a rectangle, so a list can scroll inside a panel rather
	than carrying on over whatever sits below it.

	This is the hardware scissor, which means it costs nothing per draw and
	cuts pixels rather than geometry -- a glyph half outside the box is drawn
	half, not dropped. It is also why the rectangle is axis-aligned and a
	Rectangle's `rotation` is ignored here: there is no rotating a scissor.

	The rectangle is given in the same coordinates you draw in. The same
	Rectangle handed to draw_rect covers exactly the pixels that stay visible,
	so a panel and its clip can be the same value.
*/

import sdl "vendor:sdl3"

// A list inside a panel inside a screen is three, which is as deep as this has
// needed to go. Fixed, so the stack costs no allocation.
MAX_CLIP_DEPTH :: 8

/*
	Confines every draw until the matching end_clip.

	Nesting intersects rather than replaces: a list clipped inside a panel
	cannot escape the panel even when the list's own rectangle is larger.
	end_clip restores whatever was in force before it.

	`defer` is the tidy way to pair them:

		matchbox.begin_clip(panel)
		defer matchbox.end_clip()
*/
begin_clip :: proc(rectangle: Rectangle) {
	r := &mbi.renderer

	ensure(r.clip_depth < MAX_CLIP_DEPTH,
		"too many nested begin_clip calls -- is an end_clip missing?")

	rect := clip_to_window(rectangle)

	// Intersect with whatever is already in force, so an inner clip can only
	// ever shrink the visible area and never widen it.
	if r.clip_depth > 0 {
		rect = rect_intersect(rect, r.clip_stack[r.clip_depth - 1])
	}

	r.clip_stack[r.clip_depth] = rect
	r.clip_depth += 1

	apply_clip()
}

// Restores the clip that was in force before the matching begin_clip, or the
// whole window when that was the outermost one.
end_clip :: proc() {
	r := &mbi.renderer

	ensure(r.clip_depth > 0, "end_clip without a matching begin_clip")

	r.clip_depth -= 1
	apply_clip()
}

/*
	Hands the current clip to the render pass.

	Called by begin_clip and end_clip, and again by anything that opens a pass:
	the scissor is state on the pass rather than on the command buffer, so a
	pass opened after a clip was set would otherwise start unclipped. That
	happens whenever clear_background runs, which games do every frame.
*/
@(private)
apply_clip :: proc() {
	r := &mbi.renderer
	if r.pass == nil do return

	rect: sdl.Rect
	if r.clip_depth > 0 {
		rect = r.clip_stack[r.clip_depth - 1]
	} else {
		rect = {0, 0, max(0, mbi.window_width), max(0, mbi.window_height)}
	}

	sdl.SetGPUScissor(r.pass, rect)
}

// Dropped at the top of every frame, so a game that forgets an end_clip loses
// the clip at the frame boundary instead of never drawing again.
@(private)
clip_reset :: proc() {
	mbi.renderer.clip_depth = 0
}

/*
	Turns a Rectangle into the window pixels it occupies.

	Built from the centre outwards rather than from the top-left, because that
	is what draw_rect does -- the two have to agree or a panel and its clip
	will not line up. Both go through screen_pos and screen_size, so the camera
	and the letterbox transform are already accounted for.
*/
@(private)
clip_to_window :: proc(rectangle: Rectangle) -> sdl.Rect {
	center := screen_pos(rect_center(rectangle))
	size   := screen_size(rectangle.size)

	x0 := center.x - size.x * 0.5
	y0 := center.y - size.y * 0.5
	x1 := x0 + size.x
	y1 := y0 + size.y

	// Clamped to the window. A scissor reaching outside the render target is
	// an error to D3D12 rather than something it quietly ignores, and a panel
	// scrolled half off the edge is an ordinary thing to want to draw.
	w := f32(mbi.window_width)
	h := f32(mbi.window_height)

	x0 = clamp(x0, 0, w)
	y0 = clamp(y0, 0, h)
	x1 = clamp(x1, 0, w)
	y1 = clamp(y1, 0, h)

	return sdl.Rect{
		x = i32(x0),
		y = i32(y0),
		w = i32(max(0, x1 - x0)),
		h = i32(max(0, y1 - y0)),
	}
}

@(private)
rect_intersect :: proc(a, b: sdl.Rect) -> sdl.Rect {
	x0 := max(a.x, b.x)
	y0 := max(a.y, b.y)
	x1 := min(a.x + a.w, b.x + b.w)
	y1 := min(a.y + a.h, b.y + b.h)

	return sdl.Rect{
		x = x0,
		y = y0,
		w = max(0, x1 - x0),
		h = max(0, y1 - y0),
	}
}
