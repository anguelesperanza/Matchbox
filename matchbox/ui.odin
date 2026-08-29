package matchbox

/*
	ui.odin
	-------

	This is a place to add very basic UI elements that can be resued between projects.
	Nothing in here is polished at the moment and only has what it is needed for the current project

	  button / Button_Style   draws, hovers, answers a click, and can be disabled
	  button_confirm          asks first, for anything that cannot be undone
	  Hover / hover_dwell     the pointer resting on something rather than crossing it
	  draw_text_plate         text on a plate, so it survives landing on pale artwork
	  draw_rect_border        a border of one even thickness all the way round
	  Text_Field              somewhere to type, with its label above it
	  Scroll_View             a panel whose contents can be taller than it is
	  Dropdown                pick one of a list, at a box or at a point
	  draw_tooltip            a plate beside the cursor, kept on screen
	  Status_Line             a short message with a severity colour
	  Modal                   a full-screen dim with something centred on top
	  draw_progress           a bar from 0 to 1

	Three of these come in two halves -- Scroll_View, Dropdown and Modal -- and
	the reason is the same each time. Drawing is immediate, so what opens out
	over the screen has to be drawn last; but every widget tests the mouse for
	itself, so the same widget has to take the pointer first. See examples/ui,
	whose header lays the order out.

	All of it is here, and that is the point. Some of this was briefly spread
	over a `widgets.odin`, a `scroll.odin` and a `dropdown.odin`, split up
	because this file was getting long -- which is a reason to split *a* file and
	not a reason to split *this* one. "Widgets" and "ui" are the same word, and
	somebody looking for a tooltip had no way to guess which of four files it
	was in. One long file you can search beats four you have to choose between.

	Layout and Grid are still in layout.odin, for a different reason: they draw
	nothing and answer no input. They hand back Rectangles, and everything here
	takes one.
*/

import "core:math"
import "core:strings"
import "core:unicode/utf8"

// Whether a label sits in the middle of its box or against the left edge.
// Left is what a list of options wants -- centred labels in a stacked column
// make ragged edges on both sides and nothing lines up.
Text_Align :: enum {
	CENTER,
	LEFT,
}

Button_Style :: struct {
	hover:      [4]f32, // fill while the pointer is over it
	text_color: [4]f32,
	align:      Text_Align,
	padding:    f32, // gap from the left edge when aligned LEFT

	// A button that is there and cannot be pressed: drawn dimmed, never
	// highlighted, and never true. This is in the style rather than being a
	// separate procedure because "can this be pressed" changes per frame and per
	// button, and every caller that had to handle it by hand ended up dropping
	// out of `button` altogether and back to Button / draw_button /
	// mouse_over_button -- which is the wrapper `button` was added to retire.
	disabled:     bool,

	// What the fill and the label are multiplied by while disabled. A factor
	// rather than a colour, so it dims whatever palette the caller is using
	// without being told about it. Alpha is left alone: a disabled button is
	// still there.
	disabled_dim: f32,
}

// The dim used when a style was built from scratch and left this at zero.
// Without it a hand-made Button_Style would draw a disabled button in black
// rather than a dimmed version of its own colour.

/*
	Every number the widgets in this file measure themselves by.

	One struct rather than the twenty-two loose constants this used to be,
	scattered down two thousand lines beside whichever widget first needed one.
	They are the same kind of thing -- a size, a colour or a duration a widget
	uses when nobody said otherwise -- and grouping them means a game retheming
	the UI reads one declaration instead of hunting.

	`BUTTON_STYLE` stays separate and is not folded in here: it is a value a
	game copies and edits (`style := mb.BUTTON_STYLE; style.hover = ...`),
	which is a different job from a default nothing overrides.
*/
Ui_Confirm_Defaults :: struct {
	timeout:     f32, // seconds before an armed button forgets
	armed:       [4]f32,
	armed_hover: [4]f32,
}

Ui_Text_Plate_Defaults :: struct {
	bg:      [4]f32,
	fg:      [4]f32,
	padding: [2]f32,
}

Ui_Text_Field_Defaults :: struct {
	padding:     f32, // gap between the box edge and the text
	caret_width: f32,
	ring:        f32, // pixels, all the way round
	label_gap:   f32, // between the label's baseline row and the box
	blink:       f32, // seconds for a full off-on cycle
	mask:        rune,
}

Ui_Scroll_Defaults :: struct {
	bar_width:  f32,
	thumb_min:  f32, // shortest the thumb is allowed to get
	inset:      f32, // gap between the bar and the panel edge
	wheel_step: f32, // pixels per notch of the wheel
}

Ui_Dropdown_Defaults :: struct {
	padding: f32, // gap from the box edge to the label
	row_gap: f32, // hairline between options, so a long list reads as rows
}

Ui_Defaults :: struct {
	// The dim a style built from scratch falls back to. Without it a hand-made
	// Button_Style would draw a disabled button in black rather than a dimmed
	// version of its own colour.
	button_disabled_dim: f32,

	hover_dwell:         f32, // seconds the pointer must rest before it counts
	status_fade:         f32, // seconds a timed message spends fading out
	slider_handle_width: f32,

	confirm:    Ui_Confirm_Defaults,
	text_plate: Ui_Text_Plate_Defaults,
	text_field: Ui_Text_Field_Defaults,
	scroll:     Ui_Scroll_Defaults,
	dropdown:   Ui_Dropdown_Defaults,
}

UI_DEFAULTS :: Ui_Defaults{
	button_disabled_dim = 0.45,
	hover_dwell         = 0.4,
	status_fade         = 0.5,
	slider_handle_width = 14,

	confirm = {
		timeout     = 3.0,
		armed       = {0.55, 0.18, 0.18, 1},
		armed_hover = {0.70, 0.24, 0.24, 1},
	},

	text_plate = {
		bg      = {0, 0, 0, 0.65},
		fg      = {1, 1, 1, 1},
		padding = {6, 4},
	},

	text_field = {
		padding     = 8,
		caret_width = 2,
		ring        = 2,
		label_gap   = 4,
		blink       = 1.06,
		mask        = '*',
	},

	scroll = {
		bar_width  = 8,
		thumb_min  = 24,
		inset      = 2,
		wheel_step = 48,
	},

	dropdown = {
		padding = 8,
		row_gap = 1,
	},
}

BUTTON_STYLE :: Button_Style{
	hover        = {0.35, 0.35, 0.42, 1},
	text_color   = {1, 1, 1, 1},
	align        = .CENTER,
	padding      = 10,
	disabled_dim = UI_DEFAULTS.button_disabled_dim,
}

// Multiplies the colour channels and leaves alpha alone.
@(private)
dimmed :: proc(color: [4]f32, amount: f32) -> [4]f32 {
	dim := amount if amount > 0 else UI_DEFAULTS.button_disabled_dim
	return {color.r * dim, color.g * dim, color.b * dim, color.a}
}

/*
	A button that draws itself and answers in one call. True on the frame it is
	clicked.

		if matchbox.button({position = {40, 40}, size = {160, 40},
		                    color = {0.2, 0.2, 0.26, 1}, pivot = {0.5, 0.5}}, "Play") {
			start_game()
		}

	Everything a caller needs is at the call site: the size comes from the
	Rectangle rather than a fixed constant, and `style.align` puts the label
	left instead of centred. Those two are what every hand-rolled wrapper
	around Button/draw_button/mouse_over_button ended up adding.

	The fill comes from `rectangle.color`, and `style.hover` replaces it while
	the pointer is inside. Pass a style to change either, or leave it off.

	Button, draw_button and mouse_over_button are still here and unchanged, for
	anything that wants the parts separately.
*/
button :: proc(rectangle: Rectangle, text: string, style := BUTTON_STYLE, font: ^Font = nil) -> bool {
	font := font if font != nil else &mbi.font
	rect := rectangle

	// Not hovered when something above has claimed the pointer, which takes
	// care of the click and the highlight together: a button under an open
	// dropdown should neither light up nor answer. Nor when it is disabled,
	// which takes care of the highlight and the answer the same way.
	hovered := !style.disabled && mouse_over_rect(rectangle) && !mouse_captured()

	label := style.text_color

	switch {
	case style.disabled:
		rect.color = dimmed(rect.color, style.disabled_dim)
		label      = dimmed(label,      style.disabled_dim)
	case hovered:
		rect.color = style.hover
	}

	draw_rect(rect)

	if len(text) > 0 {
		top_left := rect_top_left(rect)
		measured := measure_text(font, text)

		x: f32
		switch style.align {
		case .CENTER: x = top_left.x + (rect.size.x - measured.x) * 0.5
		case .LEFT:   x = top_left.x + style.padding
		}

		// draw_text's y is a baseline rather than a top edge, so the ascent has
		// to be added or the glyphs hang above the box instead of sitting in it.
		y := top_left.y + (rect.size.y - measured.y) * 0.5 + font.ascent

		draw_text(font, text, x, y, label)
	}

	return hovered && is_mouse_pressed(.LEFT)
}

