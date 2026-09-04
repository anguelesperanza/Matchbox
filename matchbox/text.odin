package matchbox

/*
	Text
	----
	Everything that puts glyphs on screen, and measures them before it does.

	`font.odin` is the other half: it bakes a TTF into an atlas and keeps a few
	sizes of the default one. Nothing there draws. Everything here does, or
	measures what drawing would take.

	Two coordinate spaces, and the difference is the whole reason there are two
	families. `draw_text` is in world coordinates -- it moves with the camera
	and scales with the letterbox. `draw_text_ui` is in window pixels, so a HUD
	stays put and the font draws at the size it was baked at.

	The wrapping half sits on top of the one-line `draw_text`, which has no idea
	how wide the space it is being put in is. Everything wrapped takes a
	**top-left**, not a baseline: text that wraps is being fitted into a box
	rather than typeset onto a line, and the box is what the caller has. The
	first baseline is worked out from the font's ascent.

	Lines are broken at spaces, and at any '\n' already in the text. A single
	word too long for the width is broken mid-word rather than allowed to run
	out of the box -- there is nowhere else for it to go, and silently
	overflowing is the one outcome a caller asking for a width did not want.
*/

import "core:strconv"
import "core:strings"

import "base:intrinsics"

import stbtt "vendor:stb/truetype"

// -----------------------------------------------------------------------
// One line
// -----------------------------------------------------------------------

@(private)
trim_plus :: proc(s: string) -> string {
	return s[1:] if len(s) > 0 && s[0] == '+' else s
}

// An integer, without the caller building a string for it. Part of the
// `draw_text` group.
draw_text_i64 :: proc(font: ^Font, integer: i64, x: f32, y: f32, color: [4]f32) {
    buf: [256]u8
    result := strconv.write_int(buf[:], integer, 10)
    draw_text_string(font, result[:], x, y, color)
}

/*
	`strconv.write_float`'s leading sign, dropped when it is a plus and kept
	when it is a minus.

	`write_float` always writes a sign, so "3.14" comes back as "+3.14" and has
	to be trimmed. Trimming it as `result[1:]` is the obvious thing and it is
	wrong: it takes whichever character is first, so -8.5 draws as "8.50". On a
	position readout that is half the values on screen rendering as their own
	mirror image, with nothing on screen to say so.
*/

draw_text_2_i64 :: proc(font: ^Font, integers:[2]i64, x:f32, y:f32, color:[4]f32, separator:string = " ") {

	buf_one: [256]u8
	buf_two: [256]u8

	result_one := strconv.write_int(buf_one[:], integers[0], 10)
	result_two := strconv.write_int(buf_two[:], integers[1], 10)

	// Temp, not the context allocator: this is a draw call, so a game showing a
	// position every frame would otherwise leak a string per frame forever. The
	// temp allocator is reset at the end of the frame, which is exactly as long
	// as the text needs to live.
	text, _ := strings.concatenate({trim_plus(result_one), separator, trim_plus(result_two)},context.temp_allocator)

	draw_text_string(font = font, text = text, x = x, y = y, color = color)
}

// Two floats separated by `separator` -- a position or a size, without the
// caller building a string for it. Part of the `draw_text` group.
draw_text_2_float :: proc(font: ^Font, float: [2]$T, x: f32, y: f32, color: [4]f32, separator: string = " ") {
	buf_one: [256]u8
	buf_two: [256]u8

	result_one := strconv.write_float(buf_one[:], cast(f64)float[0], 'f', 2, 64)
	result_two := strconv.write_float(buf_two[:], cast(f64)float[1], 'f', 2, 64)

	// Temp, not the context allocator: this is a draw call, so a game showing a
	// position every frame would otherwise leak a string per frame forever. The
	// temp allocator is reset at the end of the frame, which is exactly as long
	// as the text needs to live.
	text, _ := strings.concatenate({trim_plus(result_one), separator, trim_plus(result_two)},
		context.temp_allocator)

	draw_text_string(font = font, text = text, x = x, y = y, color = color)
}



// A float at two decimal places, without the caller building a string. Part of
// the `draw_text` group.
draw_text_float :: proc(font: ^Font, float: $T, x: f32, y: f32, color: [4]f32) where intrinsics.type_is_float(T) {
    buf: [256]u8
    result := strconv.write_float(buf[:], cast(f64)float, 'f', 2, 64)
    draw_text_string(font, trim_plus(result), x, y, color)
}


