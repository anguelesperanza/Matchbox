package keypress

import "../../matchbox"

/*
	At the time of writting this example; there is no font rendering.
	Text is printed to the console.
*/

import "core:fmt"

main :: proc() {

	mbi := matchbox.init("Move Rectangle", 1280, 720)

	rectangle := matchbox.create_default_rectangle()

	for mbi.running {
		matchbox.poll_events(&mbi)

		if matchbox.is_key_held(&mbi, .W) {
			rectangle.pos.y -= 0.001
		}

		if matchbox.is_key_held(&mbi, .A) {
			rectangle.pos.x -= 0.001
		}

		if matchbox.is_key_held(&mbi, .S) {
			rectangle.pos.y += 0.001
		}
		if matchbox.is_key_held(&mbi, .D) {
			rectangle.pos.x += 0.001
		}

		fmt.println(rectangle.pos)

		matchbox.begin_render(&mbi)
		matchbox.render_shape(&mbi, rectangle)
		matchbox.end_render(&mbi)
	}

	matchbox.destroy_shape(&rectangle)
	matchbox.cleanup(&mbi)
}