// A style with `disabled` set the way the caller says, which is the shape this
// is nearly always wanted in:
//
//	if matchbox.button(rect, "Play", matchbox.button_enabled_if(hand > 0)) { ... }
button_enabled_if :: proc(enabled: bool, style := BUTTON_STYLE) -> Button_Style {
	style := style
	style.disabled = !enabled
	return style
}

// Whether the pointer is inside a rectangle. point_in_rect with the mouse
// already filled in, which is what almost every caller wants.
mouse_over_rect :: proc(rectangle: Rectangle) -> bool {
	return point_in_rect(get_mouse_position(), rectangle)
}

// -----------------------------------------------------------------------
// Confirm-on-second-press
// -----------------------------------------------------------------------


// Two colours, because an armed button is nearly always under the pointer --
// you are about to press it again. If arming only changed the resting colour,
// the ordinary hover fill would paint over the warning at exactly the moment
// it matters.

// Held by the caller, one per button, like Text_Field. Zero value is unarmed.
Confirm_Button :: struct {
	armed_at: u64, // 0 when unarmed
}

/*
	A button that asks first. True only on the second press.

	The Delete-then-"Sure?" pattern, for anything that cannot be undone. The
	first press arms it and swaps the label; the second confirms.

		if matchbox.button_confirm(&delete, rect, "Delete", "Sure?") {
			delete_deck(deck)
		}

	It disarms on three things, in rough order of how often they happen: the
	pointer being clicked anywhere else, UI_DEFAULTS.confirm.timeout passing, and the
	pointer leaving is deliberately *not* one of them -- moving off a button by
	a pixel and back should not lose the arming, or the second press has to be
	hurried.

	Armed and unarmed are different colours as well as different labels,
	because a label alone is easy to click straight past.
*/
button_confirm :: proc(
	state:        ^Confirm_Button,
	rectangle:    Rectangle,
	text:         string,
	confirm_text: string,
	style        := BUTTON_STYLE,
	armed_color  := UI_DEFAULTS.confirm.armed,
	armed_hover  := UI_DEFAULTS.confirm.armed_hover,
) -> bool {
	armed := state.armed_at != 0

	// Forgotten after a while. Somebody who armed this and wandered off should
	// not come back to a button that deletes on one click.
	if armed && seconds_since(state.armed_at) > UI_DEFAULTS.confirm.timeout {
		state.armed_at = 0
		armed = false
	}

	// A click anywhere else is an answer of no.
	if armed && is_mouse_pressed(.LEFT) && !mouse_over_rect(rectangle) {
		state.armed_at = 0
		armed = false
	}

	rect  := rectangle
	shown := style

	if armed {
		rect.color  = armed_color
		shown.hover = armed_hover
	}

	if button(rect, confirm_text if armed else text, shown) {
		if armed {
			state.armed_at = 0
			return true
		}
		state.armed_at = mbi.now_ts
	}

	return false
}

// Whether it is currently asking. For anything that wants to dim the rest of a
// row while one of its buttons is waiting for an answer.
confirm_button_armed :: proc(state: ^Confirm_Button) -> bool {
	return state.armed_at != 0 && seconds_since(state.armed_at) <= UI_DEFAULTS.confirm.timeout
}

// -----------------------------------------------------------------------
// Hover dwell
// -----------------------------------------------------------------------


// Held by the caller, one per thing that can be dwelled on.
Hover :: struct {
	entered_at: u64, // 0 while the pointer is outside
}

/*
	True once the pointer has rested inside `rectangle` for `seconds`.

	The waiting is the feature. A full-size preview that appears on plain hover
	strobes its way across a grid as the pointer crosses it, opening and
	closing once per cell; requiring the pointer to settle means only the thing
	actually being looked at opens.

	Call once a frame for each candidate, whether or not it is hovered -- that
	is what notices the pointer leaving and resets the clock.

		if matchbox.hover_dwell(&preview, card_rect) {
			draw_closeup(card)
		}
*/
hover_dwell :: proc(state: ^Hover, rectangle: Rectangle, seconds: f32 = UI_DEFAULTS.hover_dwell) -> bool {
	// Something above has the pointer, so this is not being looked at even
	// though the pointer is over it. Cleared rather than merely reported, so
	// the dwell starts again once whatever it was closes
	if mouse_captured() {
		state.entered_at = 0
		return false
	}

	if !mouse_over_rect(rectangle) {
		state.entered_at = 0
		return false
	}

	if state.entered_at == 0 {
		state.entered_at = mbi.now_ts
		return false
	}

	return seconds_since(state.entered_at) >= seconds
}

// How far through the dwell the pointer is, 0 to 1. For drawing the wait --
// a ring filling, a bar creeping -- so it does not look like nothing is
// happening.
hover_progress :: proc(state: ^Hover, seconds: f32 = UI_DEFAULTS.hover_dwell) -> f32 {
	if state.entered_at == 0 || seconds <= 0 do return 0
	return clamp(seconds_since(state.entered_at) / seconds, 0, 1)
}

// Seconds since a performance-counter reading. The clock everything here uses
// is the one poll_events already keeps.
@(private)
seconds_since :: proc(ts: u64) -> f32 {
	if ts == 0 || mbi.ts_freq == 0 do return 0
	return f32(mbi.now_ts - ts) / f32(mbi.ts_freq)
}

Button :: struct {
	text:string,
	rectangle:Rectangle,
}

// Draws a button without asking whether it was clicked -- the drawing half of
// `button`, for a game that decides on its own terms what a click means.
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


// Whether the pointer is inside the button's rectangle. Hover, without the
// click.
mouse_over_button :: proc(button:Button) -> bool {
	return mouse_over_rect(button.rectangle)
}

// -----------------------------------------------------------------------
// Text on a plate
// -----------------------------------------------------------------------


/*
	Text on a dark plate cut to fit it. Returns the size of the plate.

	White text drawn straight over artwork disappears the moment it lands on
	something pale, and there is no outline or drop shadow here to fall back
	on. A plate behind it is the cheap fix and works over anything.

	Takes a **top-left**, not a baseline, unlike draw_text. Everything reaching
	for this is stacking boxes rather than typesetting, and the returned size is
	what to advance by:

		p := matchbox.draw_text_plate(font, name, {x, y})
		matchbox.draw_text_plate(font, cost, {x, y + p.y + 4})

	The height is the font's ascent plus descent rather than the extent of
	these particular glyphs, so a line of plates keeps one height whatever is
	written on them.
*/
draw_text_plate :: proc(
	font:      ^Font,
	text:      string,
	top_left:  [2]f32,
	color:     [4]f32 = UI_DEFAULTS.text_plate.fg,
	plate:     [4]f32 = UI_DEFAULTS.text_plate.bg,
	padding:   [2]f32 = UI_DEFAULTS.text_plate.padding,
) -> [2]f32 {
	measured := measure_text(font, text)
	size     := measured + padding * 2

	draw_rect({
		position = top_left,
		size     = size,
		color    = plate,
		pivot    = {0.5, 0.5}, // position is the top-left corner
	})

	draw_text(
		font, text,
		top_left.x + padding.x,
		top_left.y + padding.y + font.ascent,
		color,
	)

	return size
}

