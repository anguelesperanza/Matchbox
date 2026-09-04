package layout_example

/*
	A menu column laid out by a cursor, and a card grid that refits itself to
	whatever width it is given.

	**Resize the window.** The grid is the point: it was the arithmetic that
	stopped a card layout picked on a 1920x1080 monitor from running off the
	edge of a 13 inch laptop. Narrow the window and the column count drops and
	the cards resize to fill the width exactly, rather than being clipped or
	leaving a ragged margin.

	The grid is drawn inside a clip, so a grid taller than its area scrolls
	instead of spilling. grid_height is what the scroll is measured against.
*/

import "core:fmt"

import "../../matchbox"

CARDS   :: 18
CARD    :: [2]f32{130, 180} // the size we would like; the grid decides the real one
GAP     :: 10

PANEL   :: [4]f32{0.20, 0.20, 0.26, 1}
CARD_BG :: [4]f32{0.30, 0.34, 0.44, 1}

main :: proc() {
	matchbox.init("Layout", 900, 560)
	defer matchbox.cleanup()

	font   := &matchbox.mbi.font
	scroll: f32 = 0
	picked := -1

	for matchbox.is_running() {
		matchbox.poll_events()

		matchbox.begin_drawing()
		matchbox.clear_background({0.09, 0.09, 0.11, 1})

		// ---- the menu column ---------------------------------------------
		// Rebuilt every frame. The cursor holds no state between them, which
		// is the point: there is nothing to keep in sync.
		l := matchbox.create_layout({24, 24}, 190, 8)

		matchbox.layout_text(&l, font, "Deck")
		matchbox.layout_space(&l, 6)

		for name, i in ([]string{"All cards", "Owned", "Favourites"}) {
			rect := matchbox.layout_next(&l, 40)
			rect.color = PANEL

			style := matchbox.BUTTON_STYLE
			style.align = .LEFT

			if matchbox.button(rect, name, style) do picked = -1
		}

		matchbox.layout_space(&l, 14)

		// Narrower than the column, so centred in it
		narrow := matchbox.layout_next(&l, 34, 120)
		narrow.color = PANEL
		if matchbox.button(narrow, "Done") do picked = -1

		matchbox.layout_space(&l, 14)
		matchbox.layout_text(&l, font, fmt.tprintf("picked %d", picked))

		// ---- the grid ----------------------------------------------------
		area := matchbox.Rectangle{
			position = {236, 24},
			size     = {f32(matchbox.mbi.width) - 260, f32(matchbox.mbi.height) - 48},
			pivot    = {0.5, 0.5},
		}

		matchbox.draw_rect({position = area.position, size = area.size,
		                    color = {0.13, 0.13, 0.17, 1}, pivot = {0.5, 0.5}})

		inner := area
		inner.position += {GAP, GAP}
		inner.size     -= {GAP * 2, GAP * 2}

		grid := matchbox.create_grid(inner, CARD, CARDS, GAP)

		scroll -= matchbox.get_mouse_wheel().y * 40
		scroll = clamp(scroll, 0, max(0, matchbox.grid_height(grid) - inner.size.y))

		{
			matchbox.begin_clip(area)
			defer matchbox.end_clip()

			for i in 0 ..< CARDS {
				cell := matchbox.grid_cell(grid, i)
				cell.position.y -= scroll
				cell.color = CARD_BG

				if matchbox.button(cell, fmt.tprintf("%d", i + 1)) do picked = i
			}
		}

		matchbox.draw_text(font,
			fmt.tprintf("%d cols  %.0fx%.0f  (asked %.0fx%.0f)",
				grid.cols, grid.item.x, grid.item.y, CARD.x, CARD.y),
			236, f32(matchbox.mbi.height) - 12, matchbox.WHITE)

		matchbox.end_drawing()
	}
}
