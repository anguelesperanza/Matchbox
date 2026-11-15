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

	view := linalg.matrix4_look_at_f32({0, 0, 3}, {0, 0, 0}, {0, 1, 0})

	for mb.is_running() {
		mb.poll_events()

		if mb.is_key_pressed(.ESCAPE) || mb.is_gamepad_pressed(.SELECT) {
			mb.stop_running()
		}

		if mb.is_key_pressed(.SPACE) || mb.is_gamepad_pressed(.FACE_DOWN) {
			mb.play_audio(audio = jump_sound) // TODO
		}

		size := mb.get_window_size()
		// if size[1] == 0 do continue // window is minimized so don't render anything
		aspect := cast(f32)size[0] / cast(f32)size[1]
		projection := mb.perspective_projection(linalg.to_radians(cast(f32)60), aspect, 0.1, 100)

		mb.render_start()
		mb.clear_background(color = {0, 0.4, 0.6, 1})

		mb.set_view_projection(projection * view)

		mb.render_test_triangle(linalg.matrix4_translate_f32({0.5, 0, 0}))
		mb.render_test_triangle(linalg.matrix4_translate_f32({-0.5, 0, -1}), {1, 1, 0.3, 1})		
		mb.render_end()
	}

	mb.destroy(jump_sound) // TODO: Audio not implemeted yet

	mb.cleanup()
}
