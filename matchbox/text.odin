package matchbox

/*
	Text
	====
	Draws a string as one sprite per glyph, from the atlas of a `Font`.

	Positions are world units with +Y up, like everything else. Through a world
	camera the text moves with the world; between screen_start and screen_end it
	is a HUD:

		font := mb.create_font(mb.DEFAULT_FONT_BYTES, 26, 90)

		mb.screen_start()
		mb.render_text(font, "Score", mb.calculate_anchor_position(.TOP_LEFT, {0.5, -1}))
		mb.screen_end()

	`render_text` takes the left end of the BASELINE, which suits one line. Text that
	wraps goes in a box, so the wrapping procs (`render_text_wrapped`) take the
	TOP-LEFT corner of the box instead.

	Sizes returned and taken are in world units. A line is broken at spaces and at
	any '\n' in the text; a word too long for the width is broken mid-word, since
	running out of the box is the one thing a caller asking for a width did not want.
*/

import "core:math"
import "core:strconv"
import "core:strings"

import "base:intrinsics"

// -----------------------------------------------------------------------
// One line
// -----------------------------------------------------------------------

/*
	A string with its baseline starting at `position` (z is the layer).

	Glyphs are blended sprites, so they sort by z with the rest of the pass and the
	soft edges of the letters blend over whatever is behind them. Characters the
	atlas does not hold (anything outside printable ASCII) are skipped.
*/
render_text_string :: proc(font:Font, text:string, position:[3]f32, color:[4]f32 = {1, 1, 1, 1}) {
	ensure(font.pixels_per_unit > 0, "Font was not created with create_font")

	sprite := Sprite {
		texture = font.texture,
		scale = {1, 1},
		tint = color,
		pivot = {0, 0}, // the bottom left of the glyph sits at `position`
		pixels_per_unit = font.pixels_per_unit,
	}

	// A cursor walks along the baseline in atlas pixels, y down, as stb lays glyphs out
	cursor_x:f32

	for character in text {
		if character < mbi.font_settings.first_glyph || character >= mbi.font_settings.first_glyph + FONT_GLYPH_COUNT {
			continue
		}

		// The glyph's rectangle in the atlas, in pixels from its top left
		baked := font.baked_chars[int(character - mbi.font_settings.first_glyph)]
		sprite.source = {f32(baked.x0), f32(baked.y0), f32(baked.x1 - baked.x0), f32(baked.y1 - baked.y0)}

		// y is down from the baseline and world y is up, so the bottom edge places the sprite
		left, bottom := calculate_glyph_corner(baked, cursor_x)
		cursor_x += baked.xadvance

		sprite.position = {
			position.x + left / font.pixels_per_unit,
			position.y - bottom / font.pixels_per_unit,
			position.z,
		}

		// A glyph with nothing to draw (a space) has an empty rectangle
		if sprite.source[2] > 0 && sprite.source[3] > 0 {
			render_sprite(sprite, .BLENDED)
		}
	}
}

/*
	Where a glyph's box sits for a cursor at `cursor_x` on the baseline, in atlas pixels with y
	down: its left edge, and its bottom edge below the baseline. Worked out as stb's
	GetBakedQuad does it with the OpenGL fill rule -- the top left snapped to a whole pixel, so
	the atlas is sampled pixel for pixel. Written here rather than called so the text code
	needs no baker on the handhelds; text_test.odin checks it against stb on PC
*/
@(private)
calculate_glyph_corner :: proc(glyph:Baked_Glyph, cursor_x:f32) -> (left, bottom:f32) {
	left = math.floor(cursor_x + glyph.xoff + 0.5)
	top := math.floor(glyph.yoff + 0.5) // the cursor's own y is the baseline, 0
	bottom = top + f32(glyph.y1 - glyph.y0)
	return
}

// An integer, without the caller building a string for it. Part of the `render_text` group
render_text_i64 :: proc(font:Font, integer:i64, position:[3]f32, color:[4]f32 = {1, 1, 1, 1}) {
	buffer:[64]u8
	render_text_string(font, strconv.write_int(buffer[:], integer, 10), position, color)
}

// A float at two decimal places. Part of the `render_text` group
render_text_float :: proc(font:Font, value:$T, position:[3]f32, color:[4]f32 = {1, 1, 1, 1}) where intrinsics.type_is_float(T) {
	buffer:[64]u8
	render_text_string(font, format_float(buffer[:], f64(value)), position, color)
}

