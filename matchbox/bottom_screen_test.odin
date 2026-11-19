package matchbox

import "core:testing"

@(test)
wide_window_keeps_the_height :: proc(t:^testing.T) {
	testing.expect_value(t, bottom_screen_view_height(12, 16.0 / 9.0), 12)
	testing.expect_value(t, bottom_screen_view_height(12, BOTTOM_SCREEN_ASPECT), 12)
}

@(test)
narrow_window_holds_the_width :: proc(t:^testing.T) {
	// A square window: 4:3 of 12 is 16 wide, so the view must be 16 tall to be 16 wide
	height := bottom_screen_view_height(12, 1)
	testing.expect_value(t, height, 16)
	testing.expect(t, abs(height * 1 - 12 * BOTTOM_SCREEN_ASPECT) < 0.001)

	// A tall window needs even more height
	testing.expect_value(t, bottom_screen_view_height(12, 0.5), 32)
}

@(test)
no_window_shape_keeps_the_height :: proc(t:^testing.T) {
	testing.expect_value(t, bottom_screen_view_height(12, 0), 12) // minimised
}
