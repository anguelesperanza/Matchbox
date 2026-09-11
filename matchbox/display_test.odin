package matchbox

/*
	UI scale and the pointer's shape -- the bookkeeping, without a window
	----------------------------------------------------------------------
	`update_display_transform` is what `begin_drawing` runs on the window's size
	each frame, and `cursor_begin_frame` what `poll_events` runs; both are
	driven here by setting `mbi` directly. Expected values are the arithmetic in
	the comments.

	**Not tested here:** that a face baked at the scaled size is what text is
	drawn with. Baking needs a GPU; `text_bake_scale`, which chooses the size, is
	tested, and the drawing is checked in Stargate's editor.
*/

import "core:testing"

@(private = "file")
display_setup :: proc(width, height: i32) {
	mbi.window_width  = width
	mbi.window_height = height
	mbi.width         = width
	mbi.height        = height
	mbi.fixed_res     = false
	mbi.ui_scale      = 0
	mbi.camera        = {}
}

@(test)
test_a_ui_scale_divides_the_window_into_the_logical_size :: proc(t: ^testing.T) {
	display_setup(1600, 900)
	set_ui_scale(2)
	update_display_transform()

	// 1600 / 2 by 900 / 2, from the top-left, and each logical pixel twice as big.
	testing.expect_value(t, mbi.width, 800)
	testing.expect_value(t, mbi.height, 450)
	testing.expect_value(t, mbi.draw_scale, 2)
	testing.expect_value(t, mbi.draw_offset, [2]f32{0, 0})
	testing.expect_value(t, get_ui_scale(), 2)

	// Logical (200, 100) lands on window pixel (400, 200).
	testing.expect_value(t, screen_pos({200, 100}), [2]f32{400, 200})
	testing.expect_value(t, screen_size({10, 5}), [2]f32{20, 10})

	// And text is baked for twice its size.
	testing.expect_value(t, text_bake_scale(), 2)
}

// A window one pixel past a whole number of logical pixels: 1601 / 2 is 800,
// not 801, so nothing is laid out past the window's edge.
@(test)
test_a_scaled_logical_size_never_overhangs_the_window :: proc(t: ^testing.T) {
	display_setup(1601, 901)
	set_ui_scale(1.5)
	update_display_transform()

	// 1601 / 1.5 = 1067.33 and 901 / 1.5 = 600.67, rounded down.
	testing.expect_value(t, mbi.width, 1067)
	testing.expect_value(t, mbi.height, 600)
	testing.expect(t, f32(mbi.width) * mbi.draw_scale <= 1601, "the logical width, drawn, is no wider than the window")
}

// Never set, zero, or negative: the window itself, as before this existed.
@(test)
test_no_ui_scale_is_the_window_as_before :: proc(t: ^testing.T) {
	display_setup(1280, 720)
	update_display_transform()
	testing.expect_value(t, mbi.width, 1280)
	testing.expect_value(t, mbi.draw_scale, 1)
	testing.expect_value(t, text_bake_scale(), 1)

	set_ui_scale(-3)
	update_display_transform()
	testing.expect_value(t, get_ui_scale(), 1)
	testing.expect_value(t, mbi.height, 720)
}

// A pinned size says how big things are already. 640x480 in 1600x900 fits at
// min(2.5, 1.875) = 1.875: 1200 wide, (1600 - 1200) / 2 = 200 either side.
@(test)
test_a_pinned_logical_size_ignores_the_ui_scale :: proc(t: ^testing.T) {
	display_setup(1600, 900)
	defer mbi.fixed_res = false

	set_ui_scale(2)
	set_logical_size(640, 480)
	update_display_transform()

	testing.expect_value(t, mbi.width, 640)
	testing.expect_value(t, mbi.height, 480)
	testing.expect_value(t, mbi.draw_scale, 1.875)
	testing.expect_value(t, mbi.draw_offset, [2]f32{200, 0})

	// A letterbox's scale changes with every pixel the window is dragged, so
	// text is not baked for it.
	testing.expect_value(t, text_bake_scale(), 1)
}

@(test)
test_a_2d_camera_is_not_baked_for :: proc(t: ^testing.T) {
	display_setup(1600, 900)
	defer mbi.camera = {}

	set_ui_scale(2)
	update_display_transform()
	mbi.camera.active = true
	testing.expect_value(t, text_bake_scale(), 1)
}

@(test)
test_a_cursor_shape_lasts_one_frame :: proc(t: ^testing.T) {
	mbi.input.cursor_wanted = .ARROW
	mbi.input.cursor_shown  = .ARROW

	// Asked for during a frame, shown from the next poll.
	set_cursor_shape(.RESIZE_EW)
	testing.expect_value(t, get_cursor_shape(), Cursor_Shape.ARROW)
	cursor_begin_frame()
	testing.expect_value(t, get_cursor_shape(), Cursor_Shape.RESIZE_EW)

	// Asked for again: still showing.
	set_cursor_shape(.RESIZE_EW)
	cursor_begin_frame()
	testing.expect_value(t, get_cursor_shape(), Cursor_Shape.RESIZE_EW)

	// Not asked for: back to the arrow.
	cursor_begin_frame()
	testing.expect_value(t, get_cursor_shape(), Cursor_Shape.ARROW)

	// The last call in a frame wins.
	set_cursor_shape(.HAND)
	set_cursor_shape(.RESIZE_NS)
	cursor_begin_frame()
	testing.expect_value(t, get_cursor_shape(), Cursor_Shape.RESIZE_NS)
}
