package matchbox

/*
	ui.odin
	-------

	This is a place to add very basic UI elements that can be resued between projects.
	Nothing in here is polished at the moment and only has what it is needed for the current project
*/

Button :: struct {
	text:string,
	rectangle:Rectangle,
}

draw_button :: proc(button:Button) {
	draw_rect(button.rectangle)
	draw_text(
		&mbi.font,
		button.text,
		button.rectangle.position.x + 2,
		button.rectangle.position.y + 2,
		WHITE,
	)
}


mouse_over_button :: proc(button:Button) -> bool {
	mouse_x := mbi.input.mouse.x
	mouse_y := mbi.input.mouse.y
	button_x := button.rectangle.position.x
	button_y := button.rectangle.position.y
	button_width := button.rectangle.size.x
	button_height := button.rectangle.size.y

	if mouse_x >= button_x && mouse_x <= button_x + button_width {
		if mouse_y >= button_y && mouse_y <= button_y + button_height {
			return true
		}
	}
	return false
}
