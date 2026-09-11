package matchbox

/*
	Number field and toggle -- driven with synthetic input
	-------------------------------------------------------
	The pointer, its left button and the keys are set in `mbi.input` directly,
	a frame at a time, which is all these widgets read. Expected values are the
	arithmetic in the comments: a drag of so many pixels at so much a pixel.

	Typing needs `begin_text_input`, which asks for an initialised Matchbox, so
	those tests mark it initialised; with no window, SDL declines to start text
	input and the widget carries on reading `mbi.input.text` all the same.
*/

import "core:testing"

@(private)
field_rect :: proc() -> Rectangle {
	return Rectangle{position = {100, 100}, size = {120, 30}, pivot = {0.5, 0.5}} // x 100..220, y 100..130
}

// One frame of pointer state, the way poll_events would leave it.
@(private)
pointer :: proc(x, y: f32, pressed, held: bool) {
	mbi.input.mouse.x = x
	mbi.input.mouse.y = y
	mbi.input.mouse.buttons[.LEFT] = Key_State{pressed = pressed, pressing = held}
	mbi.input.mouse.captured = false
}

@(test)
test_a_drag_moves_the_value_from_where_it_started :: proc(t: ^testing.T) {
	state: Number_Field
	defer destroy_number_field(&state)
	value := f32(1)
	style := NUMBER_FIELD_STYLE // 0.01 a pixel

	pointer(150, 115, true, true)
	number_field_input(&state, field_rect(), &value, style)

	pointer(151, 115, false, true) // one pixel: under the three it takes to be a drag
	number_field_input(&state, field_rect(), &value, style)
	testing.expect_value(t, value, 1)

	pointer(250, 115, false, true) // off the end of the field, still held: 100 pixels
	changed := number_field_input(&state, field_rect(), &value, style)
	testing.expect(t, changed, "a drag did not report a change")
	testing.expectf(t, abs(value - 2) < 1e-5, "100 pixels at 0.01 from 1: %v, want 2", value)
	testing.expect(t, is_number_field_active(&state), "a drag under way is not active")

	pointer(250, 115, false, false)
	number_field_input(&state, field_rect(), &value, style)
	testing.expect(t, !is_number_field_active(&state), "a finished drag is still active")
	testing.expect(t, !state.typing, "a drag opened the field for typing")
}

@(test)
test_a_drag_snaps_the_result_not_each_frame :: proc(t: ^testing.T) {
	state: Number_Field
	defer destroy_number_field(&state)
	value := f32(1)
	style := NUMBER_FIELD_STYLE
	style.step = 0.5

	pointer(150, 115, true, true)
	number_field_input(&state, field_rect(), &value, style)

	// Five moves of 26 pixels. Snapping each frame's 0.26 would round every one
	// to 0.5 and land on 3.5; snapping the total, 1 + 1.3 = 2.3, lands on 2.5.
	for step in 1 ..= 5 {
		pointer(150 + f32(step) * 26, 115, false, true)
		number_field_input(&state, field_rect(), &value, style)
	}
	testing.expectf(t, abs(value - 2.5) < 1e-5, "value %v, want 2.5", value)
}

@(test)
test_a_click_opens_typing_and_enter_keeps_the_number :: proc(t: ^testing.T) {
	mbi.initialized = true

	state: Number_Field
	defer destroy_number_field(&state)
	value := f32(1)

	pointer(150, 115, true, true)
	number_field_input(&state, field_rect(), &value, NUMBER_FIELD_STYLE)
	pointer(150, 115, false, false)
	number_field_input(&state, field_rect(), &value, NUMBER_FIELD_STYLE)
	testing.expect(t, state.typing, "a click without a drag did not open the field for typing")
	testing.expect_value(t, state.text.placeholder, "1.00")

	// Typed this frame.
	pointer(150, 115, false, false)
	copy(mbi.input.text[:], "3.75")
	mbi.input.text_length = 4
	number_field_input(&state, field_rect(), &value, NUMBER_FIELD_STYLE)
	mbi.input.text_length = 0
	testing.expect_value(t, value, 1) // nothing is kept until Enter

	mbi.input.keys[.RETURN] = Key_State{pressed = true, pressing = true}
	changed := number_field_input(&state, field_rect(), &value, NUMBER_FIELD_STYLE)
	mbi.input.keys[.RETURN] = {}

	testing.expect(t, changed, "Enter did not report a change")
	testing.expect_value(t, value, 3.75)
	testing.expect(t, !state.typing, "Enter did not close the field")
}