// A string at a position, in world coordinates -- so it moves with the camera
// and scales with the letterbox. `draw_text_ui` is the one that does not.
//
// `x` and `y` are the left end of the baseline, not the top-left corner.
draw_text_string :: proc(font: ^Font, text: string, x: f32, y: f32, color: [4]f32) {
	// Bound once for the whole string. The pipeline, the shared quad and the
	// atlas are the same for every character in it -- only the uniforms differ.
	if !bind_quad_state(mbi.renderer.pipelines.font, font.texture, font.sampler) do return

	// Once for the whole string, not once per glyph. A pushed uniform block stays
	// in force for every draw after it until something pushes over it, and the
	// colour is the same for every character -- so this was the same sixteen
	// bytes handed over twenty times for a twenty character line.
	frag_data := Font_Frag_Data{color = color}
	push_frag_uniform(&frag_data, size_of(frag_data))

	cursor_x := x
	cursor_y := y

	for ch in text {
		if ch < FONT_FIRST_GLYPH || ch >= FONT_FIRST_GLYPH + FONT_GLYPH_COUNT {
			continue
		}

		q: stbtt.aligned_quad
		stbtt.GetBakedQuad(raw_data(font.baked_chars[:]), font.atlas_size, font.atlas_size, cast(i32)ch - FONT_FIRST_GLYPH, &cursor_x, &cursor_y, &q, true)

		pos  := [2]f32{(q.x0 + q.x1) * 0.5, (q.y0 + q.y1) * 0.5}
		size := [2]f32{q.x1 - q.x0, q.y1 - q.y0}

		vert_data := Vert_Data{
			position = screen_pos(pos),
			size     = screen_size(size),
			screen   = get_screen_dims(),
			uv_min   = {q.s0, q.t0},
			uv_max   = {q.s1, q.t1},
		}

		push_quad(&vert_data, nil, 0)
	}
}

// Draws a string, an integer or a float, so a game does not build a string for
// a number it wants on screen.
draw_text :: proc {
	draw_text_string,
	draw_text_i64,
	draw_text_float,
	draw_text_2_float,
}

// How much room `text` takes up when drawn with draw_text.
//
// The height is the font's ascent plus descent rather than the extent of these
// particular glyphs, so "Play" and "Play Card" measure the same height and a
// line of text does not shift about vertically as its content changes.
measure_text :: proc(font: ^Font, text: string) -> [2]f32 {
	width: f32
	for ch in text {
		if ch < FONT_FIRST_GLYPH || ch >= FONT_FIRST_GLYPH + FONT_GLYPH_COUNT {
			continue
		}
		width += font.baked_chars[cast(int)ch - FONT_FIRST_GLYPH].xadvance
	}
	return {width, font.ascent + font.descent}
}

// Screen-space text — coordinates and glyph size are in actual window pixels,
// draw_scale is NOT applied.  Use this for HUD / UI text when set_logical_size
// is active, so the font renders at its native baked size instead of being
// upscaled by the logical-resolution multiplier.
draw_text_ui_string :: proc(font: ^Font, text: string, x: f32, y: f32, color: [4]f32) {
	// Bound once for the whole string, as in draw_text_string, and the colour
	// pushed once for the same reason.
	if !bind_quad_state(mbi.renderer.pipelines.font, font.texture, font.sampler) do return

	frag_data := Font_Frag_Data{color = color}
	push_frag_uniform(&frag_data, size_of(frag_data))

	cursor_x := x
	cursor_y := y

	for ch in text {
		if ch < FONT_FIRST_GLYPH || ch >= FONT_FIRST_GLYPH + FONT_GLYPH_COUNT {
			continue
		}

		q: stbtt.aligned_quad
		stbtt.GetBakedQuad(raw_data(font.baked_chars[:]), font.atlas_size, font.atlas_size, cast(i32)ch - FONT_FIRST_GLYPH, &cursor_x, &cursor_y, &q, true)

		pos  := [2]f32{(q.x0 + q.x1) * 0.5, (q.y0 + q.y1) * 0.5}
		size := [2]f32{q.x1 - q.x0, q.y1 - q.y0}

		// No screen_pos / screen_size here: that is what makes this the UI
		// variant, drawing at the font's baked size in window pixels.
		vert_data := Vert_Data{
			position = pos,
			size     = size,
			screen   = get_screen_dims(),
			uv_min   = {q.s0, q.t0},
			uv_max   = {q.s1, q.t1},
		}

		push_quad(&vert_data, nil, 0)
	}
}

// An integer in screen coordinates. Part of the `draw_text_ui` group.
draw_text_ui_int :: proc(font: ^Font, integer: i64, x: f32, y: f32, color: [4]f32) {
    buf: [256]u8
    result := strconv.write_int(buf[:], integer, 10)
    draw_text_ui_string(font, result[:], x, y, color)
}

// A float in screen coordinates, two decimal places. Part of the
// `draw_text_ui` group.
draw_text_ui_f32 :: proc(font: ^Font, float: f32, x: f32, y: f32, color: [4]f32) {
    buf: [256]u8
    result := strconv.write_float(buf[:], cast(f64)float, 'f', 2, 64)
    draw_text_ui_string(font, trim_plus(result), x, y, color)
}

// `draw_text`, but in screen coordinates: fixed to the window and untouched by
// the camera. What a HUD, a score or a debug readout wants.
draw_text_ui :: proc {
    draw_text_ui_string,
    draw_text_ui_int,
    draw_text_ui_f32,
}

// -----------------------------------------------------------------------
// Wrapping and multiple lines
// -----------------------------------------------------------------------


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
