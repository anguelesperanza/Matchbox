#+build windows

package ui

/*
	The widgets, driven without a window
	====================================
	Each test writes `ui_state.input` a frame at a time (where the pointer is, whether the button went down) and calls the
	widget the way a screen does. Nothing draws: every drawing call checks for a screen pass and returns. What is checked is
	what an editor relies on: pointer capture, the dropdown's two halves, the number field's drag and typing, the clip in hit
	tests, the scroll view's flipped arithmetic, and text measured the same at every UI scale.

	Ported from Stargate's ui_test.odin with every number turned over: Stargate's layout ran down the screen with y growing,
	this runs down it with y falling, so a row below another has the smaller y. The screen is Matchbox's with no window: 1280
	by 720, the origin in the middle, so x runs -640..640 and y -360..360.

	Typing is committed the other way the field allows (by clicking elsewhere), and the keyboard is Matchbox's, so a key is
	"pressed" by writing mb.mbi.keys_pressed. The tests share `ui_state`: run them one at a time
	(-define:ODIN_TEST_THREADS=1)
*/

import "core:math"
import "core:testing"

import mb ".."

// One frame of pointer: where it is, and the left button's state
@(private = "file")
pointer :: proc(at: [2]f32, pressed := false, held := false) {
	ui_state.frame += 1
	ui_state.input.mouse = at
	ui_state.input.claimed = false
	ui_state.input.buttons[.LEFT] = {pressed = pressed, pressing = held || pressed}
	ui_state.input.buttons[.RIGHT] = {}
	ui_state.input.text_length = 0
}

@(private = "file")
reset :: proc() {
	ui_state.input = {}
	ui_state.clip = {}
	ui_state.scale = 1
	ui_state.time = 0
}

@(test)
a_button_answers_a_press_over_it_and_nothing_else :: proc(t: ^testing.T) {
	reset()
	defer destroy_fonts(&ui_state.fonts) // fonts are made with this test's allocator, which is gone when it ends
	box := create_rectangle({100, 100}, {80, 30}) // x 100..180, y 70..100

	pointer({120, 85}, pressed = true)
	testing.expect(t, button(box, "Go"), "a press inside did not click")

	pointer({20, 20}, pressed = true)
	testing.expect(t, !button(box, "Go"), "a press outside clicked")

	pointer({120, 85}, pressed = true)
	claim_pointer()
	testing.expect(t, !button(box, "Go"), "a press something above had claimed still clicked")

	pointer({120, 85}, pressed = true)
	testing.expect(t, !button(box, "Go", calculate_button_enabled_if(false)), "a disabled button clicked")
}

@(test)
the_clip_is_part_of_being_over_a_rectangle :: proc(t: ^testing.T) {
	reset()
	defer destroy_fonts(&ui_state.fonts) // fonts are made with this test's allocator, which is gone when it ends
	row := create_rectangle({0, -200}, {100, 20}) // y -220..-200

	// A row scrolled below its panel is cut from the picture, and must not answer the pointer through whatever is drawn
	// there instead
	pointer({50, -210})
	begin_clip(create_rectangle({0, 0}, {100, 150}))
	testing.expect(t, !is_pointer_over_rectangle(row), "a row outside the clip answered the pointer")
	end_clip()

	testing.expect(t, is_pointer_over_rectangle(row), "with the clip lifted the row should answer")

	// Nested clips intersect: the inner one cannot reach past the outer
	begin_clip(create_rectangle({0, 0}, {100, 100}))
	begin_clip(create_rectangle({0, 0}, {100, 300}))
	testing.expect(t, !is_pointer_over_rectangle(row), "an inner clip escaped the outer one")
	end_clip()
	end_clip()
}

