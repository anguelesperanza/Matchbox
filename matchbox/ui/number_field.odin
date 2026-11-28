#+build windows

package ui

import "core:math"
import "core:strconv"
import "core:strings"

import mb ".."

Number_Field_Style :: struct {
	speed:          f32, // how far the value moves per unit dragged
	step:           f32, // what the value snaps to; zero is continuous
	drag_threshold: f32, // units before a press is a drag rather than a click
	decimals:       int,

	fill:       [4]f32,
	hover:      [4]f32,
	active:     [4]f32, // while dragging or typing
	text_color: [4]f32,
}

NUMBER_FIELD_STYLE :: Number_Field_Style {
	speed          = 0.01,
	drag_threshold = 3,
	decimals       = 2,
	fill           = {0.16, 0.16, 0.20, 1},
	hover          = {0.22, 0.22, 0.28, 1},
	active         = {0.26, 0.34, 0.52, 1},
	text_color     = {0.92, 0.92, 0.95, 1},
}

/*Held by the caller, one per field. The number itself is the caller's, passed by pointer*/
Number_Field :: struct {
	pressed:     bool,
	dragging:    bool,
	press_x:     f32,
	press_value: f32,

	typing: bool,
	text:   Text_Field,
	shown:  [32]u8, // the number as the placeholder while typing
}

/*
	A number changed by dragging sideways across it, or by clicking and typing. True on any frame the value changes.

	**A drag is measured from where it started**, so the value does not drift, and `style.step` snaps the result rather than
	each frame's change. **A click that does not drag opens the field for typing**, empty, with the number as the
	placeholder. Enter or a click elsewhere keeps what was typed when it is a number; Escape, or text that is not one,
	leaves the value as it was
*/
number_field :: proc(field: ^Number_Field, rectangle: Rectangle, value: ^f32, style := NUMBER_FIELD_STYLE, font: ^Font = nil) -> (changed: bool) {
	changed = update_number_field(field, rectangle, value, style)
	render_number_field(field, rectangle, value^, style, font)
	return changed
}

/*Whether a drag or typing is under way: when an editor takes an undo step*/
is_number_field_active :: proc(field: ^Number_Field) -> bool {
	return field.dragging || field.typing
}

destroy_number_field :: proc(field: ^Number_Field) {
	destroy_text_field(&field.text)
}

@(private)
update_number_field :: proc(field: ^Number_Field, rectangle: Rectangle, value: ^f32, style: Number_Field_Style) -> (changed: bool) {
	before := value^

	if field.typing {
		field.text.rectangle = rectangle
		update_text_field(&field.text)

		switch {
		case mb.is_key_pressed(.ESCAPE):
			stop_number_field_typing(field)
		case mb.is_key_pressed(.RETURN) || mb.is_key_pressed(.KEYPAD_ENTER) || !field.text.focused:
			typed := strings.trim_space(get_text_field_string(&field.text))
			if parsed, ok := strconv.parse_f32(typed); ok && len(typed) > 0 {
				value^ = calculate_number_snapped(parsed, style.step)
			}
			stop_number_field_typing(field)
		}
		return value^ != before
	}

	mouse := get_pointer_position()

	switch {
	case field.pressed && !is_button_held(.LEFT):
		// Let go. Without having dragged, that was a click
		if !field.dragging do start_number_field_typing(field, rectangle, value^, style)
		field.pressed = false
		field.dragging = false

	case field.pressed:
		if !field.dragging && math.abs(mouse.x - field.press_x) >= style.drag_threshold do field.dragging = true
		if field.dragging do value^ = calculate_number_snapped(field.press_value + (mouse.x - field.press_x) * style.speed, style.step)
		claim_pointer()

	case is_button_pressed(.LEFT) && !is_pointer_claimed() && is_pointer_over_rectangle(rectangle):
		field.pressed = true
		field.dragging = false
		field.press_x = mouse.x
		field.press_value = value^
		claim_pointer()
	}

	return value^ != before
}

@(private)
start_number_field_typing :: proc(field: ^Number_Field, rectangle: Rectangle, value: f32, style: Number_Field_Style) {
	field.typing = true
	set_text_field_text(&field.text, "")
	field.text.placeholder = calculate_number_text(field.shown[:], value, style.decimals)
	field.text.rectangle = rectangle
	field.text.focused = true
	field.text.blink_from = ui_state.time
	start_text_input()
}

@(private)
stop_number_field_typing :: proc(field: ^Number_Field) {
	field.typing = false
	field.text.focused = false
	// Typing is the screen's to turn off, but a field that turned it on for itself turns it off again
	end_text_input()
}

/*
	A number as the field shows it. No "+" (strconv always writes a sign) and no "-0.00" for a number that shows as zero: a
	rotation turned back into angles gives -0 for an unturned axis, which read "-0.0" in the inspector
*/
@(private)
calculate_number_text :: proc(buffer: []u8, value: f32, decimals: int) -> string {
	text := strings.trim_prefix(strconv.write_float(buffer, f64(value), 'f', decimals, 32), "+")
	if len(text) > 1 && text[0] == '-' && strings.trim_left(text[1:], "0.") == "" do text = text[1:]
	return text
}

@(private)
calculate_number_snapped :: proc(value, step: f32) -> f32 {
	if step <= 0 do return value
	return math.round(value / step) * step
}

@(private)
render_number_field :: proc(field: ^Number_Field, rectangle: Rectangle, value: f32, style: Number_Field_Style, font: ^Font) {
	font := font if font != nil else default_font()

	fill: [4]f32
	switch {
	case field.dragging || field.typing:
		fill = style.active
	case is_pointer_over_rectangle(rectangle) && !is_pointer_claimed():
		fill = style.hover
	case:
		fill = style.fill
	}

	if field.typing {
		field.text.rectangle = rectangle
		field.text.fill = fill
		render_text_field(&field.text, font)
		return
	}

	render_rectangle(rectangle, fill)

	buffer: [32]u8
	text := calculate_number_text(buffer[:], value, style.decimals)

	begin_clip(rectangle)
	render_text(font, text, {rectangle.min.x + 8, calculate_baseline_centred(font, rectangle)}, style.text_color)
	end_clip()
}