/*
	A border of one even thickness all the way round, in pixels.

	This exists because draw_rect_outline's `border` used to be a fraction
	compared against uv on both axes, which came out heavier along the long
	side of anything that was not square. That is fixed -- draw_rect_outline
	now takes a thickness in pixels and is even -- so the two agree, and this
	one is kept for taking a Rectangle directly.

	draw_rect_outline is the cheaper of the two: one draw against four, and it
	rotates with the shape. Reach for that unless you already have a Rectangle
	in hand. draw_outline_proportional is the one to use when the border should
	scale with the shape, which is what a card-shaped zone wants.
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



TEXT_FIELD_PLACEHOLDER: [4]f32 = {0.6, 0.6, 0.6, 1}
TEXT_FIELD_FOCUS_RING:  [4]f32 = {1, 1, 1, 1}
TEXT_FIELD_LABEL:       [4]f32 = {0.78, 0.80, 0.86, 1}

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
	masked:      bool,   // draw every character as UI_DEFAULTS.text_field.mask
	max_bytes:   int,    // 0 for no limit. Bytes, not characters

	// Drawn above the box when set. Every form field on a screen wants one, and
	// a label positioned by hand beside every field is the same four lines
	// written once per field and gone wrong once per redesign.
	//
	// The label is deliberately *not* part of `rectangle`: that stays the box, so
	// the hit test, the focus ring and the caret are untouched by adding one. It
	// does mean a labelled field takes up more room than its rectangle says, and
	// text_field_place and text_field_height are how to lay one out.
	label:       string,
	label_color: [4]f32, // TEXT_FIELD_LABEL when left at zero

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

// Whether the pointer is inside the field's box. What a game reads to show an
// I-beam cursor.
mouse_over_text_field :: proc(field:^Text_Field) -> bool {
	return mouse_over_rect(field.rectangle)
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
	// A click that belongs to something above neither focuses this field nor
	// takes focus off it -- picking an option out of a dropdown should leave
	// the caret where it was
	if is_mouse_pressed(.LEFT) && !mouse_captured() {
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

// How much room the label takes above the box, gap included. Zero without one.
text_field_label_height :: proc(field:^Text_Field, font:^Font = nil) -> f32 {
	if len(field.label) == 0 do return 0

	font := font if font != nil else &mbi.font
	return font.ascent + font.descent + UI_DEFAULTS.text_field.label_gap
}

// The whole height a field occupies, label included, for a box `box_height`
// tall. This is what a Layout or a form's own arithmetic needs.
text_field_height :: proc(field:^Text_Field, box_height:f32, font:^Font = nil) -> f32 {
	return text_field_label_height(field, font) + box_height
}

/*
	Puts the field where the whole thing -- label and box together -- starts at
	`top_left`, with a box `size` big.

	Set `label` before calling this, since where the box lands depends on whether
	there is one.
*/
text_field_place :: proc(field:^Text_Field, top_left:[2]f32, size:[2]f32, font:^Font = nil) {
	field.rectangle.position = {top_left.x, top_left.y + text_field_label_height(field, font)}
	field.rectangle.size     = size
	field.rectangle.pivot    = {0.5, 0.5} // position is the top-left corner
}

/*Draws the label, the box, what is in it, and the caret. Call after update_text_field*/
draw_text_field :: proc(field:^Text_Field, font:^Font = nil) {
	font := font if font != nil else &mbi.font

	draw_rect(field.rectangle)

	top_left := rect_top_left(field.rectangle)
	baseline := top_left.y + (field.rectangle.size.y - (font.ascent + font.descent)) * 0.5 + font.ascent
	left     := top_left.x + UI_DEFAULTS.text_field.padding

	if len(field.label) > 0 {
		color := field.label_color
		if color == {0, 0, 0, 0} do color = TEXT_FIELD_LABEL

		// Sitting on its own baseline directly above the box, which is what
		// text_field_place left room for.
		draw_text(font, field.label, top_left.x, top_left.y - UI_DEFAULTS.text_field.label_gap - font.descent, color)
	}

	if field.focused do draw_rect_border(field.rectangle, TEXT_FIELD_FOCUS_RING, UI_DEFAULTS.text_field.ring)

	shown := text_field_shown(field, context.temp_allocator)

	if len(shown) > 0 {
		draw_text(font, shown, left, baseline, WHITE)
	} else if len(field.placeholder) > 0 {
		draw_text(font, field.placeholder, left, baseline, TEXT_FIELD_PLACEHOLDER)
	}

	if !field.focused do return

	// Solid for the first half second after a keystroke, blinking after that
	since := f32(mbi.now_ts - field.blink_from) / f32(mbi.ts_freq)
	if since > UI_DEFAULTS.text_field.blink * 0.5 && math.mod(since, UI_DEFAULTS.text_field.blink) > UI_DEFAULTS.text_field.blink * 0.5 do return

	// Measured off what is on screen, not off the real text: with a masked
	// field those are different widths, and the caret has to follow the stars
	before := shown[:text_field_shown_caret(field)]

	draw_rect({
		position = {left + measure_text(font, before).x, baseline - font.ascent},
		size     = {UI_DEFAULTS.text_field.caret_width, font.ascent + font.descent},
		pivot    = {0.5, 0.5}, // position is the top-left corner
		color    = WHITE,
	})
}

/*What the field puts on screen: its text, or one star per character when masked*/
text_field_shown :: proc(field:^Text_Field, allocator := context.allocator) -> string {
	if !field.masked do return text_field_string(field)

	// Per character, not per byte, or an accented letter would show as two
	stars := strings.builder_make(allocator)
	for _ in string(field.text[:]) do strings.write_rune(&stars, UI_DEFAULTS.text_field.mask)

	return strings.to_string(stars)
}

/*Where the caret sits within text_field_shown, which masking makes a different string*/
text_field_shown_caret :: proc(field:^Text_Field) -> int {
	if !field.masked do return field.caret

	return utf8.rune_count_in_string(string(field.text[:field.caret]))
}

// -----------------------------------------------------------------------
// Scroll_View -- a panel whose contents can be taller than it is
// -----------------------------------------------------------------------

/*
	A panel whose contents can be taller than it is.

	begin_clip went in saying, in its own words, that it exists "so a list can
	scroll inside a panel rather than carrying on over whatever sits below it",
	and then nothing used it for that. What games wrote instead was paging: a
	page index, a page size, clamping, a pair of `< >` buttons and an `N / M`
	indicator, per list -- and every view of the contents having to work out its
	own per-page count, because how many things fit on a page is a different
	question from how many things there are.

	This is the same panel with none of that. The offset is a number of pixels
	rather than an index, so nothing has to know how many items fit: the items
	are laid out at their natural positions and the ones outside are cut off.

		content := f32(len(items)) * ROW

		origin := matchbox.begin_scroll(&view, panel, content)
		defer matchbox.end_scroll(&view)

		for item, i in items {
			row := matchbox.Rectangle{
				position = {origin.x, origin.y + f32(i) * ROW},
				size     = {panel.size.x, ROW},
				pivot    = {0.5, 0.5},
			}
			if matchbox.button(row, item.name) { pick(item) }
		}

	Rows outside the panel are still walked and still drawn -- they are cut by
	the scissor rather than skipped. That is the right trade for a list of a few
	hundred, which is what this is for. A list long enough for the drawing to
	cost something can work out its own first and last visible row from
	`view.offset` and the panel height, and loop over only those.
*/


SCROLLBAR_TRACK: [4]f32 = {1, 1, 1, 0.06}
SCROLLBAR_THUMB: [4]f32 = {1, 1, 1, 0.28}
SCROLLBAR_HOVER: [4]f32 = {1, 1, 1, 0.45}

/*
	Held by the caller, one per scrolling panel. The zero value is a view
	scrolled to the top.

	`offset` can be read and written: setting it to 0 jumps to the top. It is
	clamped by the next begin_scroll rather than at the moment it is set, so a
	caller does not need to know the content height to move it.
*/
Scroll_View :: struct {
	offset:  f32, // how far the content has been pulled up, in pixels

	// Filled in by begin_scroll, so end_scroll and the bar do not have to be
	// handed the same two values a second time.
	area:    Rectangle,
	content: f32,

	// Set while the thumb is being dragged, along with where inside the thumb it
	// was taken hold of -- without that the thumb jumps so its middle lands
	// under the pointer on the first frame of every drag.
	dragging: bool,
	grab:     f32,
}