@(test)
a_dropdown_opens_takes_the_pointer_and_picks :: proc(t: ^testing.T) {
	reset()
	defer destroy_fonts(&ui_state.fonts) // fonts are made with this test's allocator, which is gone when it ends
	options := []string{"one", "two", "three"}
	box := create_rectangle({100, 100}, {120, 30}) // y 70..100
	dd: Dropdown

	pointer({110, 85}, pressed = true)
	testing.expect(t, !dropdown(&dd, box, options), "opening is not a change")
	testing.expect(t, dd.open, "a press on the box did not open it")

	// The rows hang under the box, 30 tall with a 1 unit gap: 40..70, 9..39, -22..8
	pointer({110, -10})
	dropdown(&dd, box, options)
	testing.expect(t, is_pointer_claimed(), "the open list did not take the pointer over it")

	pointer({110, -10}, pressed = true)
	testing.expect(t, dropdown(&dd, box, options), "picking another option was not a change")
	testing.expect_value(t, dd.selected, 2)
	testing.expect(t, !dd.open, "picking did not close the list")

	// Open again and click away: closed, nothing chosen
	pointer({110, 85}, pressed = true)
	dropdown(&dd, box, options)
	pointer({400, 300}, pressed = true)
	testing.expect(t, !dropdown(&dd, box, options), "clicking away was a change")
	testing.expect(t, !dd.open && dd.selected == 2, "clicking away should close and keep the choice")
}

@(test)
a_dropdown_near_the_bottom_opens_upwards :: proc(t: ^testing.T) {
	reset()
	defer destroy_fonts(&ui_state.fonts) // fonts are made with this test's allocator, which is gone when it ends
	options := []string{"one", "two", "three"}
	box := create_rectangle({0, -330}, {120, 30}) // y -360..-330: the bottom edge of the screen
	dd := Dropdown{anchor = .BOX, rectangle = box, row = {120, 30}}

	// No room below, so the list sits on top of the box: 3 rows and 2 gaps is 92 tall, from y -330 up
	list := calculate_dropdown_list(&dd, len(options))
	testing.expect_value(t, list.min.y, -330)
	testing.expect_value(t, list.max.y, -238)

	// And the rows still run from the top down: the first is the highest
	first := calculate_dropdown_row(&dd, 0, len(options))
	testing.expect_value(t, first.max.y, list.max.y)
	testing.expect(t, calculate_dropdown_row(&dd, 2, len(options)).max.y < first.max.y, "the third row should be lower than the first")
}

@(test)
a_context_menu_ignores_the_click_that_opened_it :: proc(t: ^testing.T) {
	reset()
	defer destroy_fonts(&ui_state.fonts) // fonts are made with this test's allocator, which is gone when it ends
	options := []string{"Rename", "Delete"}
	menu: Dropdown

	pointer({300, 300}, pressed = true)
	open_context_menu(&menu, {300, 300}, {140, 30})
	_, picked := context_menu(&menu, options)
	testing.expect(t, !picked, "the opening click picked the first entry")
	testing.expect(t, menu.open, "the menu closed on the frame it opened")

	pointer({310, 255}, pressed = true) // the second row: 239..269
	chosen, picked_again := context_menu(&menu, options)
	testing.expectf(t, picked_again && chosen == 1, "picking the second entry gave %v, %v", chosen, picked_again)
}

@(test)
a_number_field_drags_from_where_it_started :: proc(t: ^testing.T) {
	reset()
	defer destroy_fonts(&ui_state.fonts) // fonts are made with this test's allocator, which is gone when it ends
	field: Number_Field
	defer destroy_number_field(&field)
	box := create_rectangle({0, 0}, {100, 30}) // y -30..0

	value: f32 = 1
	style := NUMBER_FIELD_STYLE
	style.speed = 0.1
	style.step = 0.5

	pointer({50, -15}, pressed = true)
	number_field(&field, box, &value, style)

	// Two units is under the threshold: still a press, not a drag
	pointer({52, -15}, held = true)
	number_field(&field, box, &value, style)
	testing.expect_value(t, value, 1)

	// 23 units right of where the drag began is 1 + 2.3 = 3.3, and the result is snapped, not the step: 3.5. Measured from
	// the start wherever the pointer goes, even off the field
	pointer({73, -60}, held = true)
	testing.expect(t, number_field(&field, box, &value, style), "a drag did not change the value")
	testing.expect_value(t, value, 3.5)
	testing.expect(t, is_number_field_active(&field), "a drag under way should be active")

	pointer({73, -60})
	number_field(&field, box, &value, style)
	testing.expect(t, !field.typing, "letting go of a drag opened the field for typing")
}

