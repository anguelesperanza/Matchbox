#+build windows

package ui

import "core:math"
import "core:strings"
import "core:unicode/utf8"

import mb ".."

TEXT_FIELD_FILL :: [4]f32{0.12, 0.12, 0.15, 1}
TEXT_FIELD_PLACEHOLDER :: [4]f32{0.6, 0.6, 0.6, 1}
TEXT_FIELD_FOCUS_RING :: [4]f32{1, 1, 1, 1}
TEXT_FIELD_LABEL :: [4]f32{0.78, 0.80, 0.86, 1}

/*
	A single line of typed text, UTF-8 throughout. No selection, no dragging the caret, no scrolling when the text outruns
	the box: it exists for names and paths
*/
Text_Field :: struct {
	rectangle:   Rectangle,
	fill:        [4]f32, // TEXT_FIELD_FILL when left at zero
	text:        [dynamic]u8,
	placeholder: string, // shown, dimmed, while empty
	caret:       int, // byte offset, always on a character boundary
	focused:     bool,
	max_bytes:   int, // 0 for no limit

	// Drawn above the box. Not part of `rectangle`, so the hit test and the caret are untouched by it; place_text_field
	// leaves room for it
	label:       string,
	label_color: [4]f32,

	// When the caret last moved: it is drawn solid for half a second after, so it does not blink out mid-keystroke
	blink_from: f64,
}

destroy_text_field :: proc(field: ^Text_Field) {
	delete(field.text)
	field.text = nil
}

/*What has been typed. Points into the field*/
get_text_field_string :: proc(field: ^Text_Field) -> string {
	return string(field.text[:])
}

/*Replaces the contents, caret at the end*/
set_text_field_text :: proc(field: ^Text_Field, text: string) {
	clear(&field.text)
	append(&field.text, text)
	field.caret = len(field.text)
	field.blink_from = ui_state.time
}

/*
	Takes this frame's input when the field has focus. Clicking inside focuses it and clicking anywhere else drops focus, so
	several fields on one screen have one focus between them without knowing about each other.

	Turns typing on while focused and never off: the screen owning the fields calls end_text_input when it closes, so one
	field cannot switch input off in the same frame another switched it on
*/
update_text_field :: proc(field: ^Text_Field) {
	if is_button_pressed(.LEFT) && !is_pointer_claimed() {
		field.focused = is_pointer_over_rectangle(field.rectangle)
		if field.focused do field.blink_from = ui_state.time
	}

	if !field.focused do return
	start_text_input()

	edited := false
	defer if edited do field.blink_from = ui_state.time

	if typed := get_text_input(); len(typed) > 0 {
		insert_text_field_text(field, typed)
		edited = true
	}

	if mb.is_key_held(.CONTROL) && mb.is_key_pressed(.V) {
		// A pasted newline would be invisible in a one-line box
		insert_text_field_text(field, strings.trim_space(mb.get_clipboard_text(context.temp_allocator)))
		edited = true
	}

	if mb.is_key_repeated(.BACK) && field.caret > 0 {
		_, size := utf8.decode_last_rune(field.text[:field.caret])
		remove_range(&field.text, field.caret - size, field.caret)
		field.caret -= size
		edited = true
	}
	if mb.is_key_repeated(.DELETE) && field.caret < len(field.text) {
		_, size := utf8.decode_rune(field.text[field.caret:])
		remove_range(&field.text, field.caret, field.caret + size)
		edited = true
	}
	if mb.is_key_repeated(.LEFT) && field.caret > 0 {
		_, size := utf8.decode_last_rune(field.text[:field.caret])
		field.caret -= size
		edited = true
	}
	if mb.is_key_repeated(.RIGHT) && field.caret < len(field.text) {
		_, size := utf8.decode_rune(field.text[field.caret:])
		field.caret += size
		edited = true
	}
	if mb.is_key_pressed(.HOME) {
		field.caret = 0
		edited = true
	}
	if mb.is_key_pressed(.END) {
		field.caret = len(field.text)
		edited = true
	}
}

/*Puts text in at the caret, as far as `max_bytes` allows, cut on a character boundary so a long paste never leaves broken UTF-8*/
insert_text_field_text :: proc(field: ^Text_Field, text: string) {
	text := text
	if field.max_bytes > 0 {
		room := field.max_bytes - len(field.text)
		if room <= 0 do return
		if len(text) > room {
			cut := room
			for cut > 0 && text[cut] & 0xc0 == 0x80 do cut -= 1
			text = text[:cut]
		}
	}
	if len(text) == 0 do return

	inject_at(&field.text, field.caret, text)
	field.caret += len(text)
}

/*The room the label takes above the box, gap included. Zero without one*/
calculate_text_field_label_height :: proc(field: ^Text_Field, font: ^Font = nil) -> f32 {
	if len(field.label) == 0 do return 0
	font := font if font != nil else default_font()
	return font.ascent + font.descent + DEFAULTS.text_field_gap
}

/*The whole height a field takes, label included, for a box `box_height` tall*/
calculate_text_field_height :: proc(field: ^Text_Field, box_height: f32, font: ^Font = nil) -> f32 {
	return calculate_text_field_label_height(field, font) + box_height
}

/*Puts the field, label and box together, at `top_left`, with a box `size` big. Set `label` first*/
place_text_field :: proc(field: ^Text_Field, top_left: [2]f32, size: [2]f32, font: ^Font = nil) {
	box_top := top_left.y - calculate_text_field_label_height(field, font)
	field.rectangle = {min = {top_left.x, box_top - size.y}, max = {top_left.x + size.x, box_top}}
}

/*Draws the label, the box, the text and the caret. After update_text_field*/
render_text_field :: proc(field: ^Text_Field, font: ^Font = nil) {
	font := font if font != nil else default_font()
	rectangle := field.rectangle

	render_rectangle(rectangle, field.fill if field.fill != {} else TEXT_FIELD_FILL)

	baseline := calculate_baseline_centred(font, rectangle)
	left := rectangle.min.x + DEFAULTS.text_field_padding

	if len(field.label) > 0 {
		color := field.label_color if field.label_color != {} else TEXT_FIELD_LABEL
		render_text(font, field.label, {rectangle.min.x, rectangle.max.y + DEFAULTS.text_field_gap + font.descent}, color)
	}

	if field.focused do render_rectangle_border(rectangle, TEXT_FIELD_FOCUS_RING, DEFAULTS.text_field_ring)

	shown := get_text_field_string(field)
	if len(shown) > 0 {
		render_text(font, shown, {left, baseline}, WHITE)
	} else if len(field.placeholder) > 0 {
		render_text(font, field.placeholder, {left, baseline}, TEXT_FIELD_PLACEHOLDER)
	}

	if !field.focused do return

	blink := f64(DEFAULTS.text_field_blink)
	since := ui_state.time - field.blink_from
	if since > blink * 0.5 && math.mod(since, blink) > blink * 0.5 do return

	before := shown[:field.caret]
	caret_x := left + calculate_text_size(font, before).x
	render_rectangle({min = {caret_x, baseline - font.descent}, max = {caret_x + DEFAULTS.text_field_caret, baseline + font.ascent}}, WHITE)
}