@(test)
test_escape_and_nonsense_leave_the_value :: proc(t: ^testing.T) {
	mbi.initialized = true

	open :: proc(state: ^Number_Field, value: ^f32) {
		pointer(150, 115, true, true)
		number_field_input(state, field_rect(), value, NUMBER_FIELD_STYLE)
		pointer(150, 115, false, false)
		number_field_input(state, field_rect(), value, NUMBER_FIELD_STYLE)
	}
	type :: proc(state: ^Number_Field, value: ^f32, text: string) {
		copy(mbi.input.text[:], text)
		mbi.input.text_length = len(text)
		number_field_input(state, field_rect(), value, NUMBER_FIELD_STYLE)
		mbi.input.text_length = 0
	}

	state: Number_Field
	defer destroy_number_field(&state)
	value := f32(1)

	open(&state, &value)
	type(&state, &value, "9")
	mbi.input.keys[.ESCAPE] = Key_State{pressed = true, pressing = true}
	number_field_input(&state, field_rect(), &value, NUMBER_FIELD_STYLE)
	mbi.input.keys[.ESCAPE] = {}
	testing.expect_value(t, value, 1)
	testing.expect(t, !state.typing, "Escape did not close the field")

	open(&state, &value)
	type(&state, &value, "abc")
	mbi.input.keys[.RETURN] = Key_State{pressed = true, pressing = true}
	number_field_input(&state, field_rect(), &value, NUMBER_FIELD_STYLE)
	mbi.input.keys[.RETURN] = {}
	testing.expect_value(t, value, 1)
}

@(test)
test_a_captured_pointer_does_not_start_a_drag :: proc(t: ^testing.T) {
	state: Number_Field
	defer destroy_number_field(&state)
	value := f32(1)

	pointer(150, 115, true, true)
	mbi.input.mouse.captured = true // a dropdown opened over the field took it
	number_field_input(&state, field_rect(), &value, NUMBER_FIELD_STYLE)
	testing.expect(t, !state.pressed, "a press under a captured pointer started a drag")
}

@(test)
test_a_number_that_shows_as_zero_has_no_sign :: proc(t: ^testing.T) {
	buffer: [32]u8

	// A variable, not a literal: a constant -0.0 is folded to plain zero.
	zero: f32 = 0
	testing.expect_value(t, number_text(buffer[:], -zero, 1), "0.0")
	testing.expect_value(t, number_text(buffer[:], -0.001, 2), "0.00")
	testing.expect_value(t, number_text(buffer[:], -0.4, 0), "0")

	// Anything that shows as more than zero keeps its sign, and a positive one
	// never had one.
	testing.expect_value(t, number_text(buffer[:], -0.05, 2), "-0.05")
	testing.expect_value(t, number_text(buffer[:], -10, 0), "-10")
	testing.expect_value(t, number_text(buffer[:], 1, 2), "1.00")
}

@(test)
test_toggle_flips_on_a_click_anywhere_on_it :: proc(t: ^testing.T) {
	rect  := Rectangle{position = {10, 10}, size = {200, 24}, pivot = {0.5, 0.5}}
	value := false

	pointer(180, 20, true, true) // on the label, well right of the square
	testing.expect(t, toggle_input(rect, &value, TOGGLE_STYLE), "a click on the label did not flip it")
	testing.expect(t, value, "not ticked after a click")

	pointer(180, 20, false, true) // held, not pressed again
	testing.expect(t, !toggle_input(rect, &value, TOGGLE_STYLE), "holding the button flipped it again")

	pointer(300, 20, true, true)
	testing.expect(t, !toggle_input(rect, &value, TOGGLE_STYLE), "a click outside flipped it")

	disabled := TOGGLE_STYLE
	disabled.disabled = true
	pointer(20, 20, true, true)
	testing.expect(t, !toggle_input(rect, &value, disabled), "a disabled toggle flipped")
	testing.expect(t, value, "a disabled toggle changed its value")
}
