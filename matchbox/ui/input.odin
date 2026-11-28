#+build windows

package ui

/*
	Input
	=====
	The pointer as the widgets see it: where it is in screen units, which buttons went down this frame, and whether something
	on top has already claimed it. Read from Matchbox once a frame into `ui_state.input`, so a test can write the same struct
	and drive a widget without a window.

	**The keyboard is Matchbox's**, asked directly (mb.is_key_pressed): a test writes the same fields Matchbox's own tests
	write. Only typed text is copied here, so a test can type by writing `ui_state.input.text`.

	The pointer is *claimed*, not captured: Matchbox's own mb.is_mouse_captured is the operating system's lock for looking
	around, a different thing.
*/

import mb ".."

MAX_TEXT_INPUT :: mb.MAX_TEXT_INPUT

Button_State :: struct {
	pressed:  bool, // went down this frame
	pressing: bool, // is down
	released: bool, // came up this frame
}

Input :: struct {
	mouse:   [2]f32, // screen units
	delta:   [2]f32, // units moved since last frame
	wheel:   [2]f32, // notches this frame; positive y is away from the user
	buttons: [mb.Mouse]Button_State,

	/*
		Whether something on top has claimed the pointer this frame. False again at the next begin_frame.

		Drawing is immediate, so what is drawn last is on top and nothing knows what is above it. A widget that opens out over
		others claims the pointer, and whatever is underneath asks before acting on a click of its own: otherwise the click
		that picks an option out of an open list also lands on whatever the list was covering
	*/
	claimed: bool,

	// What was typed this frame, as UTF-8, and whether typing is being accepted at all: a text field turns it on while it has
	// focus, so the editor's single-key shortcuts can stand aside
	text:        [MAX_TEXT_INPUT]u8,
	text_length: int,
	text_open:   bool,
}

@(private)
read_input :: proc(input: ^Input) {
	previous := input.mouse
	input.mouse = mb.calculate_mouse_screen_position()
	input.delta = input.mouse - previous
	input.wheel = {f32(mb.get_mouse_wheel_horizontal_value()) / 120, f32(mb.get_mouse_wheel_value()) / 120}

	for button in mb.Mouse {
		input.buttons[button] = {
			pressed  = mb.is_mouse_pressed(button),
			pressing = mb.is_mouse_held(button),
			released = mb.is_mouse_released(button),
		}
	}

	input.claimed = false

	typed := mb.get_typed_text()
	input.text_length = min(len(typed), MAX_TEXT_INPUT)
	copy(input.text[:input.text_length], typed)
}

get_pointer_position :: proc() -> [2]f32 {
	return ui_state.input.mouse
}

get_pointer_delta :: proc() -> [2]f32 {
	return ui_state.input.delta
}

/*Notches turned this frame: x sideways (positive right), y forwards (positive away from the user)*/
get_pointer_wheel :: proc() -> [2]f32 {
	return ui_state.input.wheel
}

/*True only on the frame the button went down*/
is_button_pressed :: proc(button: mb.Mouse) -> bool {
	return ui_state.input.buttons[button].pressed
}

/*True every frame the button is down: what a drag reads*/
is_button_held :: proc(button: mb.Mouse) -> bool {
	return ui_state.input.buttons[button].pressing
}

/*True only on the frame the button came back up*/
is_button_released :: proc(button: mb.Mouse) -> bool {
	return ui_state.input.buttons[button].released
}

/*Claims the pointer for whatever is on top, for the rest of this frame*/
claim_pointer :: proc() {
	ui_state.input.claimed = true
}

/*Hands the pointer back: a modal, having drawn its dim, gives it to the buttons inside it*/
release_pointer :: proc() {
	ui_state.input.claimed = false
}

/*Whether something above has claimed the pointer this frame. Ask before acting on a click*/
is_pointer_claimed :: proc() -> bool {
	return ui_state.input.claimed
}

/*
	Whether the pointer is inside a rectangle and inside the clip in force.

	The clip is part of the question because a row scrolled out of a panel is cut out of the picture by the scissor, and would
	answer the pointer anyway without this: the scissor is drawing state and a hit test never sees it
*/
is_pointer_over_rectangle :: proc(rectangle: Rectangle) -> bool {
	return is_point_in_rectangle(ui_state.input.mouse, rectangle) && is_point_in_clip(ui_state.input.mouse)
}

// ---- typing -------------------------------------------------------------------

/*Starts accepting typed text. The screen owning the fields ends it*/
start_text_input :: proc() {
	ui_state.input.text_open = true
}

end_text_input :: proc() {
	ui_state.input.text_open = false
}

/*Whether typing is being accepted: what the editor checks before treating a key as a shortcut rather than a letter someone typed*/
is_text_input_open :: proc() -> bool {
	return ui_state.input.text_open
}

/*What was typed this frame, while typing is accepted; empty otherwise*/
get_text_input :: proc() -> string {
	if !ui_state.input.text_open do return ""
	return string(ui_state.input.text[:ui_state.input.text_length])
}