/*
	Starts a scrolling panel and returns the top-left to lay content out from.

	Takes the wheel while the pointer is over the panel, clamps the offset to the
	content, and clips to `area` until end_scroll. The point handed back is the
	panel's top-left moved up by the current offset, so everything positioned
	relative to it scrolls together.

	`content_height` is how tall everything inside comes to. grid_height and
	layout_height both hand that back, which is what they are for.
*/
begin_scroll :: proc(view: ^Scroll_View, area: Rectangle, content_height: f32) -> [2]f32 {
	view.area    = area
	view.content = max(content_height, 0)

	max_offset := scroll_max(view)

	// The wheel only counts over the panel, and only when nothing above has
	// claimed the pointer -- scrolling the list under an open dropdown is the
	// same mistake as clicking through it.
	if max_offset > 0 && mouse_over_rect(area) && !mouse_captured() {
		view.offset -= get_mouse_wheel().y * UI_DEFAULTS.scroll.wheel_step
	}

	scroll_drag(view, max_offset)

	// Clamped here rather than where it is written, so a caller can put any
	// number in offset -- including one past the end after removing an item --
	// and have it come right without knowing the content height.
	view.offset = clamp(view.offset, 0, max_offset)

	begin_clip(area)

	top_left := rect_top_left(area)
	return {top_left.x, top_left.y - view.offset}
}

/*
	Ends the panel and draws the scrollbar.

	The bar is drawn after the clip is lifted rather than inside it, so it sits
	on the panel's edge instead of being cut in half by it.
*/
end_scroll :: proc(view: ^Scroll_View) {
	end_clip()
	draw_scrollbar(view)
}

// The furthest the content can be scrolled. Zero when everything already fits,
// which is also what makes the bar go away.
scroll_max :: proc(view: ^Scroll_View) -> f32 {
	return max(0, view.content - view.area.size.y)
}

// Whether there is anything to scroll. For a caller deciding whether to leave
// room for the bar.
scroll_needed :: proc(view: ^Scroll_View) -> bool {
	return scroll_max(view) > 0
}

/*
	Brings a band of content into view, given in the coordinates it was laid out
	in -- offsets from the top of the content, not from the top of the panel.

	For a list following a selection moved by the keyboard, or a newly added item
	that would otherwise appear below the fold. Does nothing when the band is
	already visible, so it is safe to call every frame.
*/
scroll_to :: proc(view: ^Scroll_View, top: f32, height: f32) {
	bottom := top + height

	switch {
	case top < view.offset:
		view.offset = top
	case bottom > view.offset + view.area.size.y:
		view.offset = bottom - view.area.size.y
	}
}

// -----------------------------------------------------------------------
// Scroll_View -- the bar
// -----------------------------------------------------------------------

/*
	The track the thumb runs in, down the panel's right edge.

	Inside the panel rather than beside it. A bar hanging off the edge has to be
	accounted for by whoever sized the panel, and forgetting is invisible until
	the panel is put next to something.
*/
scrollbar_track_rect :: proc(view: ^Scroll_View) -> Rectangle {
	top_left := rect_top_left(view.area)

	return {
		position = {
			top_left.x + view.area.size.x - UI_DEFAULTS.scroll.bar_width - UI_DEFAULTS.scroll.inset,
			top_left.y + UI_DEFAULTS.scroll.inset,
		},
		size  = {UI_DEFAULTS.scroll.bar_width, view.area.size.y - UI_DEFAULTS.scroll.inset * 2},
		pivot = {0.5, 0.5},
	}
}

/*
	The thumb, as long as the share of the content on screen and as far down as
	the share already scrolled past.

	Kept to UI_DEFAULTS.scroll.thumb_min however long the content is, because a thumb that
	shrinks in proportion forever ends up two pixels tall and cannot be taken
	hold of. That makes the thumb's travel shorter than the track on a long
	list, which is why the position is worked out against the travel rather than
	against the track.
*/
scrollbar_thumb_rect :: proc(view: ^Scroll_View) -> Rectangle {
	track      := scrollbar_track_rect(view)
	max_offset := scroll_max(view)
	if max_offset <= 0 do return track

	visible := clamp(view.area.size.y / max(view.content, 1), 0, 1)
	height  := max(track.size.y * visible, min(UI_DEFAULTS.scroll.thumb_min, track.size.y))
	travel  := track.size.y - height

	top_left := rect_top_left(track)

	return {
		position = {top_left.x, top_left.y + travel * (view.offset / max_offset)},
		size     = {track.size.x, height},
		pivot    = {0.5, 0.5},
	}
}

/*
	The thumb, dragged.

	The wheel was all this needed, and the bar had to be drawn either way to say
	where in the list you are. Once it is on screen it looks draggable, so it is.
*/
@(private)
scroll_drag :: proc(view: ^Scroll_View, max_offset: f32) {
	if max_offset <= 0 || !is_mouse_held(.LEFT) {
		view.dragging = false
		return
	}

	thumb := scrollbar_thumb_rect(view)

	// Only the press that lands on the thumb starts a drag. Held is what keeps
	// it going, so the pointer may wander off the bar mid-drag and still be
	// dragging it, which is what every scrollbar does.
	if !view.dragging {
		if !is_mouse_pressed(.LEFT) || mouse_captured() do return
		if !mouse_over_rect(thumb) do return

		view.dragging = true
		view.grab     = get_mouse_position().y - rect_top_left(thumb).y
	}

	track  := scrollbar_track_rect(view)
	travel := track.size.y - thumb.size.y
	if travel <= 0 do return

	// Where the top of the thumb has been dragged to, as a share of how far it
	// can travel, put back onto the offset.
	top := get_mouse_position().y - view.grab - rect_top_left(track).y
	view.offset = clamp(top / travel, 0, 1) * max_offset
}

/*
	Draws the track and thumb, and nothing at all when everything fits.

	Nothing rather than a full-length thumb: a bar that is always there but only
	sometimes means something is a worse signal than one that appears when there
	is more to see.
*/
draw_scrollbar :: proc(view: ^Scroll_View) {
	if scroll_max(view) <= 0 do return

	draw_rect_in(scrollbar_track_rect(view), SCROLLBAR_TRACK)

	thumb := scrollbar_thumb_rect(view)
	color := SCROLLBAR_THUMB
	if view.dragging || (mouse_over_rect(thumb) && !mouse_captured()) do color = SCROLLBAR_HOVER

	draw_rect_in(thumb, color)
}

// draw_rect with the colour given separately, for the places that build a
// Rectangle for its geometry and decide the colour afterwards.
@(private)
draw_rect_in :: proc(rectangle: Rectangle, color: [4]f32) {
	rect := rectangle
	rect.color = color
	draw_rect(rect)
}

// -----------------------------------------------------------------------
// Dropdown -- pick one of a list, at a box or at a point
// -----------------------------------------------------------------------

/*
	A list of options that opens over the screen, hanging either from a box or
	from a point.

	Those two used to be different widgets. `dropdown` opened its list under a
	box; a context menu opens the same list at the pointer, and because there
	was no way to say that, a game needing one wrote a second nearly identical
	widget of its own -- which then had to learn about capture, dismissal and
	drawing late all over again. The only difference between them is where the
	list hangs from, so that is what this takes: an anchor.

	Drawing is immediate and an open list has to appear over things drawn after
	it, so this comes in two halves:

		matchbox.dropdown(&state, box, options)    // early: the closed box, and all the input
		... the rest of the screen ...
		matchbox.dropdown_overlay(&state, options) // late: the open list, over the top

	All the input is in the first call, including the hit test on the open list,
	so the caller learns about a change in time to act on it the same frame
	rather than the next. The second call only draws.

	While the list is open the pointer is captured, so whatever the list covers
	can ask mouse_captured() and leave the click alone. That only works if this
	is called before the things it covers.
*/


DROPDOWN_LIST_BG:  [4]f32 = {0.10, 0.10, 0.13, 1}
DROPDOWN_BORDER:   [4]f32 = {0.35, 0.38, 0.46, 1}
DROPDOWN_MARK:     [4]f32 = {0.55, 0.80, 0.55, 1} // the option currently chosen

