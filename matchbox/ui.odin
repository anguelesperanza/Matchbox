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
