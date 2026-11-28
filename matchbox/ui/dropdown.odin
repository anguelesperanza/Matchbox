#+build windows

package ui

Dropdown_Style :: struct {
	fill:             [4]f32, // the closed box
	hover:            [4]f32, // under the pointer, on the box and on a row
	text_color:       [4]f32,
	list_background:  [4]f32,
	border:           [4]f32,
	mark:             [4]f32, // the chosen option, in an open dropdown's list
	padding:          f32,
	border_thickness: f32,
}

DROPDOWN_STYLE :: Dropdown_Style {
	fill             = {0.16, 0.16, 0.20, 1},
	hover            = {0.35, 0.35, 0.42, 1},
	text_color       = {1, 1, 1, 1},
	list_background  = {0.10, 0.10, 0.13, 1},
	border           = {0.35, 0.38, 0.46, 1},
	mark             = {0.55, 0.80, 0.55, 1},
	padding          = DEFAULTS.dropdown_padding,
	border_thickness = 1,
}

/*What the list hangs from: a closed box (a dropdown, whose chosen option is marked) or a point (a context menu, a list of actions with no current one)*/
Dropdown_Anchor :: enum {
	BOX,
	POINT,
}

Dropdown :: struct {
	open:     bool,
	selected: int,
	anchor:   Dropdown_Anchor,

	// The closed box, or a rectangle of no height at the point: the list hangs under its bottom edge either way
	rectangle: Rectangle,
	row:       [2]f32, // one row of the open list

	// The frame a context menu opened on: the click that opened it is still a press for the rest of that frame, and must
	// not also pick its first entry
	opened_on: u64,
}

/*
	The closed box, and every scrap of input for the frame, including the hit test on the open list, so a change is known in
	time to act on it this frame. True on the frame the selection changes. render_dropdown_overlay, called late, draws the list
*/
dropdown :: proc(dd: ^Dropdown, rectangle: Rectangle, options: []string, style := DROPDOWN_STYLE, font: ^Font = nil) -> (changed: bool) {
	font := font if font != nil else default_font()

	dd.anchor = .BOX
	dd.rectangle = rectangle
	dd.row = calculate_rectangle_size(rectangle)

	if len(options) == 0 {
		dd.open = false
		return false
	}
	dd.selected = clamp(dd.selected, 0, len(options) - 1)

	over := is_pointer_over_rectangle(rectangle)
	if dd.open {
		changed = take_dropdown_input(dd, len(options), over)
	} else if over && !is_pointer_claimed() {
		claim_pointer()
		if is_button_pressed(.LEFT) do dd.open = true
	}

	render_rectangle(rectangle, style.hover if over else style.fill)
	render_rectangle_border(rectangle, style.border, style.border_thickness)

	label := options[dd.selected]
	render_text(font, label, {rectangle.min.x + style.padding, calculate_baseline_centred(font, rectangle)}, style.text_color)

	// A triangle pointing the way the list will open, sized off the box
	size := calculate_rectangle_size(rectangle)
	half := min(size.y * 0.18, size.x * 0.25)
	centre := [2]f32{rectangle.max.x - style.padding - half, calculate_rectangle_centre(rectangle).y}
	tip := centre.y - half * 0.8 // +Y is up, so a list opening downwards points down
	base := centre.y + half * 0.6
	if dd.open do tip, base = base, tip
	render_triangle({centre.x - half, base}, {centre.x + half, base}, {centre.x, tip}, style.text_color)

	return changed
}

/*Opens the list at a point, with no box: a context menu. `row_size` is the list's width and each entry's height*/
open_context_menu :: proc(dd: ^Dropdown, point: [2]f32, row_size: [2]f32) {
	dd.anchor = .POINT
	dd.rectangle = {min = point, max = {point.x + row_size.x, point.y}}
	dd.row = row_size
	dd.selected = -1
	dd.open = true
	dd.opened_on = ui_state.frame
}

