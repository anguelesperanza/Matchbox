package demo
import mb "matchbox"

import "core:fmt"
import "core:math/linalg"

main :: proc() {
	mb.init("Demo Window", 1920, 1080)

	// TODO
	jump_sound:mb.Audio = mb.load_audio(filepath = "path-to-audio")

	mb.print("Hello", "World", 10)
	mb.print(fmt.tprintf("%v", 1.5))

	for mb.is_running() {
		mb.poll_events()

		if mb.is_key_pressed(.ESCAPE) || mb.is_gamepad_pressed(.SELECT) {
			mb.stop_running()
		}

		if mb.is_key_pressed(.SPACE) || mb.is_gamepad_pressed(.FACE_DOWN) {
			mb.play_audio(audio = jump_sound) // TODO
		}

		mb.render_start()
		mb.clear_background(color = {0, 0.4, 0.6, 1})

		mb.set_view_projection(linalg.MATRIX4F32_IDENTITY)

		mb.render_test_triangle()
		mb.render_end()
	}

	mb.destroy(jump_sound) // TODO: Audio not implemeted yet

	mb.cleanup()
}
