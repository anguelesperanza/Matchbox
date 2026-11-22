package boot

/*
	Handheld boot
	=============
	The smallest game that proves a target boots on Matchbox: it starts the runtime, prints
	through mb.print, allocates, and runs the frame loop until START is pressed. What a
	backend prints here is what a test run reads back from the emulator's log, so every
	line starts with "boot:".

	It draws nothing but the clear colour, because the handhelds draw nothing else yet
	(A0b, T2 and T3 in render_plan.md). Builds on PC too, as a check that it is one game.
*/

import "core:fmt"

import mb "../../matchbox"

main :: proc() {
	mb.init("Handheld boot", 400, 240)
	defer mb.cleanup()

	// fmt.tprintf uses the temp allocator and `append` the heap: on the 3DS both do nothing
	// unless start_runtime set up the context, so these two lines are the runtime's test
	mb.print("boot: tprintf ->", fmt.tprintf("%d + %d = %d", 2, 3, 2 + 3))
	numbers := make([dynamic]int)
	defer delete(numbers)
	for i in 0..<5 do append(&numbers, i * i)
	mb.print("boot: make/append ->", numbers[:])
	mb.print("boot: window size ->", mb.get_window_size())

	frames := 0
	for mb.is_running() {
		mb.poll_events()

		mb.render_start()
		mb.clear_background({0.2, 0.4, 0.8, 1})
		mb.camera_start(mb.create_screen_camera(12))
		mb.camera_end()
		mb.render_end()

		// Two seconds at 60 fps: the log line's timestamp tells whether the loop keeps pace
		frames += 1
		if frames == 120 do mb.print("boot: 120 frames")
		if mb.is_gamepad_pressed(.START) do mb.stop_running()
	}
}
