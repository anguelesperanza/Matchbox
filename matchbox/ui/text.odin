#+build windows

package ui

/*
	Text
	====
	One face at whatever sizes are asked for, drawn with Matchbox's fonts.

	**Measured without a GPU, drawn with one.** A size's advances, ascent and descent come from Matchbox's font baking
	(create_font_metrics), which needs no window, so a layout test measures text exactly as the running editor draws it. The
	atlas is made the first time a size is drawn with a device, replacing the measuring-only one.

	**render_text takes a baseline, not a top edge**, so text of different sizes on one line sits on one line. `font.ascent`
	is how far above the baseline the tallest glyph reaches, which is what to take off a top edge.

	**Sizes are units, baked at the UI scale.** get_font(13) at a scale of 2 is a 26 pixel atlas drawn 1:1, not a 13 pixel one
	stretched. The face is Matchbox's default font unless `ui_state.font_settings.bytes` is set to another before the first
	get_font: a pixel font looks right at the sizes it was drawn for.
*/

import "core:math"

import mb ".."

Font_Settings :: struct {
	bytes:        []byte, // the .ttf; Matchbox's default font until a tool sets its own
	size:         f32, // the size default_font hands back
	line_spacing: f32, // extra gap between lines, as a fraction of a line
}

Font :: struct {
	size:    f32, // units
	pixels:  i32, // what it is baked at: `size` times the scale it was asked for at
	ascent:  f32, // units, baseline up to the tallest glyph
	descent: f32, // units, baseline down to the lowest glyph
	face:    mb.Font, // Matchbox's: its texture is empty until the size is first drawn with a device
}

Fonts :: struct {
	cache: map[i32]^Font, // by baked pixel size
}

/*
	The face at `size` units, at the current UI scale. The pointer is good until shutdown: sizes are few, and nothing is evicted
*/
get_font :: proc(size: f32) -> ^Font {
	scale := get_scale()
	pixels := max(i32(math.round(size * scale)), 1)

	if cached, found := ui_state.fonts.cache[pixels]; found do return cached

	font := new(Font)
	font.size = size
	font.pixels = pixels
	font.face = mb.create_font_metrics(ui_state.font_settings.bytes, f32(pixels), scale)
	font.ascent = font.face.ascent / scale
	font.descent = font.face.descent / scale

	ui_state.fonts.cache[pixels] = font
	return font
}

/*The size most of a tool is written in*/
default_font :: proc() -> ^Font {
	return get_font(ui_state.font_settings.size)
}

@(private)
destroy_fonts :: proc(fonts: ^Fonts) {
	for _, font in fonts.cache {
		if font.face.texture.width > 0 do mb.destroy_font(font.face)
		free(font)
	}
	delete(fonts.cache)
	fonts^ = {}
}

/*
	How wide `text` is, and how tall a line is. The height is the font's ascent plus descent rather than these glyphs', so
	"Play" and "Play Card" measure the same height and a line does not shift as its text changes
*/
calculate_text_size :: proc(font: ^Font, text: string) -> [2]f32 {
	return mb.calculate_text_size(font.face, text)
}

/*The height of one line, baseline to baseline*/
calculate_line_height :: proc(font: ^Font, spacing: f32 = -1) -> f32 {
	return mb.calculate_line_height(font.face, spacing if spacing >= 0 else ui_state.font_settings.line_spacing)
}

/*
	The baseline that puts a line of text in the vertical middle of `rectangle`. Text is placed by baseline and centred by its
	ascent plus descent, so a label does not sit higher or lower as its letters change
*/
calculate_baseline_centred :: proc(font: ^Font, rectangle: Rectangle) -> f32 {
	return calculate_rectangle_centre(rectangle).y - (font.ascent - font.descent) * 0.5
}

/*
	Draws `text` with its baseline starting at `position`. Snapped to whole window pixels: a pixel font drawn at a half pixel
	is two grey columns where there should be one black one. (With an odd window height the middle of the screen is a pixel
	centre, which this does not account for.)
*/
render_text :: proc(font: ^Font, text: string, position: [2]f32, color: [4]f32) {
	if len(text) == 0 || !is_drawing() do return

	// Sized for measuring first; the atlas is made now that something is being drawn
	if font.face.texture.width == 0 {
		font.face = mb.create_font(ui_state.font_settings.bytes, f32(font.pixels), get_scale())
	}

	scale := get_scale()
	snapped := [2]f32{math.round(position.x * scale) / scale, math.round(position.y * scale) / scale}
	mb.render_text_string(font.face, text, {snapped.x, snapped.y, 0}, color)
}

/*
	Splits `text` into lines that each fit within `max_width`. The strings point into `text`; only the slice holding them is
	allocated. A word wider than the whole width is broken where it runs out of room, because the alternative is drawing
	outside the box. An empty line in the source stays an empty line. A `max_width` of zero or less breaks only at the newlines
	already there
*/
wrap_text :: proc(font: ^Font, text: string, max_width: f32, allocator := context.allocator) -> []string {
	return mb.wrap_text(font.face, text, max_width, allocator)
}
