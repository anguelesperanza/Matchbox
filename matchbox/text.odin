package matchbox

/*
	Text
	----
	Wrapping and multiple lines, on top of the one-line draw_text.

	`draw_text` is a single line and has no idea how wide the space it is being
	put in is, so anything with more to say than fits has nowhere to put the
	rest. The card game reported a deck's problems as "the first one (and 3
	more)" and sent the remainder to the console, partly for want of this.

	Everything here takes a **top-left**, not a baseline, unlike draw_text. Text
	that wraps is being fitted into a box rather than typeset onto a line, and
	the box is the thing the caller has. The first baseline is worked out from
	the font's ascent.

	Lines are broken at spaces, and at any '\n' already in the text. A single
	word too long for the width is broken mid-word rather than allowed to run
	out of the box -- there is nowhere else for it to go, and silently
	overflowing is the one outcome a caller asking for a width did not want.
*/

import "core:strings"

// Extra room between one baseline and the next, as a share of the line height.
// A little over single spacing, which is what a paragraph of body text wants.


/*
	Splits `text` into lines that each fit within `max_width`.

	The strings point into `text` and allocate nothing themselves; only the
	slice holding them is allocated. `context.temp_allocator` is the usual thing
	to pass, since the result is almost always drawn and then dropped.

	A `max_width` of zero or less means no wrapping, and the only breaks are the
	'\n' already in the text.
*/
wrap_text :: proc(font: ^Font, text: string, max_width: f32, allocator := context.allocator) -> []string {
	lines := make([dynamic]string, allocator)

	remaining := text
	for paragraph in strings.split_lines_iterator(&remaining) {
		// An empty line in the source is a blank line on screen, not something
		// to be closed up -- it is the only way a caller can ask for a gap.
		if max_width <= 0 || len(paragraph) == 0 {
			append(&lines, paragraph)
			continue
		}

		wrap_paragraph(font, paragraph, max_width, &lines)
	}

	return lines[:]
}

@(private)
wrap_paragraph :: proc(font: ^Font, paragraph: string, max_width: f32, lines: ^[dynamic]string) {
	space_width := rune_advance(font, ' ')

	line_start := 0   // byte offset the line being built starts at
	line_end   := 0   // byte offset just past the last word put on it
	width:      f32   // how wide that line is so far
	emitted    := false

	i := 0
	for i < len(paragraph) {
		// Spaces belong to the gap between words rather than to either of them,
		// and a wrapped line never begins with one -- that is what keeps the left
		// edge of a paragraph straight.
		for i < len(paragraph) && paragraph[i] == ' ' do i += 1
		if i >= len(paragraph) do break

		word_start := i
		for i < len(paragraph) && paragraph[i] != ' ' do i += 1

		word       := paragraph[word_start:i]
		word_width := measure_text(font, word).x
		gap        := space_width if line_end > line_start else 0

		// The word does not fit on the line being built, so that line is done.
		if line_end > line_start && width + gap + word_width > max_width {
			append(lines, paragraph[line_start:line_end])
			emitted = true

			line_start, line_end = word_start, word_start
			width, gap = 0, 0
		}

		// Still too wide with a line to itself: one word wider than the whole
		// box. It is broken where it runs out of room, because the alternative
		// is drawing outside the box the caller asked to stay inside.
		if line_end == line_start && word_width > max_width {
			chunk := word_start
			run:   f32

			for ch, offset in word {
				advance := rune_advance(font, ch)

				if run + advance > max_width && word_start + offset > chunk {
					append(lines, paragraph[chunk:word_start + offset])
					emitted = true

					chunk = word_start + offset
					run   = 0
				}

				run += advance
			}

			// What did not fill a whole line stays on the line being built.
			line_start, line_end = chunk, chunk
			width, gap           = 0, 0
			word_width           = run
		}

		width   += gap + word_width
		line_end = i
	}

	if line_end > line_start {
		append(lines, paragraph[line_start:line_end])
	} else if !emitted {
		// A paragraph of nothing but spaces still occupied a line in the source
		// and still occupies one on screen.
		append(lines, "")
	}
}

// How far the cursor moves for one character. Characters the atlas does not
// hold are skipped by draw_text, so they take no room here either.
@(private)
rune_advance :: proc(font: ^Font, ch: rune) -> f32 {
	if ch < FONT_FIRST_GLYPH || ch >= FONT_FIRST_GLYPH + FONT_GLYPH_COUNT do return 0
	return font.baked_chars[int(ch) - FONT_FIRST_GLYPH].xadvance
}

// The height of one line, baseline to baseline.
line_height :: proc(font: ^Font, spacing: f32 = FONT_DEFAULTS.line_spacing) -> f32 {
	return (font.ascent + font.descent) * (1 + spacing)
}

/*
	Draws `text` into a column `max_width` wide, from a top-left corner.

	Returns the space it took, so a panel can be sized to its contents or the
	next thing can be put underneath it:

		used := matchbox.draw_text_wrapped(font, rules, {x, y}, 300, matchbox.WHITE)
		matchbox.draw_text_wrapped(font, flavour, {x, y + used.y}, 300, DIM)

	The width returned is the widest line, which is at most `max_width` and is
	usually less -- it is what the text actually occupied, not what it was
	allowed.
*/
draw_text_wrapped :: proc(
	font:      ^Font,
	text:      string,
	top_left:  [2]f32,
	max_width: f32,
	color:     [4]f32 = WHITE,
	spacing:   f32 = FONT_DEFAULTS.line_spacing,
) -> [2]f32 {
	lines := wrap_text(font, text, max_width, context.temp_allocator)
	return draw_text_lines(font, lines, top_left, color, spacing)
}

/*
	Draws lines that have already been split, from a top-left corner.

	For a caller that wrapped once and wants to draw the same result every
	frame, or that split the text on something wrap_text does not know about.
*/
draw_text_lines :: proc(
	font:     ^Font,
	lines:    []string,
	top_left: [2]f32,
	color:    [4]f32 = WHITE,
	spacing:  f32 = FONT_DEFAULTS.line_spacing,
) -> [2]f32 {
	step  := line_height(font, spacing)
	width: f32

	for line, i in lines {
		y := top_left.y + f32(i) * step + font.ascent
		draw_text(font, line, top_left.x, y, color)
		width = max(width, measure_text(font, line).x)
	}

	return {width, text_block_height(font, len(lines), spacing)}
}

/*
	How much room `text` takes when wrapped to `max_width`, without drawing it.

	For laying a panel out before anything goes in it -- a tooltip sizing its
	plate, a dialog sizing itself to its message.
*/
measure_text_wrapped :: proc(font: ^Font, text: string, max_width: f32, spacing: f32 = FONT_DEFAULTS.line_spacing) -> [2]f32 {
	lines := wrap_text(font, text, max_width, context.temp_allocator)

	width: f32
	for line in lines do width = max(width, measure_text(font, line).x)

	return {width, text_block_height(font, len(lines), spacing)}
}

/*
	The height of `count` lines.

	The gap between lines is counted between them and not after the last one, so
	a one line block is exactly as tall as a one line measure_text and a block
	sits flush against whatever is put under it.
*/
text_block_height :: proc(font: ^Font, count: int, spacing: f32 = FONT_DEFAULTS.line_spacing) -> f32 {
	if count <= 0 do return 0

	line := font.ascent + font.descent
	return f32(count) * line + f32(count - 1) * line * spacing
}