// A variable rather than a constant, because the colours it names are
// variables themselves and a constant cannot be built out of those.
DROPDOWN_STYLE := Dropdown_Style{
	hover            = {0.35, 0.35, 0.42, 1},
	text_color       = {1, 1, 1, 1},
	list_bg          = DROPDOWN_LIST_BG,
	border           = DROPDOWN_BORDER,
	mark             = DROPDOWN_MARK,
	padding          = UI_DEFAULTS.dropdown.padding,
	border_thickness = 1,
}

Dropdown_Style :: struct {
	hover:            [4]f32, // fill under the pointer, on the box and on a row
	text_color:       [4]f32,
	list_bg:          [4]f32,
	border:           [4]f32,
	mark:             [4]f32, // the chosen option, so an open list says where it is
	padding:          f32,
	border_thickness: f32,
}

/*
	What the list hangs from.

	BOX is a dropdown: there is a closed box on screen, the list opens under it,
	and the option currently chosen is marked in the list because the box is
	showing it.

	POINT is a context menu: nothing is on screen until it is opened, the list
	hangs from wherever it was opened at, and nothing is marked -- a menu of
	actions has no current one.
*/
Dropdown_Anchor :: enum {
	BOX,
	POINT,
}

Dropdown :: struct {
	open:     bool,
	selected: int,

	anchor: Dropdown_Anchor,

	// What the list hangs from: the closed box for BOX, and a rectangle of no
	// height sitting at the point for POINT. One field rather than two because
	// the list is placed the same way from either -- under the bottom edge,
	// which for a zero-height rectangle is the point itself.
	rectangle: Rectangle,

	// One row of the open list. Taken from the box for BOX, where the list is
	// as wide as the thing it came out of, and given by the caller for POINT.
	row: [2]f32,

	// The frame open_context_menu ran on. The click that opens a menu is still
	// a press for the rest of that frame, and the point it opens at is the top
	// corner of the first row -- so without this the menu opens and chooses its
	// own first entry in the same breath.
	opened_on: u64,
}

/*
	The closed box, and every scrap of input for the frame.

	True on the frame the selection changes -- not merely on a click, so a
	caller can rebuild something expensive on the strength of it.
*/
dropdown :: proc(
	state:     ^Dropdown,
	rectangle: Rectangle,
	options:   []string,
	style:     Dropdown_Style = DROPDOWN_STYLE,
	font:      ^Font = nil,
) -> (changed: bool) {
	font := font if font != nil else &mbi.font

	state.anchor    = .BOX
	state.rectangle = rectangle
	state.row       = rectangle.size

	if len(options) == 0 {
		state.open = false
		return false
	}
	state.selected = clamp(state.selected, 0, len(options) - 1)

	over := mouse_over_rect(rectangle)

	if state.open {
		changed = dropdown_take_input(state, len(options), over)
	} else if over {
		capture_mouse()
		if is_mouse_pressed(.LEFT) do state.open = true
	}

	box := rectangle
	if over do box.color = style.hover
	draw_rect(box)
	draw_rect_border(box, style.border, style.border_thickness)

	top_left := rect_top_left(box)
	baseline := top_left.y + (box.size.y - measure_text(font, options[state.selected]).y) * 0.5 + font.ascent

	draw_text(font, options[state.selected], top_left.x + style.padding, baseline, style.text_color)

	// Which way it will open. This was the ASCII characters `v` and `^` until
	// there was a triangle to draw, which is a small thing that was visible on
	// every dropdown on screen: the caret was whatever shape the game's font
	// happened to give those two letters, at whatever size the text was.
	dropdown_caret(box, style, state.open)

	return changed
}

/*
	Opens the list at a point, with no box: a context menu.

	The caller decides what opens it, which is the whole difference between this
	and a dropdown -- usually the right button over something:

		if matchbox.is_mouse_pressed(.RIGHT) && matchbox.mouse_over_rect(deck) {
			matchbox.open_context_menu(&menu, matchbox.get_mouse_position(), {160, 32})
		}

	`row_size` is one row: the width of the whole list, and the height of each
	entry in it. There is no box to take that from the way a dropdown does.
*/
open_context_menu :: proc(state: ^Dropdown, point: [2]f32, row_size: [2]f32) {
	state.anchor = .POINT

	// No height, so the list hangs from the point itself -- dropdown_list_rect
	// puts it under the bottom edge either way and does not need to know which
	// of the two it is looking at.
	state.rectangle = {position = point, size = {row_size.x, 0}, pivot = {0.5, 0.5}}
	state.row       = row_size
	state.selected  = -1
	state.open      = true
	state.opened_on = mbi.frame
}

/*
	The input half of a context menu. Draws nothing; dropdown_overlay does that.

	`picked` is true on the frame an entry is chosen, and `chosen` indexes
	`options`. Unlike a dropdown this does not report a *change*: every pick off
	a menu of actions is worth acting on, including picking the same one twice.

		if choice, picked := matchbox.context_menu(&menu, ACTIONS); picked {
			do_action(choice)
		}
*/
context_menu :: proc(
	state:   ^Dropdown,
	options: []string,
	style:   Dropdown_Style = DROPDOWN_STYLE,
) -> (chosen: int, picked: bool) {
	if !state.open do return -1, false

	if len(options) == 0 {
		state.open = false
		return -1, false
	}

	// The frame it opened on is the frame the opening click happened on, and
	// that click is not also a choice. The pointer is still taken, so whatever
	// the menu landed on top of does not act on it either.
	if state.opened_on == mbi.frame {
		capture_mouse()
		return -1, false
	}

	dropdown_take_input(state, len(options), false)

	// selected is left at -1 by open_context_menu and only moves when a row is
	// hit, so this is exactly "something was picked this frame".
	if !state.open && state.selected >= 0 {
		return state.selected, true
	}

	return -1, false
}

/*
	The input an open list takes, whichever way it was opened.

	The list is on top, so it takes the pointer whether or not the click lands
	on a row -- otherwise closing the list by clicking away also presses
	whatever happened to be under that spot.

	`over_anchor` is whether the pointer is over the thing the list came out of,
	which for a dropdown is its own box and needs capturing too. A context menu
	has no box and passes false.
*/
@(private)
dropdown_take_input :: proc(state: ^Dropdown, count: int, over_anchor: bool) -> (changed: bool) {
	if over_anchor || mouse_over_rect(dropdown_list_rect(state, count)) do capture_mouse()

	// Either button puts a menu away. Right-clicking somewhere else with a menu
	// open means "open one there instead", and leaving the first one up would
	// give two.
	if !is_mouse_pressed(.LEFT) && !is_mouse_pressed(.RIGHT) do return false

	if hit := dropdown_row_at(state, count, get_mouse_position()); hit >= 0 {
		changed        = hit != state.selected
		state.selected = hit
		state.open     = false
		return changed
	}

	// Anywhere else, the box included, just puts it away.
	state.open = false
	return false
}

/*
	The open list, drawn over whatever came after it.

	Does nothing when closed, so it can be called unconditionally from the end of
	a screen. No input: dropdown() and context_menu() already took it.
*/
dropdown_overlay :: proc(
	state:   ^Dropdown,
	options: []string,
	style:   Dropdown_Style = DROPDOWN_STYLE,
	font:    ^Font = nil,
) {
	if !state.open || len(options) == 0 do return

	font := font if font != nil else &mbi.font

	list := dropdown_list_rect(state, len(options))
	list.color = style.list_bg
	draw_rect(list)
	draw_rect_border(list, style.border, style.border_thickness)

	mouse := get_mouse_position()

	for option, i in options {
		row := dropdown_row_rect(state, i, len(options))

		if point_in_rect(mouse, row) {
			row.color = style.hover
			draw_rect(row)
		}

		// Only a dropdown marks a row. A context menu is a list of things to do
		// and has no current one, so marking the last thing done would be
		// saying something untrue.
		color := style.text_color
		if state.anchor == .BOX && i == state.selected do color = style.mark

		top_left := rect_top_left(row)
		baseline := top_left.y + (row.size.y - measure_text(font, option).y) * 0.5 + font.ascent

		draw_text(font, option, top_left.x + style.padding, baseline, color)
	}
}

