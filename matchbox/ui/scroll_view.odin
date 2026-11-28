#+build windows

package ui

SCROLLBAR_TRACK :: [4]f32{1, 1, 1, 0.06}
SCROLLBAR_THUMB :: [4]f32{1, 1, 1, 0.28}
SCROLLBAR_HOVER :: [4]f32{1, 1, 1, 0.45}

/*
	A panel whose contents can be taller than it is. The offset is in units, not an index, so nothing has to know how many
	items fit: they are laid out at their natural positions and the ones outside are clipped.

		origin := ui.begin_scroll(&view, panel, f32(len(items)) * ROW)
		defer ui.end_scroll(&view)

	Content is laid out downwards from `origin`, so the first row's top edge is at origin.y and the next is ROW below it.
	The offset grows as the content goes up past the top edge: scrolled to the bottom it is `content - panel height`
*/
Scroll_View :: struct {
	offset: f32, // how far the content is pulled up; clamped by the next begin_scroll

	area:    Rectangle,
	content: f32,

	// Where inside the thumb the drag took hold, so it does not jump
	dragging: bool,
	grab:     f32,
}

/*Starts the panel: takes the wheel and the thumb, clamps, clips to `area`, and returns the top-left to lay content out from*/
begin_scroll :: proc(view: ^Scroll_View, area: Rectangle, content_height: f32) -> [2]f32 {
	view.area = area
	view.content = max(content_height, 0)

	max_offset := get_scroll_max(view)

	if max_offset > 0 && is_pointer_over_rectangle(area) && !is_pointer_claimed() {
		view.offset -= get_pointer_wheel().y * DEFAULTS.scroll_wheel_step
	}

	update_scroll_drag(view, max_offset)
	view.offset = clamp(view.offset, 0, max_offset)

	begin_clip(area)
	return {area.min.x, area.max.y + view.offset}
}

/*Ends the panel and draws the bar, after the clip is lifted so the bar is not cut in half by it*/
end_scroll :: proc(view: ^Scroll_View) {
	end_clip()
	render_scrollbar(view)
}

get_scroll_max :: proc(view: ^Scroll_View) -> f32 {
	return max(0, view.content - calculate_rectangle_size(view.area).y)
}

/*Brings a band of content into view. `top` is how far below the content's top edge the band starts, and `height` how tall it is. Safe every frame*/
scroll_to :: proc(view: ^Scroll_View, top: f32, height: f32) {
	bottom := top + height
	panel_height := calculate_rectangle_size(view.area).y
	switch {
	case top < view.offset:
		view.offset = top
	case bottom > view.offset + panel_height:
		view.offset = bottom - panel_height
	}
}

@(private)
calculate_scrollbar_track :: proc(view: ^Scroll_View) -> Rectangle {
	area := view.area
	return {
		min = {area.max.x - DEFAULTS.scroll_bar_width - DEFAULTS.scroll_inset, area.min.y + DEFAULTS.scroll_inset},
		max = {area.max.x - DEFAULTS.scroll_inset, area.max.y - DEFAULTS.scroll_inset},
	}
}

@(private)
calculate_scrollbar_thumb :: proc(view: ^Scroll_View) -> Rectangle {
	track := calculate_scrollbar_track(view)
	max_offset := get_scroll_max(view)
	if max_offset <= 0 do return track

	track_height := calculate_rectangle_size(track).y
	visible := clamp(calculate_rectangle_size(view.area).y / max(view.content, 1), 0, 1)
	height := max(track_height * visible, min(DEFAULTS.scroll_thumb_min, track_height))
	travel := track_height - height

	// The thumb starts at the top of the track and moves down as the offset grows
	top := track.max.y - travel * (view.offset / max_offset)
	return {min = {track.min.x, top - height}, max = {track.max.x, top}}
}

@(private)
update_scroll_drag :: proc(view: ^Scroll_View, max_offset: f32) {
	if max_offset <= 0 || !is_button_held(.LEFT) {
		view.dragging = false
		return
	}

	thumb := calculate_scrollbar_thumb(view)
	if !view.dragging {
		if !is_button_pressed(.LEFT) || is_pointer_claimed() || !is_pointer_over_rectangle(thumb) do return
		view.dragging = true
		view.grab = thumb.max.y - get_pointer_position().y
	}

	track := calculate_scrollbar_track(view)
	travel := calculate_rectangle_size(track).y - calculate_rectangle_size(thumb).y
	if travel <= 0 do return

	top := get_pointer_position().y + view.grab
	view.offset = clamp((track.max.y - top) / travel, 0, 1) * max_offset
}

@(private)
render_scrollbar :: proc(view: ^Scroll_View) {
	if get_scroll_max(view) <= 0 do return

	render_rectangle(calculate_scrollbar_track(view), SCROLLBAR_TRACK)
	thumb := calculate_scrollbar_thumb(view)
	color := SCROLLBAR_THUMB
	if view.dragging || (is_pointer_over_rectangle(thumb) && !is_pointer_claimed()) do color = SCROLLBAR_HOVER
	render_rectangle(thumb, color)
}