@(test)
a_number_field_clicked_is_typed_into :: proc(t: ^testing.T) {
	reset()
	defer destroy_fonts(&ui_state.fonts) // fonts are made with this test's allocator, which is gone when it ends
	field: Number_Field
	defer destroy_number_field(&field)
	box := create_rectangle({0, 0}, {100, 30})
	value: f32 = 4

	pointer({50, -15}, pressed = true)
	number_field(&field, box, &value)
	pointer({50, -15})
	number_field(&field, box, &value)
	testing.expect(t, field.typing, "a click without a drag did not open the field for typing")
	testing.expect_value(t, field.text.placeholder, "4.00")

	// What the keyboard would have typed, then a click elsewhere to keep it
	pointer({50, -15})
	copy(ui_state.input.text[:], "-2.5")
	ui_state.input.text_length = 4
	number_field(&field, box, &value)

	pointer({300, 300}, pressed = true)
	testing.expect(t, number_field(&field, box, &value), "committing the typing was not a change")
	testing.expect_value(t, value, -2.5)
	testing.expect(t, !field.typing && !is_text_input_open(), "committing did not end the typing")
}

@(test)
a_modal_is_not_dismissed_by_the_click_that_opened_it :: proc(t: ^testing.T) {
	reset()
	defer destroy_fonts(&ui_state.fonts) // fonts are made with this test's allocator, which is gone when it ends
	modal: Modal

	pointer({10, 10}, pressed = true)
	open_modal(&modal)
	modal_begin(&modal)
	content, open := modal_overlay(&modal, {200, 100})
	testing.expect(t, open, "the modal is not open")
	testing.expect(t, !is_modal_dismissed(content), "the opening click dismissed it")

	// The content is centred on the screen, whose middle is the origin
	testing.expect_value(t, calculate_rectangle_centre(content), [2]f32{0, 0})
	testing.expect_value(t, calculate_rectangle_size(content), [2]f32{200, 100})

	pointer({400, 300}, pressed = true) // on the dim, outside the box
	modal_begin(&modal)
	content, _ = modal_overlay(&modal, {200, 100})
	testing.expect(t, is_modal_dismissed(content), "a later click on the dim did not dismiss it")
}

@(test)
a_timed_status_fades_then_goes :: proc(t: ^testing.T) {
	reset()
	defer destroy_fonts(&ui_state.fonts) // fonts are made with this test's allocator, which is gone when it ends
	status: Status_Line

	set_status(&status, "saved", .GOOD, 2)
	testing.expect_value(t, get_status_text(&status), "saved")

	ui_state.time = 1
	testing.expect_value(t, calculate_status_alpha(&status), 1)
	ui_state.time = 1.75 // a quarter of a second left, half of the fade
	testing.expectf(t, math.abs(calculate_status_alpha(&status) - 0.5) < 1e-4, "halfway through the fade: %v", calculate_status_alpha(&status))
	ui_state.time = 3
	testing.expect_value(t, calculate_status_alpha(&status), 0)
}

@(test)
text_measures_the_same_at_every_scale :: proc(t: ^testing.T) {
	reset()
	defer destroy_fonts(&ui_state.fonts) // fonts are made with this test's allocator, which is gone when it ends

	TEXT :: "The quick brown fox, 1234"
	at_1 := calculate_text_size(get_font(16), TEXT)

	ui_state.scale = 2
	at_2 := calculate_text_size(get_font(16), TEXT)

	// Baked at 32 pixels and drawn 1:1, but laid out in the same units: a pixel font rounds each advance to whole pixels at the size it is baked at, so up to a unit a glyph apart, never
	// twice as big
	testing.expectf(t, at_1.x > 0 && at_1.y > 0, "nothing measured: %v", at_1)
	testing.expectf(t, math.abs(at_1.x - at_2.x) <= f32(len(TEXT)), "width %v at 1 against %v at 2", at_1.x, at_2.x)
	testing.expectf(t, math.abs(at_1.y - at_2.y) <= 1, "height %v at 1 against %v at 2", at_1.y, at_2.y)

	// The height is the font's, not the glyphs': a line does not jump as it changes
	ui_state.scale = 1
	font := get_font(16)
	testing.expect_value(t, calculate_text_size(font, "Play").y, calculate_text_size(font, "Play Card").y)
}