// Whether a dropdown is showing its list, for a caller deciding what else to
// draw.
dropdown_is_open :: proc(state: ^Dropdown) -> bool {
	return state.open
}

// Shuts the list without changing the choice.
dropdown_close :: proc(state: ^Dropdown) {
	state.open = false
}

/*
	The whole open list.

	Hanging off the bottom of whatever it is anchored to, and turned back when
	that would put it off the screen -- up when there is not room below and more
	room above, and left when it would run off the right edge.

	The flip is not a nicety here. It was left undone while the only anchor was
	a box, on the grounds that nothing had been put near the bottom of a window
	yet. A context menu opens wherever the pointer is, and the bottom of the
	window is an ordinary place to right-click.
*/
dropdown_list_rect :: proc(state: ^Dropdown, count: int) -> Rectangle {
	anchor := rect_top_left(state.rectangle)

	width  := state.row.x
	height := f32(count) * state.row.y + f32(max(0, count - 1)) * UI_DEFAULTS.dropdown.row_gap

	x := anchor.x
	y := anchor.y + state.rectangle.size.y // under the box, or at the point

	// Measured against the logical size, which is what everything here is drawn
	// in -- window pixels would be wrong under a letterbox.
	screen_w := f32(mbi.width)
	screen_h := f32(mbi.height)

	// Up rather than down only when that is actually better. A list too tall for
	// either side stays where it was, because flipping it would move the problem
	// without fixing it and put the first row further from the pointer.
	below := screen_h - y
	above := anchor.y
	if height > below && above > below do y = anchor.y - height

	if x + width > screen_w do x = screen_w - width
	if x < 0 do x = 0

	return {position = {x, y}, size = {width, height}, pivot = {0.5, 0.5}}
}

/*
	One row of the open list.

	Derived from the list rather than from the anchor, so the two cannot
	disagree about where the list ended up once it has been flipped -- which is
	the bug this shape of code invites: a hit test that still believes the list
	opened downwards.
*/
dropdown_row_rect :: proc(state: ^Dropdown, index: int, count: int) -> Rectangle {
	list     := dropdown_list_rect(state, count)
	top_left := rect_top_left(list)

	return {
		position = {top_left.x, top_left.y + f32(index) * (state.row.y + UI_DEFAULTS.dropdown.row_gap)},
		size     = {list.size.x, state.row.y},
		pivot    = {0.5, 0.5},
	}
}

// Which row a point is on, or -1 for none of them.
dropdown_row_at :: proc(state: ^Dropdown, count: int, point: [2]f32) -> int {
	for i in 0 ..< count {
		if point_in_rect(point, dropdown_row_rect(state, i, count)) do return i
	}
	return -1
}

/*
	The little triangle at the right-hand end of a closed box, pointing the way
	the list will open.

	Sized off the box rather than off the font, which is the point of drawing it
	rather than writing it: it is the same shape at every text size, and it is
	the same shape whatever font the game loaded.
*/
@(private)
dropdown_caret :: proc(box: Rectangle, style: Dropdown_Style, open: bool) {
	top_left := rect_top_left(box)

	half   := min(box.size.y * 0.18, box.size.x * 0.25)
	center := [2]f32{top_left.x + box.size.x - style.padding - half, top_left.y + box.size.y * 0.5}

	// Pointing down when closed -- "there is more under here" -- and up when
	// open, which is the direction it will fold back into.
	tip  := center.y + half * 0.8
	base := center.y - half * 0.6
	if open do tip, base = base, tip

	draw_triangle(
		{center.x - half, base},
		{center.x + half, base},
		{center.x, tip},
		style.text_color,
	)
}

// -----------------------------------------------------------------------
// Tooltip
// -----------------------------------------------------------------------

TOOLTIP_OFFSET:  [2]f32 = {16, 18} // from the pointer to the plate's near corner
TOOLTIP_MARGIN:  f32    = 6        // closest the plate comes to a window edge
TOOLTIP_MAX:     f32    = 260      // width it wraps at

/*
	Text on a plate beside the pointer, moved to the other side when it would
	run off the screen.

	The flipping is the part worth having. A plate that always hangs down and to
	the right is fine until the pointer is near an edge, and then the thing you
	asked to read is the thing that is off screen.

	Wraps at `max_width`, so a sentence of explanation is as ordinary a thing to
	pass as two words. Returns the plate, for a caller that wants to know what
	got covered.

		if matchbox.hover_dwell(&hint, card_rect) {
			matchbox.draw_tooltip(rules_text)
		}

	Call it late. It is drawn where it is asked and nothing here reorders
	anything, so a tooltip drawn in the middle of a screen is covered by the
	rest of it.
*/
draw_tooltip :: proc(
	text:      string,
	font:      ^Font = nil,
	max_width: f32 = TOOLTIP_MAX,
	color:     [4]f32 = UI_DEFAULTS.text_plate.fg,
	plate:     [4]f32 = UI_DEFAULTS.text_plate.bg,
	padding:   [2]f32 = UI_DEFAULTS.text_plate.padding,
) -> Rectangle {
	font := font if font != nil else &mbi.font
	if len(text) == 0 do return {}

	measured := measure_text_wrapped(font, text, max_width)
	size     := measured + padding * 2

	at := tooltip_corner(get_mouse_position(), size)

	draw_rect({position = at, size = size, color = plate, pivot = {0.5, 0.5}})
	draw_text_wrapped(font, text, at + padding, max_width, color)

	return {position = at, size = size, pivot = {0.5, 0.5}}
}

/*
	Where a plate of `size` goes for a pointer at `mouse`.

	Below and to the right by preference, because that is where the pointer is
	not. Flipped to the other side of the pointer when there is no room, and only
	then pushed back inside the window -- flipping first keeps the plate clear of
	the cursor, and sliding is what is left when neither side fits.
*/
@(private)
tooltip_corner :: proc(mouse: [2]f32, size: [2]f32) -> [2]f32 {
	screen := [2]f32{f32(mbi.width), f32(mbi.height)}
	at     := mouse + TOOLTIP_OFFSET

	if at.x + size.x > screen.x - TOOLTIP_MARGIN do at.x = mouse.x - TOOLTIP_OFFSET.x - size.x
	if at.y + size.y > screen.y - TOOLTIP_MARGIN do at.y = mouse.y - TOOLTIP_OFFSET.y - size.y

	at.x = clamp(at.x, TOOLTIP_MARGIN, max(TOOLTIP_MARGIN, screen.x - TOOLTIP_MARGIN - size.x))
	at.y = clamp(at.y, TOOLTIP_MARGIN, max(TOOLTIP_MARGIN, screen.y - TOOLTIP_MARGIN - size.y))

	return at
}

// -----------------------------------------------------------------------
// Status line
// -----------------------------------------------------------------------

/*
	How much a message matters, which is the whole of what a status line adds
	over drawing the string yourself.

	Four rather than two because "it worked" and "here is what is happening" are
	not the same message and should not be the same colour, and neither is a
	warning the same as a refusal.
*/
Status_Level :: enum {
	INFO, // what is happening
	GOOD, // it worked
	WARN, // it worked, but
	BAD,  // it did not work
}

STATUS_COLOR := [Status_Level][4]f32{
	.INFO = {0.80, 0.82, 0.88, 1},
	.GOOD = {0.55, 0.80, 0.55, 1},
	.WARN = {0.90, 0.75, 0.40, 1},
	.BAD  = {0.90, 0.45, 0.45, 1},
}


// Longest message kept. A status line is one line on a screen somebody is
// reading at a glance; anything longer wants a panel of its own.
STATUS_MAX_BYTES :: 160

/*
	Held by the caller, one per screen. The zero value is a line with nothing on
	it.

	**The text is copied in.** That is what the fixed buffer is for: the message
	is nearly always a temp-allocated `fmt.tprintf`, and a status line that kept
	the pointer would be showing freed memory by the next frame -- which is the
	sort of bug that looks like a rendering fault for an afternoon.
*/
Status_Line :: struct {
	buffer: [STATUS_MAX_BYTES]u8,
	length: int,
	level:  Status_Level,

	// When it was set, and how long it lasts. `seconds` of 0 means it stays
	// until something replaces it, which is what a line reporting the state of
	// things wants; a number is what an "it worked" wants.
	set_at:  u64,
	seconds: f32,
}

