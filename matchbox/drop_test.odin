package matchbox

/*
	Dropped files and the close button, without a window
	-----------------------------------------------------
	SDL's own events cannot be raised from a test, so the two procedures
	`poll_events` calls for them -- `record_dropped_file` and `request_close` --
	are driven here directly. Expected values are the arithmetic in the
	comments.
*/

import "core:testing"

@(test)
test_dropped_files_last_one_frame :: proc(t: ^testing.T) {
	defer drops_cleanup()

	mbi.window_width, mbi.window_height = 1600, 900
	mbi.fixed_res     = false
	mbi.pixel_density = 1
	set_ui_scale(2)
	update_display_transform()

	drops_begin_frame()
	record_dropped_file("C:/project/assets/crate.gltf", {400, 200})
	record_dropped_file("C:/project/levels/yard.level", {0, 0})

	dropped := get_dropped_files()
	testing.expect_value(t, len(dropped), 2)
	testing.expect_value(t, dropped[0].path, "C:/project/assets/crate.gltf")
	testing.expect_value(t, dropped[1].path, "C:/project/levels/yard.level")

	// Window point (400, 200) at a UI scale of 2 is logical (200, 100) -- where
	// the pointer would read, so a model lands under what was let go of.
	testing.expect_value(t, dropped[0].position, [2]f32{200, 100})
	testing.expect_value(t, dropped[1].position, [2]f32{0, 0})

	// The next frame starts empty.
	drops_begin_frame()
	testing.expect_value(t, len(get_dropped_files()), 0)
}

@(test)
test_a_close_request_stops_the_loop_unless_a_program_takes_it :: proc(t: ^testing.T) {
	defer set_quit_on_close(true)

	// By default the X button closes the window, as it always did.
	mbi.running = true
	mbi.close_requested = false
	set_quit_on_close(true)
	request_close()
	testing.expect(t, !mbi.running, "the X button should close the window by default")
	testing.expect(t, is_close_requested(), "and the frame should be able to see the request")

	// A program that says it will answer keeps running, and closes when ready.
	mbi.running = true
	mbi.close_requested = false
	set_quit_on_close(false)
	request_close()
	testing.expect(t, mbi.running, "a program answering the request should keep running")
	testing.expect(t, is_close_requested(), "and should see the request")

	stop_running()
	testing.expect(t, !mbi.running, "stop_running should end the loop")
}
