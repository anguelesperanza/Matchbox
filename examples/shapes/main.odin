package shapes_example

/*
	Everything matchbox could not draw until now.

	  draw_line / draw_lines            a segment, and a run of them
	  draw_circle / draw_ellipse        filled, or as a ring
	  draw_triangle                     filled, or as an outline
	  sprite.tint / sprite.desaturate   a sprite drawn other than as it was painted
	  get_font                          text at more than one size
	  draw_text_wrapped                 text that is more than one line

	The shapes are cut out of the same unit quad every rect and sprite uses, by
	a distance field in the fragment stage -- so a triangle costs what a rect
	costs, and every `thickness` here is in pixels whatever the shape has been
	scaled or rotated by.

	Worth watching: everything is laid out as a fraction of the window, the
	text included. Resize the window and the words grow with it, which they did
	not before get_font -- the atlas was baked once at 32 pixels and a layout
	written against `mbi.height` had to treat the line height as a constant and
	arrange itself around it.
*/

import "core:math"

import "../../matchbox"

BG    :: [4]f32{0.09, 0.09, 0.11, 1}
PANEL :: [4]f32{0.16, 0.16, 0.21, 1}
DIM   :: [4]f32{0.62, 0.64, 0.72, 1}

RULES ::
	"Both players shuffle their hand, cemetery, and exile into their deck, " +
	"then draw five cards.\n\n" +
	"A card wider than the column it is put in is broken where it runs out " +
	"of room, because there is nowhere else for it to go."

main :: proc() {
	matchbox.init("Shapes", 900, 640)
	defer matchbox.cleanup()

	// One sprite drawn four times over, to show that a tint is a property of
	// the draw rather than of the art.
	card, card_err := matchbox.create_sprite(#load("../ui/art/ember.png"), 1)
	if card_err != nil do return
	defer matchbox.destroy(&card)

	elapsed: f32

	for matchbox.is_running() {
		matchbox.poll_events()
		elapsed += matchbox.get_delta_time()

		w := f32(matchbox.mbi.width)
		h := f32(matchbox.mbi.height)

		// Every size on screen comes off the window, the text included.
		unit  := h / 32
		title := matchbox.get_font(unit * 1.6)
		body  := matchbox.get_font(unit * 1.0)

		matchbox.begin_drawing()
		matchbox.clear_background(BG)

		heading :: proc(font: ^matchbox.Font, text: string, at: [2]f32) {
			matchbox.draw_text(font, text, at.x, at.y + font.ascent, DIM)
		}

		// ---- lines ---------------------------------------------------------
		left := unit * 1.5
		top  := unit * 1.5

		heading(body, "lines", {left, top})

		y := top + unit * 2
		for i in 0 ..< 4 {
			thickness := f32(i) + 1
			matchbox.draw_line(
				{left, y + f32(i) * unit * 1.1},
				{left + unit * 9, y + f32(i) * unit * 1.1},
				matchbox.WHITE, thickness,
			)
		}

		// A run of segments, with the joins rounded over. The wave moves so the
		// corners sharpen and flatten -- a square-ended polyline notches on the
		// outside of a sharp turn, and this is where that would show.
		wave: [9][2]f32
		for &p, i in wave {
			t := f32(i) / f32(len(wave) - 1)
			p = {
				left + t * unit * 9,
				y + unit * 6 + math.sin(t * 6 + elapsed * 2) * unit * 1.6,
			}
		}
		matchbox.draw_lines(wave[:], matchbox.LIME_GREEN, unit * 0.35)

		// ---- circles and triangles ------------------------------------------
		mid := left + unit * 11

		heading(body, "circles, ellipses, triangles", {mid, top})

		cy := top + unit * 4

		matchbox.draw_circle({mid + unit * 2, cy}, unit * 1.8, matchbox.PUMPKIN_ORANGE)
		matchbox.draw_circle_outline({mid + unit * 6.5, cy}, unit * 1.8, matchbox.CORNFLOWER_BLUE, unit * 0.3)

		// Rotating, to show that the ring stays one thickness the whole way
		// round -- which is the thing draw_rect_outline got wrong for years.
		matchbox.draw_ellipse({mid + unit * 11, cy}, {unit * 2.6, unit * 1.4}, matchbox.LIME_GREEN, elapsed)

		ty := cy + unit * 4
		matchbox.draw_triangle(
			{mid, ty}, {mid + unit * 4, ty}, {mid + unit * 2, ty + unit * 3.4},
			matchbox.PUMPKIN_ORANGE,
		)
		matchbox.draw_triangle_outline(
			{mid + unit * 5.5, ty}, {mid + unit * 9.5, ty}, {mid + unit * 7.5, ty + unit * 3.4},
			matchbox.RED, unit * 0.25,
		)

		// ---- sprite tint ----------------------------------------------------
		// The bottom half is two columns: the art on the left, the text on the
		// right. Both are sized off the window, so neither runs into the other
		// as it is resized.
		bottom  := h * 0.50
		gutter  := unit * 1.2
		art_col := w * 0.42

		heading(body, "one sprite, four draws", {left, bottom})

		art_w := (art_col - gutter * 3) / 4
		art_h := art_w * f32(card.height) / f32(card.width)
		art_y := bottom + unit * 2

		tints := [4][4]f32{
			{1, 1, 1, 1},         // as painted
			{0.45, 0.45, 0.5, 1}, // the dim a game used to fake with a rect over the top
			{1, 0.55, 0.55, 1},   // a flash, without a second sprite
			{1, 1, 1, 1},
		}

		for i in 0 ..< 4 {
			shown := card
			shown.position = {left + f32(i) * (art_w + gutter), art_y}
			shown.size     = {art_w, art_h}
			shown.pivot    = {0.5, 0.5}
			shown.tint     = tints[i]

			// The last one greys out and back. A multiply cannot take colour
			// away, only add or subtract it, which is why this is its own number
			// rather than another tint.
			if i == 3 do shown.desaturate = (math.sin(elapsed * 2) + 1) * 0.5

			matchbox.draw_sprite(shown)
		}

		// ---- text -----------------------------------------------------------
		text_x := left + art_col + gutter
		column := w - text_x - unit * 1.5

		matchbox.draw_text(title, "Text at any size", text_x, bottom + title.ascent, matchbox.WHITE)

		// Wrapped to the column. draw_text is one line and has no idea how wide
		// the space it is being put in is, so anything with more to say than fits
		// had nowhere to put the rest.
		rules_y := bottom + title.ascent + title.descent + unit
		used    := matchbox.draw_text_wrapped(body, RULES, {text_x, rules_y}, column, DIM)

		// Which is also how the next thing knows where to go.
		count_y := rules_y + used.y + unit
		label   := "sizes resident: "

		matchbox.draw_text(body, label, text_x, count_y + body.ascent, DIM)
		matchbox.draw_text(body, i64(matchbox.get_font_cache_len()),
			text_x + matchbox.measure_text(body, label).x, count_y + body.ascent, matchbox.WHITE)

		matchbox.end_drawing()
	}
}
