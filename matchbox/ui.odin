package matchbox

/*
	ui.odin
	-------

	This is a place to add very basic UI elements that can be resued between projects.
	Nothing in here is polished at the moment and only has what it is needed for the current project
*/

import "core:math"
import "core:strings"
import "core:unicode/utf8"

import sdl "vendor:sdl3"

Button :: struct {
	text:string,
	rectangle:Rectangle,
}

draw_button :: proc(button:Button) {
	draw_rect(button.rectangle)

	// Centre the label in the box. draw_text's y is a baseline rather than a top
	// edge, so the ascent has to be added on -- without it the glyphs hang above
	// the button instead of sitting inside it.
	top_left := rect_top_left(button.rectangle)
	text     := measure_text(&mbi.font, button.text)

	draw_text(
		&mbi.font,
		button.text,
		top_left.x + (button.rectangle.size.x - text.x) * 0.5,
		top_left.y + (button.rectangle.size.y - text.y) * 0.5 + mbi.font.ascent,
		WHITE,
	)
}


mouse_over_button :: proc(button:Button) -> bool {
	// Off rect_top_left, not off `position`: the two only agree when the pivot
	// is {0.5, 0.5}, and getting this wrong offsets the whole hitbox from the
	// button you can see by half its size.
	top_left := rect_top_left(button.rectangle)
	size     := button.rectangle.size
	mouse    := get_mouse_position()

	return mouse.x >= top_left.x && mouse.x <= top_left.x + size.x &&
	       mouse.y >= top_left.y && mouse.y <= top_left.y + size.y
}

/*
	A border of one even thickness all the way round, in pixels.

	Four rectangles rather than draw_rect_outline, because that one's `border`
	is a fraction compared against uv on both axes -- so the thickness it
	produces is `border * size` per axis, and on anything that is not square it
	comes out heavier along the long side. On a 460x52 text box a border of
	0.04 is eighteen pixels at the sides and two at the top, which swallows the
	first characters typed into it.

	Use this whenever the thickness should look the same all the way round.
	draw_rect_outline is still the one to use when the border should scale with
	the shape, which is what a card-shaped zone wants.
*/
draw_rect_border :: proc(rectangle:Rectangle, color:[4]f32, thickness:f32) {
	top_left := rect_top_left(rectangle)
	size     := rectangle.size

	// Corners are covered twice. With a flat colour that is invisible, and it
	// is cheaper than four rects mitred to meet exactly.
	bar :: proc(x, y, w, h:f32, color:[4]f32) {
		draw_rect({position = {x, y}, size = {w, h}, pivot = {0.5, 0.5}, color = color})
	}

	bar(top_left.x, top_left.y,                          size.x,    thickness, color)
	bar(top_left.x, top_left.y + size.y - thickness,     size.x,    thickness, color)
	bar(top_left.x, top_left.y,                          thickness, size.y,    color)
	bar(top_left.x + size.x - thickness, top_left.y,     thickness, size.y,    color)
}

// -----------------------------------------------------------------------
// Text_Field -- somewhere to type
// -----------------------------------------------------------------------

TEXT_FIELD_PADDING     :: 8    // gap between the box edge and the text
TEXT_FIELD_CARET_WIDTH :: 2
TEXT_FIELD_RING        :: 2    // pixels, all the way round
TEXT_FIELD_BLINK       :: 1.06 // seconds for a full off-on cycle
TEXT_FIELD_MASK        :: '*'

TEXT_FIELD_PLACEHOLDER: [4]f32 = {0.6, 0.6, 0.6, 1}
TEXT_FIELD_FOCUS_RING:  [4]f32 = {1, 1, 1, 1}

/*
	A single line of typed text.

	What it deliberately is not: there is no selection, no dragging the caret
	with the mouse, and no scrolling when the text outruns the box. It exists
	for the short answers a game asks for -- a password, an address, a name --
	and everything left out is a day's work that none of those need. Reach for
	a real editor widget before growing this one into one.

	utf-8 throughout. `caret` is a byte offset but only ever lands on a
	character boundary, because everything that moves it steps whole runes.
*/
Text_Field :: struct {
	rectangle:   Rectangle,
	text:        [dynamic]u8,
	placeholder: string, // shown, dimmed, while empty
	caret:       int,    // byte offset into text
	focused:     bool,
	masked:      bool,   // draw every character as TEXT_FIELD_MASK
	max_bytes:   int,    // 0 for no limit. Bytes, not characters

	// When the caret last moved. The caret is drawn solid for the first half
	// second after any edit, so it does not blink out mid-keystroke and look
	// like the field stopped listening.
	blink_from: u64,
}

/*Frees what the field owns. The Rectangle and strings in it are the caller's*/
destroy_text_field :: proc(field:^Text_Field) {
	delete(field.text)
	field.text = nil
}

/*What has been typed. Points into the field and changes as it is edited*/
text_field_string :: proc(field:^Text_Field) -> string {
	return string(field.text[:])
}

/*Replaces the contents outright, putting the caret at the end*/
text_field_set :: proc(field:^Text_Field, text:string) {
	clear(&field.text)
	append(&field.text, text)
	field.caret      = len(field.text)
	field.blink_from = mbi.now_ts
}

mouse_over_text_field :: proc(field:^Text_Field) -> bool {
	top_left := rect_top_left(field.rectangle)
	size     := field.rectangle.size
	mouse    := get_mouse_position()

	return mouse.x >= top_left.x && mouse.x <= top_left.x + size.x &&
	       mouse.y >= top_left.y && mouse.y <= top_left.y + size.y
}