/*The input half of a context menu. `picked` is true on the frame an entry is chosen: every pick, including the same one twice, since each is an action*/
context_menu :: proc(dd: ^Dropdown, options: []string, style := DROPDOWN_STYLE) -> (chosen: int, picked: bool) {
	if !dd.open do return -1, false

	if len(options) == 0 {
		dd.open = false
		return -1, false
	}

	if dd.opened_on == ui_state.frame {
		claim_pointer()
		return -1, false
	}

	take_dropdown_input(dd, len(options), false)
	if !dd.open && dd.selected >= 0 do return dd.selected, true
	return -1, false
}

/*
	The input an open list takes. It is on top, so it takes the pointer whether or not the click lands on a row: otherwise
	closing it by clicking away also presses whatever was under that spot. Either button puts it away
*/
@(private)
take_dropdown_input :: proc(dd: ^Dropdown, count: int, over_anchor: bool) -> (changed: bool) {
	// The plain test, not the clipped one: the list is drawn late and outside any clip, so a dropdown inside a scrolling
	// panel opens a list that reaches past the panel, and takes the pointer there too
	if over_anchor || is_point_in_rectangle(get_pointer_position(), calculate_dropdown_list(dd, count)) do claim_pointer()

	if !is_button_pressed(.LEFT) && !is_button_pressed(.RIGHT) do return false

	if hit := get_dropdown_row_at(dd, count, get_pointer_position()); hit >= 0 {
		changed = hit != dd.selected
		dd.selected = hit
		dd.open = false
		return changed
	}

	dd.open = false
	return false
}

/*The open list, drawn over whatever came after it. Nothing when closed, so it can be called unconditionally at the end of a frame*/
render_dropdown_overlay :: proc(dd: ^Dropdown, options: []string, style := DROPDOWN_STYLE, font: ^Font = nil) {
	if !dd.open || len(options) == 0 do return
	font := font if font != nil else default_font()

	list := calculate_dropdown_list(dd, len(options))
	render_rectangle(list, style.list_background)
	render_rectangle_border(list, style.border, style.border_thickness)

	mouse := get_pointer_position()
	for option, index in options {
		row := calculate_dropdown_row(dd, index, len(options))
		if is_point_in_rectangle(mouse, row) do render_rectangle(row, style.hover)

		color := style.text_color
		if dd.anchor == .BOX && index == dd.selected do color = style.mark

		render_text(font, option, {row.min.x + style.padding, calculate_baseline_centred(font, row)}, color)
	}
}

is_dropdown_open :: proc(dd: ^Dropdown) -> bool {
	return dd.open
}

close_dropdown :: proc(dd: ^Dropdown) {
	dd.open = false
}

/*
	The whole open list: under whatever it hangs from, turned up when there is more room above than below, and pulled left
	when it would run off the right edge. A context menu opens wherever the pointer is, and the bottom of the window is an
	ordinary place to right-click
*/
calculate_dropdown_list :: proc(dd: ^Dropdown, count: int) -> Rectangle {
	width := dd.row.x
	height := f32(count) * dd.row.y + f32(max(0, count - 1)) * DEFAULTS.dropdown_row_gap

	left := dd.rectangle.min.x
	top := dd.rectangle.min.y // hangs under the bottom edge of what it is anchored to

	screen := get_screen_rectangle()
	below := top - screen.min.y
	above := screen.max.y - dd.rectangle.max.y
	if height > below && above > below do top = dd.rectangle.max.y + height // sits on top of the anchor instead

	if left + width > screen.max.x do left = screen.max.x - width
	if left < screen.min.x do left = screen.min.x

	return {min = {left, top - height}, max = {left + width, top}}
}

/*One row of the open list, from the list so the two cannot disagree about where a flipped list ended up*/
calculate_dropdown_row :: proc(dd: ^Dropdown, index: int, count: int) -> Rectangle {
	list := calculate_dropdown_list(dd, count)
	top := list.max.y - f32(index) * (dd.row.y + DEFAULTS.dropdown_row_gap)
	return {min = {list.min.x, top - dd.row.y}, max = {list.max.x, top}}
}

get_dropdown_row_at :: proc(dd: ^Dropdown, count: int, point: [2]f32) -> int {
	for index in 0 ..< count {
		if is_point_in_rectangle(point, calculate_dropdown_row(dd, index, count)) do return index
	}
	return -1
}