/*
	Puts a message on the line, replacing whatever was there.

		matchbox.set_status(&note, fmt.tprintf("saved %s", name), .GOOD, 3)
		matchbox.set_status(&note, "deck needs 40 cards", .BAD)

	Truncated at STATUS_MAX_BYTES on a character boundary, so a long message is
	short rather than broken utf-8.
*/
set_status :: proc(status: ^Status_Line, text: string, level: Status_Level = .INFO, seconds: f32 = 0) {
	cut := min(len(text), STATUS_MAX_BYTES)
	for cut > 0 && cut < len(text) && text[cut] & 0xc0 == 0x80 do cut -= 1

	copy(status.buffer[:], text[:cut])

	status.length  = cut
	status.level   = level
	status.set_at  = mbi.now_ts
	status.seconds = seconds
}

// Takes the message off the line.
clear_status :: proc(status: ^Status_Line) {
	status.length = 0
	status.set_at = 0
}

// What is on the line. Points into the status line and changes when it is set
// again.
status_text :: proc(status: ^Status_Line) -> string {
	return string(status.buffer[:status.length])
}

/*
	How visible the line should be, 0 to 1.

	1 for a message with no time limit, and for a timed one until its last half
	second, which it spends fading. A message that vanishes between one frame and
	the next reads as a glitch rather than as an answer expiring.
*/
status_alpha :: proc(status: ^Status_Line) -> f32 {
	if status.length == 0 || status.set_at == 0 do return 0
	if status.seconds <= 0 do return 1

	left := status.seconds - seconds_since(status.set_at)

	if left <= 0 do return 0
	if left >= UI_DEFAULTS.status_fade do return 1

	return left / UI_DEFAULTS.status_fade
}

/*
	Draws the line at a top-left, in its level's colour, and returns the room it
	took.

	Nothing at all when the line is empty or has faded out, so this can be called
	unconditionally from the bottom of a screen.
*/
draw_status :: proc(status: ^Status_Line, top_left: [2]f32, font: ^Font = nil) -> [2]f32 {
	alpha := status_alpha(status)
	if alpha <= 0 do return {}

	font := font if font != nil else &mbi.font

	color := STATUS_COLOR[status.level]
	color.a *= alpha

	text := status_text(status)
	draw_text(font, text, top_left.x, top_left.y + font.ascent, color)

	return measure_text(font, text)
}

// -----------------------------------------------------------------------
// Modal
// -----------------------------------------------------------------------

MODAL_DIM: [4]f32 = {0, 0, 0, 0.6}

/*
	Held by the caller, one per thing that can be put up over a screen.

	Like Dropdown, this is in two halves, and for the same reason: drawing is
	immediate, so the dim has to be drawn last to be over everything, but the
	pointer has to be taken first or the screen underneath answers the clicks
	that were meant for the modal.

		matchbox.modal_begin(&preview)      // early: takes the pointer
		... the whole screen ...
		if box, open := matchbox.modal_overlay(&preview, {480, 640}); open {
			... draw the content in `box` ...
		}

	Capture only reaches widgets that run *after* it, which is why the first call
	goes at the top of the frame. The second gives the pointer back before
	handing over the box, so buttons drawn inside the modal answer normally --
	they ask mouse_captured() like every other button and would otherwise be as
	dead as the screen behind them.
*/
Modal :: struct {
	open: bool,

	// The frame open_modal ran on. The click that puts a modal up is still a
	// press for the rest of that frame, and the modal is drawn during that same
	// frame -- so without this it opens and is dismissed in one breath, which
	// looks exactly like it never opened at all.
	opened_on: u64,
}

// Puts the modal up. Whatever `modal_overlay` is next given is what it shows.
open_modal :: proc(modal: ^Modal) {
	modal.open      = true
	modal.opened_on = mbi.frame
}

// Closes the modal. Safe on one already closed.
close_modal :: proc(modal: ^Modal) {
	modal.open = false
}

// Whether the modal is up. What the rest of a screen checks before taking
// input of its own.
modal_is_open :: proc(modal: ^Modal) -> bool {
	return modal.open
}

/*
	Takes the pointer for the frame while the modal is up. Call early, before
	anything the modal will cover.

	Returns whether it is open, so a screen that wants to skip its own update
	work while a modal is up can do that off the same call.
*/
modal_begin :: proc(modal: ^Modal) -> bool {
	if modal.open do capture_mouse()
	return modal.open
}

/*
	Draws the dim and hands back a centred box to put content in. Call late.

	`open` is false when there is nothing up, in which case the box is not worth
	looking at -- the usual shape is `if box, open := ...; open { }`.

	The pointer is given back here, so anything drawn into the box behaves
	normally.
*/
modal_overlay :: proc(modal: ^Modal, size: [2]f32, dim: [4]f32 = MODAL_DIM) -> (content: Rectangle, open: bool) {
	if !modal.open do return {}, false

	screen := [2]f32{f32(mbi.width), f32(mbi.height)}

	draw_rect({position = {0, 0}, size = screen, color = dim, pivot = {0.5, 0.5}})

	// The pointer is given back so that buttons drawn into the box behave
	// normally -- except on the frame it opened, where the press that opened it
	// is still live and belongs to whatever was clicked, not to the modal. Held
	// rather than released, so that one press reaches nothing: not a button
	// inside the box that happens to sit where the opening button was, and not
	// modal_dismissed, which would otherwise shut it immediately.
	if modal.opened_on == mbi.frame {
		capture_mouse()
	} else {
		release_mouse()
	}

	return Rectangle{
		position = (screen - size) * 0.5,
		size     = size,
		pivot    = {0.5, 0.5}, // position is the top-left corner
	}, true
}

/*
	Whether the click landed on the dim rather than on `content`, which is the
	usual way a modal is dismissed.

	Call after modal_overlay and after whatever went inside it, so a button in
	the corner of the content gets the click first.

		if matchbox.modal_dismissed(box) do matchbox.close_modal(&preview)

	The `mouse_captured` test is what keeps the opening click from counting:
	modal_overlay holds the pointer for that one frame rather than giving it
	back. See there.
*/
modal_dismissed :: proc(content: Rectangle) -> bool {
	return is_mouse_pressed(.LEFT) && !mouse_over_rect(content) && !mouse_captured()
}

// -----------------------------------------------------------------------
// Slider -- pick a number by dragging
// -----------------------------------------------------------------------


SLIDER_STYLE := Slider_Style{
	track        = {1, 1, 1, 0.12},
	fill         = {0.45, 0.60, 0.85, 1},
	handle       = {0.85, 0.87, 0.92, 1},
	handle_hover = {1, 1, 1, 1},
	handle_width = UI_DEFAULTS.slider_handle_width,
}

Slider_Style :: struct {
	track:        [4]f32, // the part not yet filled
	fill:         [4]f32, // from the left edge up to the handle
	handle:       [4]f32,
	handle_hover: [4]f32,
	handle_width: f32,    // UI_DEFAULTS.slider_handle_width when left at zero
}

/*
	Held by the caller, one per slider. The zero value is a slider nobody is
	touching.

	The value itself is not in here -- it is passed by pointer, because it belongs
	to whatever is being adjusted and a slider that owned it would mean copying it
	back and forth every frame.
*/
Slider :: struct {
	dragging: bool,

	// Where inside the handle it was taken hold of. Without it the handle jumps
	// so its middle lands under the pointer on the first frame of every drag,
	// which is the same thing the scrollbar's thumb needed.
	grab: f32,
}

