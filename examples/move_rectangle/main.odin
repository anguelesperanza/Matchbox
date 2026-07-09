package keypress

import "../../matchbox"

/*
	At the time of writting this example; there is no font rendering.
	Text is printed to the console.
*/

import "core:fmt"

main :: proc() {

	mbi := matchbox.init("Key Press", 200, 200)


	for mbi.running {
		matchbox.poll_events(&mbi)

		if matchbox.is_key_pressed(&mbi, .W) {
			fmt.println("W Key Pressed")
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

		if matchbox.is_key_released(&mbi, .F) {
			fmt.println("F Key Released")
		}

		if matchbox.is_key_held(&mbi, .E) {
			fmt.println("E Key Pressed")
		}

		
		matchbox.begin_render(&mbi)
		matchbox.end_render(&mbi)
	}

	matchbox.cleanup(&mbi)
}
