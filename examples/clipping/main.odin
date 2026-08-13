package clipping_example

/*
	A list that scrolls inside a panel instead of paging, which is what the
	clip buys.

	Mouse wheel scrolls. The rows are drawn in full every frame -- all thirty
	of them, most well outside the panel -- and the scissor is the only thing
	stopping them landing on the rest of the screen. Nothing here counts rows
	or works out which ones are visible, which is exactly the bookkeeping
	paging needed.

	The right-hand box nests a second clip inside the first to show that they
	intersect: the inner rectangle is deliberately taller than the outer one,
	and cannot draw past it.
*/

import "core:fmt"

import "../../matchbox"

PANEL   :: matchbox.Rectangle{position = {40, 70}, size = {300, 300}, pivot = {0.5, 0.5}}
INNER   :: matchbox.Rectangle{position = {400, 120}, size = {240, 200}, pivot = {0.5, 0.5}}
OUTER   :: matchbox.Rectangle{position = {380, 70}, size = {280, 300}, pivot = {0.5, 0.5}}

ROW_H   :: 34
ROWS    :: 30

BG      :: [4]f32{0.09, 0.09, 0.11, 1}
PANEL_BG:: [4]f32{0.16, 0.16, 0.20, 1}
STRIPE  :: [4]f32{0.22, 0.22, 0.28, 1}

main :: proc() {
	matchbox.init("Clipping", 720, 440)
	defer matchbox.cleanup()

	font := &matchbox.mbi.font
	scroll: f32 = 0

	for matchbox.is_running() {
		matchbox.poll_events()

		scroll -= matchbox.get_mouse_wheel().y * 30
		max_scroll := f32(ROWS) * ROW_H - PANEL.size.y
		scroll = clamp(scroll, 0, max(0, max_scroll))

		matchbox.begin_drawing()
		matchbox.clear_background(BG)

		// ---- a scrolling list -------------------------------------------
		matchbox.draw_rect({position = PANEL.position, size = PANEL.size,
		                    color = PANEL_BG, pivot = {0.5, 0.5}})

		{
			matchbox.begin_clip(PANEL)
			defer matchbox.end_clip()

			top := matchbox.rect_top_left(PANEL)
			for i in 0 ..< ROWS {
				y := top.y + f32(i) * ROW_H - scroll

				if i % 2 == 0 {
					matchbox.draw_rect({position = {top.x, y}, size = {PANEL.size.x, ROW_H},
					                    color = STRIPE, pivot = {0.5, 0.5}})
				}
				matchbox.draw_text(font, fmt.tprintf("row %d", i), top.x + 12, y + 24, matchbox.WHITE)
			}
		}

		// ---- nested clips intersect --------------------------------------
		matchbox.draw_rect({position = OUTER.position, size = OUTER.size,
		                    color = PANEL_BG, pivot = {0.5, 0.5}})
		{
			matchbox.begin_clip(OUTER)
			defer matchbox.end_clip()

			// Taller than OUTER, and starts above it. Neither edge escapes.
			matchbox.begin_clip(INNER)
			defer matchbox.end_clip()

			matchbox.draw_rect({position = {360, 40}, size = {320, 400},
			                    color = matchbox.PUMPKIN_ORANGE, pivot = {0.5, 0.5}})
		}

		matchbox.draw_text(font, "wheel scrolls the list", 40, 410, matchbox.WHITE)
		matchbox.draw_text(font, "nested clip", 380, 410, matchbox.WHITE)

		matchbox.end_drawing()
	}
}
