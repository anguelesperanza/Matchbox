#+build windows

package ui

/*
	Widgets
	=======
	  button / Button_Style   draws, hovers, answers a click, and can be disabled
	  toggle                  a box ticked or not, with its label
	  Text_Field              somewhere to type, with its label above it        (text_field.odin)
	  Number_Field            a number dragged sideways, or clicked and typed   (number_field.odin)
	  Scroll_View             a panel whose contents can be taller than it is   (scroll_view.odin)
	  Dropdown                pick one of a list, at a box or at a point        (dropdown.odin)
	  Modal                   a full-screen dim with something centred on top   (modal.odin)
	  Status_Line             a short message with a severity colour            (status_line.odin)

	Three of these come in two halves (Scroll_View, Dropdown and Modal) for one reason. Drawing is immediate, so what opens
	out over the screen has to be drawn last; but every widget tests the pointer for itself, so the same widget has to take
	the pointer first.

	A widget takes a `Rectangle` for where it is, and its colours come from its style struct, the way a game hands
	create_animator its blend: a defaulted parameter, so a tool changes one field and leaves the rest.
*/

import mb ".."

Text_Align :: enum {
	CENTER,
	LEFT,
}

Defaults :: struct {
	disabled_dim: f32, // what a disabled widget's colours are multiplied by
	status_fade:  f32, // seconds a timed status message spends fading out

	text_field_padding: f32, // box edge to text
	text_field_caret:   f32, // caret width
	text_field_ring:    f32, // focus ring thickness
	text_field_gap:     f32, // between the label's line and the box
	text_field_blink:   f32, // seconds for a full off-on cycle of the caret

	scroll_bar_width:  f32,
	scroll_thumb_min:  f32, // shortest the thumb gets, so it can still be taken hold of
	scroll_inset:      f32, // bar to panel edge
	scroll_wheel_step: f32, // units per notch

	dropdown_padding: f32, // box edge to label
	dropdown_row_gap: f32, // hairline between options
}

DEFAULTS :: Defaults {
	disabled_dim = 0.45,
	status_fade  = 0.5,

	text_field_padding = 8,
	text_field_caret   = 2,
	text_field_ring    = 2,
	text_field_gap     = 4,
	text_field_blink   = 1.06,

	scroll_bar_width  = 8,
	scroll_thumb_min  = 24,
	scroll_inset      = 2,
	scroll_wheel_step = 48,

	dropdown_padding = 8,
	dropdown_row_gap = 1,
}

@(private)
calculate_dimmed :: proc(color: [4]f32, amount: f32) -> [4]f32 {
	dim := amount if amount > 0 else DEFAULTS.disabled_dim
	return {color.r * dim, color.g * dim, color.b * dim, color.a}
}

// ---- button ---------------------------------------------------------------------

Button_Style :: struct {
	fill:       [4]f32,
	hover:      [4]f32, // replaces the fill while the pointer is over it
	text_color: [4]f32,
	align:      Text_Align,
	padding:    f32, // from the left edge, when aligned LEFT

	// There and not pressable: dimmed, never highlighted, never true. In the style because whether a button can be
	// pressed changes per frame
	disabled:     bool,
	disabled_dim: f32,
}

BUTTON_STYLE :: Button_Style {
	fill         = {0.24, 0.25, 0.30, 1},
	hover        = {0.35, 0.35, 0.42, 1},
	text_color   = {1, 1, 1, 1},
	align        = .CENTER,
	padding      = 10,
	disabled_dim = DEFAULTS.disabled_dim,
}

/*
	A button that draws itself and answers in one call: true on the frame it is clicked. Not hovered, and not pressed, when
	something above has claimed the pointer: a button under an open dropdown neither lights up nor answers
*/
button :: proc(rectangle: Rectangle, text: string, style := BUTTON_STYLE, font: ^Font = nil) -> bool {
	font := font if font != nil else default_font()

	hovered := !style.disabled && is_pointer_over_rectangle(rectangle) && !is_pointer_claimed()

	fill := style.fill
	label := style.text_color
	switch {
	case style.disabled:
		fill = calculate_dimmed(fill, style.disabled_dim)
		label = calculate_dimmed(label, style.disabled_dim)
	case hovered:
		fill = style.hover
	}

	render_rectangle(rectangle, fill)

	if len(text) > 0 {
		measured := calculate_text_size(font, text)
		x: f32
		switch style.align {
		case .CENTER:
			x = rectangle.min.x + (calculate_rectangle_size(rectangle).x - measured.x) * 0.5
		case .LEFT:
			x = rectangle.min.x + style.padding
		}
		render_text(font, text, {x, calculate_baseline_centred(font, rectangle)}, label)
	}

	return hovered && is_button_pressed(.LEFT)
}

/*
	A style with `disabled` set the way the caller says:

		if ui.button(rectangle, "Save", ui.calculate_button_enabled_if(name != "")) { ... }
*/
calculate_button_enabled_if :: proc(enabled: bool, style := BUTTON_STYLE) -> Button_Style {
	style := style
	style.disabled = !enabled
	return style
}

// ---- toggle ---------------------------------------------------------------------

Toggle_Style :: struct {
	box:        [4]f32,
	box_hover:  [4]f32,
	tick:       [4]f32,
	text_color: [4]f32,

	disabled:     bool,
	disabled_dim: f32,
}

TOGGLE_STYLE :: Toggle_Style {
	box          = {0.16, 0.16, 0.20, 1},
	box_hover    = {0.22, 0.22, 0.28, 1},
	tick         = {0.55, 0.72, 1.00, 1},
	text_color   = {0.92, 0.92, 0.95, 1},
	disabled_dim = 0.45,
}

/*
	A box ticked or not, with its label beside it. True on the frame it is clicked, `value` already flipped. The square is as
	tall as `rectangle`, at its left, and **the whole rectangle is the click target**, label included
*/
toggle :: proc(rectangle: Rectangle, value: ^bool, label: string = "", style := TOGGLE_STYLE, font: ^Font = nil) -> (changed: bool) {
	hot := !style.disabled && is_pointer_over_rectangle(rectangle) && !is_pointer_claimed()

	if hot && is_button_pressed(.LEFT) {
		value^ = !value^
		changed = true
	}

	font := font if font != nil else default_font()
	side := calculate_rectangle_size(rectangle).y
	dim := style.disabled_dim if style.disabled_dim > 0 else TOGGLE_STYLE.disabled_dim

	box_color := style.box_hover if hot else style.box
	tick_color := style.tick
	text_color := style.text_color
	if style.disabled {
		box_color = calculate_dimmed(box_color, dim)
		tick_color = calculate_dimmed(tick_color, dim)
		text_color = calculate_dimmed(text_color, dim)
	}

	box := Rectangle{min = rectangle.min, max = rectangle.min + {side, side}}
	render_rectangle(box, box_color)
	if value^ {
		inset := side * 0.25
		render_rectangle({min = box.min + inset, max = box.max - inset}, tick_color)
	}
	if len(label) > 0 {
		render_text(font, label, {rectangle.min.x + side + 10, calculate_baseline_centred(font, box)}, text_color)
	}
	return
}