// Two floats with `separator` between: a position or a size. Part of the `render_text` group
render_text_2_float :: proc(font:Font, value:[2]$T, position:[3]f32, color:[4]f32 = {1, 1, 1, 1}, separator:string = " ") where intrinsics.type_is_float(T) {
	first:[64]u8
	second:[64]u8

	// Temp, not the context allocator: this is a draw call, so a game showing a position
	// every frame would otherwise leak a string a frame. The temp allocator is cleared each frame
	text := strings.concatenate({format_float(first[:], f64(value[0])), separator, format_float(second[:], f64(value[1]))}, context.temp_allocator)
	render_text_string(font, text, position, color)
}

// Two integers with `separator` between. Part of the `render_text` group
render_text_2_i64 :: proc(font:Font, values:[2]i64, position:[3]f32, color:[4]f32 = {1, 1, 1, 1}, separator:string = " ") {
	first:[64]u8
	second:[64]u8

	text := strings.concatenate({strconv.write_int(first[:], values[0], 10), separator, strconv.write_int(second[:], values[1], 10)}, context.temp_allocator)
	render_text_string(font, text, position, color)
}

// Draws a string, an integer, a float or a pair of them, so a game does not build a string
// for a number it wants on screen
render_text :: proc {
	render_text_string,
	render_text_i64,
	render_text_float,
	render_text_2_float,
	render_text_2_i64,
}

// `strconv.write_float` always writes a sign, so 3.14 comes back as "+3.14". Drop it when
// it is a plus and keep it when it is a minus. (Cutting off the first character would
// turn -8.5 into 8.50, which looks right and is wrong.)
@(private)
format_float :: proc(buffer:[]u8, value:f64) -> string {
	text := strconv.write_float(buffer, value, 'f', 2, 64)
	if len(text) > 0 && text[0] == '+' do return text[1:]
	return text
}

// -----------------------------------------------------------------------
// Measuring
// -----------------------------------------------------------------------

/*
	How much room `text` takes on one line, in world units.

	The height is the font's ascent plus descent, not the extent of these glyphs, so
	"Play" and "Play Card" measure the same and a line does not bob as its content changes.
*/
calculate_text_size :: proc(font:Font, text:string) -> [2]f32 {
	width:f32
	for character in text {
		width += rune_advance(font, character)
	}
	return {width, (font.ascent + font.descent) / font.pixels_per_unit}
}

// How far the cursor moves for one character, in world units. Characters the atlas does
// not hold are skipped when drawing, so they take no room here either
@(private)
rune_advance :: proc(font:Font, character:rune) -> f32 {
	if character < mbi.font_settings.first_glyph || character >= mbi.font_settings.first_glyph + FONT_GLYPH_COUNT do return 0
	return font.baked_chars[int(character - mbi.font_settings.first_glyph)].xadvance / font.pixels_per_unit
}

// The distance from one baseline to the next, in world units
calculate_line_height :: proc(font:Font, spacing:f32 = mbi.font_settings.line_spacing) -> f32 {
	return (font.ascent + font.descent) / font.pixels_per_unit * (1 + spacing)
}

/*
	The height of `count` lines. The gap is counted between lines and not after the last,
	so a one line block is as tall as `calculate_text_size` and a block sits flush against
	whatever goes under it
*/
calculate_text_block_height :: proc(font:Font, count:int, spacing:f32 = mbi.font_settings.line_spacing) -> f32 {
	if count <= 0 do return 0

	line := (font.ascent + font.descent) / font.pixels_per_unit
	return f32(count) * line + f32(count - 1) * line * spacing
}

// -----------------------------------------------------------------------
// Wrapping and several lines
// -----------------------------------------------------------------------

/*
	Splits `text` into lines that each fit in `max_width` world units.

	The strings point into `text`; only the slice holding them is allocated, so
	`context.temp_allocator` is the usual thing to pass. A `max_width` of 0 or less means
	no wrapping: the only breaks are the '\n' already in the text.
*/
wrap_text :: proc(font:Font, text:string, max_width:f32, allocator := context.allocator) -> []string {
	lines := make([dynamic]string, allocator)

	remaining := text
	for paragraph in strings.split_lines_iterator(&remaining) {
		// An empty line in the source is a blank line on screen: the only way to ask for a gap
		if max_width <= 0 || len(paragraph) == 0 {
			append(&lines, paragraph)
			continue
		}

		wrap_paragraph(font, paragraph, max_width, &lines)
	}

	return lines[:]
}