@(test)
wrapped_text_fits_and_breaks_a_word_too_long_to :: proc(t: ^testing.T) {
	reset()
	defer destroy_fonts(&ui_state.fonts) // fonts are made with this test's allocator, which is gone when it ends
	font := get_font(16)

	width := calculate_text_size(font, "a line of text").x
	lines := wrap_text(font, "a line of text that is too long for one line", width, context.temp_allocator)
	testing.expectf(t, len(lines) > 1, "nothing wrapped: %v", lines)
	for line in lines {
		testing.expectf(t, calculate_text_size(font, line).x <= width, "%q is wider than %v", line, width)
		testing.expectf(t, len(line) == 0 || line[0] != ' ', "%q starts with a space", line)
	}

	narrow := calculate_text_size(font, "abc").x
	broken := wrap_text(font, "abcdefghij", narrow, context.temp_allocator)
	testing.expectf(t, len(broken) >= 3, "a word wider than the box was not broken: %v", broken)
}

// ---- what Stargate's tests did not cover: the arithmetic that turned over -----------------------

@(test)
a_scroll_view_lays_content_out_downwards_and_scrolls_it_up :: proc(t: ^testing.T) {
	reset()
	defer destroy_fonts(&ui_state.fonts) // fonts are made with this test's allocator, which is gone when it ends
	view: Scroll_View
	panel := create_rectangle({0, 0}, {100, 100}) // y -100..0, content 300 tall: 200 to scroll

	pointer({50, -50})
	origin := begin_scroll(&view, panel, 300)
	end_scroll(&view)
	testing.expect_value(t, origin, [2]f32{0, 0}) // not scrolled: content starts at the panel's top edge

	// A notch away from the user scrolls up: the offset goes down, which cannot go below 0
	ui_state.input.wheel = {0, 1}
	begin_scroll(&view, panel, 300)
	end_scroll(&view)
	testing.expect_value(t, view.offset, 0)

	// A notch towards the user (negative) scrolls the content up by a step, so its origin rises above the panel's top edge
	pointer({50, -50})
	ui_state.input.wheel = {0, -1}
	origin = begin_scroll(&view, panel, 300)
	end_scroll(&view)
	testing.expect_value(t, view.offset, DEFAULTS.scroll_wheel_step)
	testing.expect_value(t, origin.y, DEFAULTS.scroll_wheel_step)

	// scroll_to takes distances down from the content's top: a band at 250..290 needs the offset to reach 190
	view.offset = 0
	scroll_to(&view, 250, 40)
	testing.expect_value(t, view.offset, 190)
}

@(test)
dragging_the_scroll_thumb_down_scrolls_the_content_up :: proc(t: ^testing.T) {
	reset()
	defer destroy_fonts(&ui_state.fonts) // fonts are made with this test's allocator, which is gone when it ends
	view: Scroll_View
	panel := create_rectangle({0, 0}, {100, 100})

	pointer({50, -50})
	begin_scroll(&view, panel, 300)
	end_scroll(&view)

	// At the top the thumb is at the top of the track
	thumb := calculate_scrollbar_thumb(&view)
	track := calculate_scrollbar_track(&view)
	testing.expect_value(t, thumb.max.y, track.max.y)

	// Take hold of the thumb's middle and pull to the bottom of the track: scrolled all the way
	grab := calculate_rectangle_centre(thumb)
	pointer(grab, pressed = true)
	begin_scroll(&view, panel, 300)
	end_scroll(&view)
	testing.expect(t, view.dragging, "a press on the thumb did not take hold of it")

	pointer({grab.x, track.min.y - 50}, held = true)
	begin_scroll(&view, panel, 300)
	end_scroll(&view)
	testing.expect_value(t, view.offset, 200)
	testing.expect_value(t, calculate_scrollbar_thumb(&view).min.y, track.min.y)
}
