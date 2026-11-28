#+build windows

package ui

MODAL_DIM :: [4]f32{0, 0, 0, 0.6}

/*
	Something put up over a screen, in two halves like Dropdown:

		ui.modal_begin(&dialog)   // early: takes the pointer
		... the whole screen ...
		if box, open := ui.modal_overlay(&dialog, {480, 320}); open { ... }
*/
Modal :: struct {
	open:      bool,
	opened_on: u64, // the frame it opened, whose click belongs to what opened it
}

open_modal :: proc(modal: ^Modal) {
	modal.open = true
	modal.opened_on = ui_state.frame
}

close_modal :: proc(modal: ^Modal) {
	modal.open = false
}

is_modal_open :: proc(modal: ^Modal) -> bool {
	return modal.open
}

/*Takes the pointer for the frame while the modal is up. Call early*/
modal_begin :: proc(modal: ^Modal) -> bool {
	if modal.open do claim_pointer()
	return modal.open
}

/*
	Draws the dim and hands back a centred box for the content. Call late.

	The pointer is given back here so buttons in the box answer normally, except on the frame it opened, where the press that
	opened it belongs to whatever was clicked, and is held so it reaches nothing
*/
modal_overlay :: proc(modal: ^Modal, size: [2]f32, dim := MODAL_DIM) -> (content: Rectangle, open: bool) {
	if !modal.open do return {}, false

	screen := get_screen_rectangle()
	render_rectangle(screen, dim)

	if modal.opened_on == ui_state.frame {
		claim_pointer()
	} else {
		release_pointer()
	}
	return create_rectangle_centred(calculate_rectangle_centre(screen), size), true
}

/*Whether the click landed on the dim rather than the content. After whatever went inside, so a button in the content gets the click first*/
is_modal_dismissed :: proc(content: Rectangle) -> bool {
	return is_button_pressed(.LEFT) && !is_pointer_over_rectangle(content) && !is_pointer_claimed()
}
