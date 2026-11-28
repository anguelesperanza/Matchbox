#+build windows

package matchbox

import "core:math"

import win "core:sys/windows"

/*
	Starts clipping the screen pass to a rectangle: until clip_end, what is drawn shows only inside it. `min` is the bottom
	left and `max` the top right, in the units of the pass (set_screen_height's, +Y up, the origin at the middle), so it is
	the same rectangle render_rectangle_outline would outline. Only inside screen_start / screen_end.

	Clips nest: a clip inside a clip is cut down to the area both share, so a dropdown inside a scroll view cannot spill out
	of the scroll view. A clip made so small that nothing is left draws nothing. Each clip_start needs its clip_end before
	screen_end, and at most MAX_CLIP_DEPTH can be open at once

		mb.screen_start()
		mb.clip_start({-4, -3}, {4, 3})
		// ... a list that is taller than that, drawn in full ...
		mb.clip_end()
		mb.screen_end()
*/
clip_start :: proc(min, max: [2]f32) {
	ensure(mbi.camera_active && mbi.screen_pass, "clip_start must be called between screen_start and screen_end")
	clip := &mbi.clip
	ensure(clip.depth < MAX_CLIP_DEPTH, "clip_start: too many clips open at once (MAX_CLIP_DEPTH)")

	low := min
	high := max
	if clip.depth > 0 {
		// Cut down to what the clip below already allows
		low.x = math.max(low.x, clip.stack_min[clip.depth - 1].x)
		low.y = math.max(low.y, clip.stack_min[clip.depth - 1].y)
		high.x = math.min(high.x, clip.stack_max[clip.depth - 1].x)
		high.y = math.min(high.y, clip.stack_max[clip.depth - 1].y)
	}
	// Nothing left is an empty rectangle, not an upside-down one
	high.x = math.max(high.x, low.x)
	high.y = math.max(high.y, low.y)

	clip.stack_min[clip.depth] = low
	clip.stack_max[clip.depth] = high
	clip.depth += 1
	update_current_clip()
}

/*Ends the innermost clip_start: what is drawn next is clipped by the clip below it, or not at all if there is none*/
clip_end :: proc() {
	ensure(mbi.clip.depth > 0, "clip_end without a clip_start")
	mbi.clip.depth -= 1
	update_current_clip()
}

/*
	The area the screen pass is clipped to right now, in the same units clip_start takes, and whether there is one. A UI uses
	it to keep the pointer out of what is hidden: a button scrolled out of a list must not answer a click on the list's edge
*/
get_clip_rectangle :: proc() -> (min, max: [2]f32, active: bool) {
	clip := &mbi.clip
	if clip.depth == 0 do return {}, {}, false
	return clip.stack_min[clip.depth - 1], clip.stack_max[clip.depth - 1], true
}

/*Works out the pixels of the innermost clip, which is what every draw queued from now on carries*/
@(private)
update_current_clip :: proc() {
	clip := &mbi.clip
	if clip.depth == 0 {
		clip.current = {}
		clip.active = false
		return
	}

	low := clip.stack_min[clip.depth - 1]
	high := clip.stack_max[clip.depth - 1]
	width := f32(clip.target_pixels.x)
	height := f32(clip.target_pixels.y)
	scale := clip.units_to_pixels

	// Units to pixels: the target's middle is `centre_units`, x grows right the same way, y is flipped (pixels count down)
	left := math.round(width * 0.5 + (low.x - clip.centre_units.x) * scale)
	right := math.round(width * 0.5 + (high.x - clip.centre_units.x) * scale)
	top := math.round(height * 0.5 - (high.y - clip.centre_units.y) * scale)
	bottom := math.round(height * 0.5 - (low.y - clip.centre_units.y) * scale)

	clip.current = {
		left   = i32(clamp(left, 0, width)),
		top    = i32(clamp(top, 0, height)),
		right  = i32(clamp(right, 0, width)),
		bottom = i32(clamp(bottom, 0, height)),
	}
	clip.active = true
}

/*Tells the GPU which pixels may be drawn: the clip of an item, or the whole target for one with none*/
@(private)
set_scissor :: proc(item_clip: Clip_Rectangle, clipped: bool, target: [2]i32) {
	rectangle := win.RECT{0, 0, target.x, target.y}
	if clipped {
		rectangle = {item_clip.left, item_clip.top, item_clip.right, item_clip.bottom}
	}
	mbi.device_context->RSSetScissorRects(1, &rectangle)
}
