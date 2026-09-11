package matchbox

/*
	The hit test and the clip
	-------------------------
	`is_mouse_over_rect` answers only inside the clip in force. Found in a card
	game's deck builder: a button in a panel's foot also pressed the list row
	scrolled out of sight underneath it (improvements.md).

	No window: `begin_clip` only records the rectangle when no pass is open, and
	the pointer is set directly, which is all the test reads. The expected
	answers are the geometry of the rectangles below, worked out by hand.
*/

import "core:testing"

@(private)
hit_test_setup :: proc() {
	mbi.window_width  = 800
	mbi.window_height = 600
	mbi.draw_scale    = 1
	mbi.draw_offset   = {0, 0}
	mbi.camera        = {}
}

@(private)
put_mouse :: proc(x, y: f32) {
	mbi.input.mouse.x = x
	mbi.input.mouse.y = y
}

@(test)
test_a_row_scrolled_out_of_its_panel_does_not_answer :: proc(t: ^testing.T) {
	hit_test_setup()

	panel := Rectangle{position = {100, 100}, size = {200, 100}, pivot = {0.5, 0.5}} // y 100..200
	row   := Rectangle{position = {100, 180}, size = {200, 40}, pivot = {0.5, 0.5}}  // y 180..220

	put_mouse(150, 210) // on the row, below the panel
	testing.expect(t, is_mouse_over_rect(row), "with no clip the row should answer")

	begin_clip(panel)
	testing.expect(t, !is_mouse_over_rect(row), "the part of the row cut off by the clip answered")

	put_mouse(150, 190) // on the row, inside the panel
	testing.expect(t, is_mouse_over_rect(row), "the visible part of the row did not answer")
	end_clip()

	put_mouse(150, 210)
	testing.expect(t, is_mouse_over_rect(row), "after end_clip the row should answer everywhere again")

	// The plain geometric test ignores the clip, on purpose.
	begin_clip(panel)
	testing.expect(t, is_point_in_rect(get_mouse_position(), row), "is_point_in_rect should not know about the clip")
	end_clip()
}

@(test)
test_nested_clips_answer_only_where_they_overlap :: proc(t: ^testing.T) {
	hit_test_setup()

	outer := Rectangle{position = {0, 0}, size = {300, 300}, pivot = {0.5, 0.5}}
	inner := Rectangle{position = {200, 200}, size = {300, 300}, pivot = {0.5, 0.5}} // 200..500, overlap 200..300
	whole := Rectangle{position = {0, 0}, size = {800, 600}, pivot = {0.5, 0.5}}

	begin_clip(outer)
	begin_clip(inner)

	put_mouse(250, 250)
	testing.expect(t, is_mouse_over_rect(whole), "inside both clips should answer")

	put_mouse(400, 400) // inside the inner clip's own rectangle, outside the outer one
	testing.expect(t, !is_mouse_over_rect(whole), "the inner clip escaped the outer one")

	end_clip()
	end_clip()
}

@(test)
test_the_clip_is_checked_in_window_pixels_under_a_letterbox :: proc(t: ^testing.T) {
	hit_test_setup()

	// A logical screen drawn at twice the size, 40 pixels in from the left.
	mbi.draw_scale  = 2
	mbi.draw_offset = {40, 0}

	panel := Rectangle{position = {10, 10}, size = {100, 50}, pivot = {0.5, 0.5}} // logical 10..110 x 10..60
	begin_clip(panel)
	defer end_clip()

	everything := Rectangle{position = {0, 0}, size = {400, 300}, pivot = {0.5, 0.5}}

	put_mouse(100, 50) // logical, inside the panel
	testing.expect(t, is_mouse_over_rect(everything), "a logical point inside the panel did not answer")

	put_mouse(115, 50) // logical, just right of the panel
	testing.expect(t, !is_mouse_over_rect(everything), "a logical point outside the panel answered")
}