/*
	Takes this frame's input, when the field has focus.

	Call once a frame for every field on screen, before drawing them. Clicking
	inside focuses; clicking anywhere else drops focus, which is what gives
	several fields on one screen exactly one focus between them without them
	having to know about each other.

	Turns text input on while focused, and never turns it off -- the screen
	owning these fields calls end_text_input when it closes. Doing it per field
	would let one field switch input off in the same frame another switched it
	on, and which won would come down to update order.
*/
update_text_field :: proc(field:^Text_Field) {
	if is_mouse_pressed(.LEFT) {
		field.focused = mouse_over_text_field(field)
		if field.focused do field.blink_from = mbi.now_ts
	}

	if !field.focused do return
	begin_text_input()

	edited := false
	defer if edited do field.blink_from = mbi.now_ts

	// Typed characters, already resolved by the keyboard layout and any IME
	if typed := get_text_input(); len(typed) > 0 {
		text_field_insert(field, typed)
		edited = true
	}

	ctrl := is_key_held(.LCTRL) || is_key_held(.RCTRL)
	if ctrl && is_key_pressed(.V) {
		pasted := get_clipboard_text(context.temp_allocator)

		// A pasted newline would be invisible in a one line box and would
		// travel wherever the value goes next
		text_field_insert(field, strings.trim_space(pasted))
		edited = true
	}

	// Repeated rather than pressed, so holding one of these keeps going at the
	// system's own repeat rate instead of acting once
	if is_key_repeated(.BACKSPACE) && field.caret > 0 {
		_, size := utf8.decode_last_rune(field.text[:field.caret])
		remove_range(&field.text, field.caret - size, field.caret)
		field.caret -= size
		edited = true
	}

	if is_key_repeated(.DELETE) && field.caret < len(field.text) {
		_, size := utf8.decode_rune(field.text[field.caret:])
		remove_range(&field.text, field.caret, field.caret + size)
		edited = true
	}

	if is_key_repeated(.LEFT) && field.caret > 0 {
		_, size := utf8.decode_last_rune(field.text[:field.caret])
		field.caret -= size
		edited = true
	}

	if is_key_repeated(.RIGHT) && field.caret < len(field.text) {
		_, size := utf8.decode_rune(field.text[field.caret:])
		field.caret += size
		edited = true
	}

	if is_key_pressed(.HOME) { field.caret = 0;               edited = true }
	if is_key_pressed(.END)  { field.caret = len(field.text); edited = true }
}

/*
	Puts text in at the caret, as far as max_bytes allows.

	Truncated on a character boundary rather than a byte one, or a paste ending
	mid-character would leave broken utf-8 in the field.
*/
text_field_insert :: proc(field:^Text_Field, text:string) {
	text := text
	if field.max_bytes > 0 {
		room := field.max_bytes - len(field.text)
		if room <= 0 do return

		if len(text) > room {
			cut := room
			for cut > 0 && text[cut] & 0xc0 == 0x80 do cut -= 1 // back off a continuation byte
			text = text[:cut]
		}
	}
	if len(text) == 0 do return

	inject_at(&field.text, field.caret, text)
	field.caret += len(text)
}

/*Draws the box, what is in it, and the caret. Call after update_text_field*/
draw_text_field :: proc(field:^Text_Field) {
	draw_rect(field.rectangle)

	top_left := rect_top_left(field.rectangle)
	baseline := top_left.y + (field.rectangle.size.y - (mbi.font.ascent + mbi.font.descent)) * 0.5 + mbi.font.ascent
	left     := top_left.x + TEXT_FIELD_PADDING

	if field.focused do draw_rect_border(field.rectangle, TEXT_FIELD_FOCUS_RING, TEXT_FIELD_RING)

	shown := text_field_shown(field, context.temp_allocator)

	if len(shown) > 0 {
		draw_text(&mbi.font, shown, left, baseline, WHITE)
	} else if len(field.placeholder) > 0 {
		draw_text(&mbi.font, field.placeholder, left, baseline, TEXT_FIELD_PLACEHOLDER)
	}

	if !field.focused do return

	// Solid for the first half second after a keystroke, blinking after that
	since := f32(mbi.now_ts - field.blink_from) / f32(mbi.ts_freq)
	if since > TEXT_FIELD_BLINK * 0.5 && math.mod(since, TEXT_FIELD_BLINK) > TEXT_FIELD_BLINK * 0.5 do return

	// Measured off what is on screen, not off the real text: with a masked
	// field those are different widths, and the caret has to follow the stars
	before := shown[:text_field_shown_caret(field)]

	draw_rect({
		position = {left + measure_text(&mbi.font, before).x, baseline - mbi.font.ascent},
		size     = {TEXT_FIELD_CARET_WIDTH, mbi.font.ascent + mbi.font.descent},
		pivot    = {0.5, 0.5}, // position is the top-left corner
		color    = WHITE,
	})
}

/*What the field puts on screen: its text, or one star per character when masked*/
text_field_shown :: proc(field:^Text_Field, allocator := context.allocator) -> string {
	if !field.masked do return text_field_string(field)

	// Per character, not per byte, or an accented letter would show as two
	stars := strings.builder_make(allocator)
	for _ in string(field.text[:]) do strings.write_rune(&stars, TEXT_FIELD_MASK)

	return strings.to_string(stars)
}

/*Where the caret sits within text_field_shown, which masking makes a different string*/
text_field_shown_caret :: proc(field:^Text_Field) -> int {
	if !field.masked do return field.caret

	return utf8.rune_count_in_string(string(field.text[:field.caret]))
}