@(private)
wrap_paragraph :: proc(font:Font, paragraph:string, max_width:f32, lines:^[dynamic]string) {
	space_width := rune_advance(font, ' ')

	line_start := 0 // byte the line being built starts at
	line_end := 0 // byte just past the last word on it
	width:f32 // how wide that line is so far
	emitted := false

	i := 0
	for i < len(paragraph) {
		// Spaces belong to the gap between words, and a wrapped line never starts with one,
		// which keeps the left edge straight
		for i < len(paragraph) && paragraph[i] == ' ' do i += 1
		if i >= len(paragraph) do break

		word_start := i
		for i < len(paragraph) && paragraph[i] != ' ' do i += 1

		word := paragraph[word_start:i]
		word_width := calculate_text_size(font, word).x
		gap := space_width if line_end > line_start else 0

		// The word does not fit, so the line being built is done
		if line_end > line_start && width + gap + word_width > max_width {
			append(lines, paragraph[line_start:line_end])
			emitted = true

			line_start, line_end = word_start, word_start
			width, gap = 0, 0
		}

		// Still too wide on a line of its own: one word wider than the box. It is broken where
		// it runs out of room
		if line_end == line_start && word_width > max_width {
			chunk := word_start
			run:f32

			for character, offset in word {
				advance := rune_advance(font, character)

				if run + advance > max_width && word_start + offset > chunk {
					append(lines, paragraph[chunk:word_start + offset])
					emitted = true

					chunk = word_start + offset
					run = 0
				}

				run += advance
			}

			// What did not fill a whole line stays on the line being built
			line_start, line_end = chunk, chunk
			width, gap = 0, 0
			word_width = run
		}

		width += gap + word_width
		line_end = i
	}

	if line_end > line_start {
		append(lines, paragraph[line_start:line_end])
	} else if emitted == false {
		// A paragraph of only spaces still takes a line
		append(lines, "")
	}
}

/*
	Draws `text` in a column `max_width` wide, from a top-left corner (z is the layer).

	Returns the space it took, so a panel can be sized to its text or the next thing
	put underneath. The width is the widest line, at most `max_width`:

		used := mb.render_text_wrapped(font, rules, top_left, 6)
		top_left.y -= used.y     // +Y is up, so the next block is lower
*/
render_text_wrapped :: proc(font:Font, text:string, top_left:[3]f32, max_width:f32, color:[4]f32 = {1, 1, 1, 1}, spacing:f32 = mbi.font_settings.line_spacing) -> [2]f32 {
	lines := wrap_text(font, text, max_width, context.temp_allocator)
	return render_text_lines(font, lines, top_left, color, spacing)
}

/*
	Draws lines that are already split, from a top-left corner. For a caller that wrapped
	once and draws the same lines every frame
*/
render_text_lines :: proc(font:Font, lines:[]string, top_left:[3]f32, color:[4]f32 = {1, 1, 1, 1}, spacing:f32 = mbi.font_settings.line_spacing) -> [2]f32 {
	step := calculate_line_height(font, spacing)
	ascent := font.ascent / font.pixels_per_unit
	width:f32

	for line, i in lines {
		// +Y is up, so each line is lower than the one before
		baseline := [3]f32{top_left.x, top_left.y - ascent - f32(i) * step, top_left.z}
		render_text_string(font, line, baseline, color)
		width = max(width, calculate_text_size(font, line).x)
	}

	return {width, calculate_text_block_height(font, len(lines), spacing)}
}

/*How much room `text` takes wrapped to `max_width`, without drawing it. For sizing a
panel before anything goes in it*/
calculate_text_wrapped_size :: proc(font:Font, text:string, max_width:f32, spacing:f32 = mbi.font_settings.line_spacing) -> [2]f32 {
	lines := wrap_text(font, text, max_width, context.temp_allocator)

	width:f32
	for line in lines do width = max(width, calculate_text_size(font, line).x)

	return {width, calculate_text_block_height(font, len(lines), spacing)}
}