/*
	A number picked by dragging, between `low` and `high`. True on any frame the
	value changes.

		if matchbox.slider(&opacity_bar, rect, &opacity, 0, 1) {
			restroke()
		}

	`draw_progress` already drew this shape and would not take input -- it is
	handed a number and renders it. This is the other half, and the reason it is
	worth having is that a colour or a brush size is something you *sweep*: the
	point is watching the result change as it moves, which a box you type a number
	into cannot do.

	`step` snaps the result, so a brush size can be whole numbers while the drag
	stays smooth. Zero leaves it continuous.

	Horizontal only. A vertical one is a transposition of everything below and is
	left out until something wants it, rather than written untested.

	Clicking the track away from the handle jumps to that point and starts
	dragging from there, which is what every slider does and what makes a long
	track usable without a drag at all.
*/
slider :: proc(
	state:     ^Slider,
	rectangle: Rectangle,
	value:     ^f32,
	low:       f32,
	high:      f32,
	step:      f32 = 0,
	style:     Slider_Style = SLIDER_STYLE,
) -> (changed: bool) {
	before := value^

	// Clamped on the way in as well as on the way out: the caller may have set
	// it from a config file, a text field, or an undo, and a handle drawn off the
	// end of its own track is a confusing way to find that out.
	value^ = clamp(value^, low, high)

	span   := high - low
	width  := style.handle_width if style.handle_width > 0 else UI_DEFAULTS.slider_handle_width
	travel := rectangle.size.x - width

	top_left := rect_top_left(rectangle)

	// Nothing to drag along: a zero-width slider, or one whose ends are the same
	// number. Drawn, so it does not silently vanish, but inert.
	if travel <= 0 || span == 0 {
		state.dragging = false
		draw_slider(rectangle, value^, low, high, style, false)
		return false
	}

	mouse  := get_mouse_position()
	handle := slider_handle_rect(rectangle, value^, low, high, style)

	switch {
	case !is_mouse_held(.LEFT):
		state.dragging = false

	case state.dragging:
		// Held is what keeps a drag alive, so the pointer may wander off the
		// track -- above it, below it, out of the window -- and still be dragging.

	case is_mouse_pressed(.LEFT) && !mouse_captured() && mouse_over_rect(handle):
		state.dragging = true
		state.grab     = mouse.x - rect_top_left(handle).x

	case is_mouse_pressed(.LEFT) && !mouse_captured() && mouse_over_rect(rectangle):
		// Anywhere else on the track: put the handle under the pointer and carry
		// on as though the drag started there.
		state.dragging = true
		state.grab     = width * 0.5
	}

	if state.dragging {
		t := clamp((mouse.x - state.grab - top_left.x) / travel, 0, 1)
		value^ = slider_snap(low + t * span, low, high, step)
	}

	hot := state.dragging || (mouse_over_rect(handle) && !mouse_captured())
	draw_slider(rectangle, value^, low, high, style, hot)

	return value^ != before
}

/*
	The same, over whole numbers.

	Separate rather than "pass step = 1", because a caller with an `int` would
	otherwise convert to f32 and back every frame and pick up the rounding on the
	way through -- and because the range of an int slider is the two ends of a
	count, which reads better as ints at the call site.
*/
slider_int :: proc(
	state:     ^Slider,
	rectangle: Rectangle,
	value:     ^int,
	low:       int,
	high:      int,
	style:     Slider_Style = SLIDER_STYLE,
) -> (changed: bool) {
	as_float := f32(value^)

	slider(state, rectangle, &as_float, f32(low), f32(high), 1, style)

	// Rounded rather than truncated: slider_snap has already put it on a whole
	// number, and int() on 3.9999996 is 3.
	snapped := int(math.round(as_float))
	snapped  = clamp(snapped, low, high)

	changed = snapped != value^
	value^  = snapped

	return changed
}

// Where the handle sits for a given value. Public because a caller wanting a
// tick mark, a tooltip over the handle, or a second thing anchored to it needs
// the same answer this uses.
slider_handle_rect :: proc(rectangle: Rectangle, value, low, high: f32, style: Slider_Style = SLIDER_STYLE) -> Rectangle {
	width  := style.handle_width if style.handle_width > 0 else UI_DEFAULTS.slider_handle_width
	travel := max(0, rectangle.size.x - width)
	span   := high - low

	t: f32
	if span != 0 do t = clamp((value - low) / span, 0, 1)

	top_left := rect_top_left(rectangle)

	return Rectangle{
		position = {top_left.x + travel * t, top_left.y},
		size     = {width, rectangle.size.y},
		pivot    = {0.5, 0.5}, // position is the top-left corner
	}
}

/*
	Puts a value on the nearest step.

	Measured from `low` rather than from zero, so a slider running 3 to 11 in
	twos gives 3, 5, 7 and not 4, 6, 8 -- the steps belong to the range, not to
	the number line. The far end is kept reachable even when the span is not a
	whole number of steps, since a slider dragged all the way right that stops
	short of its own maximum is a bug every time.
*/
@(private)
slider_snap :: proc(value, low, high: f32, step: f32) -> f32 {
	if step <= 0 do return clamp(value, low, high)

	snapped := low + math.round((value - low) / step) * step
	return clamp(snapped, low, high)
}

@(private)
draw_slider :: proc(rectangle: Rectangle, value, low, high: f32, style: Slider_Style, hot: bool) {
	draw_rect_in(rectangle, style.track)

	handle   := slider_handle_rect(rectangle, value, low, high, style)
	top_left := rect_top_left(rectangle)

	// Up to the middle of the handle, so the fill and the handle read as one
	// object rather than as a bar with a block sitting next to it.
	filled := rect_center(handle).x - top_left.x
	if filled > 0 {
		draw_rect_in({
			position = top_left,
			size     = {filled, rectangle.size.y},
			pivot    = {0.5, 0.5},
		}, style.fill)
	}

	draw_rect_in(handle, style.handle_hover if hot else style.handle)
}

// -----------------------------------------------------------------------
// Progress bar
// -----------------------------------------------------------------------

PROGRESS_STYLE := Progress_Style{
	track            = {1, 1, 1, 0.12},
	fill             = {0.55, 0.80, 0.55, 1},
	border           = {0, 0, 0, 0},
	border_thickness = 0,
}

Progress_Style :: struct {
	track:            [4]f32, // the empty part
	fill:             [4]f32, // the full part
	border:           [4]f32, // left transparent by default; a bar rarely needs one
	border_thickness: f32,
}

/*
	A bar from 0 to 1, filling left to right.

	`hover_progress` already returned the number and matchbox's own examples/ui
	drew the bar for it out of a hand-made rectangle, which is a fair sign this
	belonged here.

	`progress` is clamped, so a caller may hand over a ratio without checking
	that its denominator was not zero.
*/
draw_progress :: proc(rectangle: Rectangle, progress: f32, style: Progress_Style = PROGRESS_STYLE) {
	p := clamp(progress, 0, 1)

	track := rectangle
	track.color = style.track
	draw_rect(track)

	if p > 0 {
		top_left := rect_top_left(rectangle)

		// Grown from the left edge rather than scaled about the middle, which is
		// what `pivot` here is for -- a rect scaled about its centre would empty
		// from both ends at once.
		draw_rect({
			position = top_left,
			size     = {rectangle.size.x * p, rectangle.size.y},
			color    = style.fill,
			pivot    = {0.5, 0.5},
			rotation = rectangle.rotation,
		})
	}

	if style.border_thickness > 0 do draw_rect_border(rectangle, style.border, style.border_thickness)
}

/*
	The same bar with a label centred on it.

	Split from draw_progress rather than being an empty string away from it,
	because a bar six pixels tall is the common case and has nowhere to put
	text.
*/
draw_progress_labelled :: proc(
	rectangle: Rectangle,
	progress:  f32,
	text:      string,
	style:     Progress_Style = PROGRESS_STYLE,
	color:     [4]f32 = WHITE,
	font:      ^Font = nil,
) {
	draw_progress(rectangle, progress, style)
	if len(text) == 0 do return

	font := font if font != nil else &mbi.font

	top_left := rect_top_left(rectangle)
	measured := measure_text(font, text)

	draw_text(
		font, text,
		top_left.x + (rectangle.size.x - measured.x) * 0.5,
		top_left.y + (rectangle.size.y - measured.y) * 0.5 + font.ascent,
		color,
	)
}

// Percentage text for a bar, as "42%". Rounded rather than truncated, so a bar
// that has visibly reached the end does not read as 99%.
progress_percent :: proc(progress: f32, allocator := context.allocator) -> string {
	p := int(clamp(progress, 0, 1) * 100 + 0.5)

	sb := strings.builder_make(allocator)
	strings.write_int(&sb, p)
	strings.write_rune(&sb, '%')

	return strings.to_string(sb)
}
