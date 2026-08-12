package outline_example

/*
	The two outline procedures, side by side on the shape that made the
	difference visible.

	A 460x52 box is the case from the bug: draw_outline_proportional takes a
	share of each side, so 0.04 puts eighteen pixels down the short edges and
	two along the long ones. draw_outline takes a thickness in pixels and is
	even the whole way round.

	Both are drawn on a square underneath, where they agree -- which is why
	this went unnoticed while the only things using it were square-ish.
*/

import "../../matchbox"

WIDE  :: [2]f32{460, 52}
SQUARE :: [2]f32{160, 160}

main :: proc() {
	matchbox.init("Outlines", 760, 560)
	defer matchbox.cleanup()

	font := &matchbox.mbi.font

	for matchbox.is_running() {
		matchbox.poll_events()
		matchbox.begin_drawing()
		matchbox.clear_background({0.09, 0.09, 0.11, 1})

		matchbox.draw_text(font, "draw_outline -- thickness 4, in pixels", 60, 60, matchbox.WHITE)
		matchbox.draw_outline({380, 110}, WIDE, matchbox.LIME_GREEN, 4, 0)

		matchbox.draw_text(font, "draw_outline_proportional -- 0.04 of each side", 60, 200, matchbox.WHITE)
		matchbox.draw_outline_proportional({380, 250}, WIDE, matchbox.PUMPKIN_ORANGE, 0.04, 0)

		matchbox.draw_text(font, "on a square the two agree", 60, 340, matchbox.WHITE)
		matchbox.draw_outline({230, 440}, SQUARE, matchbox.LIME_GREEN, 6, 0)
		matchbox.draw_outline_proportional({530, 440}, SQUARE, matchbox.PUMPKIN_ORANGE, 0.0375, 0)

		matchbox.end_drawing()
	}
}
