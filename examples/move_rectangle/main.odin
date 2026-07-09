package keypress

import "../../matchbox"

/*
	At the time of writting this example; there is no font rendering.
	Text is printed to the console.
*/

import "core:fmt"

main :: proc() {

	mbi := matchbox.init("Key Press", 1280, 720)

	rectangle := matchbox.create_default_rectangle()

	for mbi.running {
		matchbox.poll_events(&mbi)

		if matchbox.is_key_held(&mbi, .W) {
			rectangle.pos.x += 10

			fmt.println(rectangle.pos)
		}

		if matchbox.is_key_pressed(&mbi, .A) {
			fmt.println("A Key Pressed")
		}

		if matchbox.is_key_pressed(&mbi, .S) {
			fmt.println("S Key Pressed")
		}
		if matchbox.is_key_pressed(&mbi, .D) {
			fmt.println("D Key Pressed")
		}

		matchbox.begin_render(&mbi)
		matchbox.render_shape(&mbi, rectangle)
		matchbox.end_render(&mbi)
	}

	matchbox.destroy_shape(&rectangle)
	matchbox.cleanup(&mbi)
}
