#+build windows

package matchbox

import "core:testing"

// A font with no atlas: every glyph is 10 pixels wide to advance, 16 tall,
// and one unit is 10 pixels, so a character is 1 unit wide
test_font :: proc() -> Font {
	font := Font {
		atlas_size = FONT_ATLAS_MIN_SIZE,
		size = 16,
		pixels_per_unit = 10,
		ascent = 12,
		descent = 4,
	}
	for &c in font.baked_chars do c.xadvance = 10
	return font
}

@(test)
measure_is_width_in_units :: proc(t:^testing.T) {
	font := test_font()
	size := measure_text(font, "hello")
	testing.expect_value(t, size.x, 5)
	testing.expect_value(t, size.y, 1.6) // (12 + 4) / 10
}

@(test)
characters_outside_the_atlas_take_no_room :: proc(t:^testing.T) {
	font := test_font()
	testing.expect_value(t, measure_text(font, "a\tb").x, 2) // tab is not in the atlas
	testing.expect_value(t, measure_text(font, "").x, 0)
}

@(test)
wraps_at_spaces :: proc(t:^testing.T) {
	font := test_font()
	lines := wrap_text(font, "aaa bbb ccc", 7, context.temp_allocator)

	testing.expect_value(t, len(lines), 2)
	testing.expect_value(t, lines[0], "aaa bbb") // exactly 7 wide, fits
	testing.expect_value(t, lines[1], "ccc")
}

@(test)
no_width_means_no_wrapping :: proc(t:^testing.T) {
	font := test_font()
	lines := wrap_text(font, "aaa bbb ccc\nddd", 0, context.temp_allocator)

	testing.expect_value(t, len(lines), 2)
	testing.expect_value(t, lines[0], "aaa bbb ccc")
	testing.expect_value(t, lines[1], "ddd")
}

@(test)
keeps_newlines_and_blank_lines :: proc(t:^testing.T) {
	font := test_font()
	lines := wrap_text(font, "aa\n\nbb", 10, context.temp_allocator)

	testing.expect_value(t, len(lines), 3)
	testing.expect_value(t, lines[1], "")
}

@(test)
long_word_is_broken_to_fit :: proc(t:^testing.T) {
	font := test_font()
	lines := wrap_text(font, "abcdefghij", 4, context.temp_allocator)

	testing.expect_value(t, len(lines), 3)
	testing.expect_value(t, lines[0], "abcd")
	testing.expect_value(t, lines[1], "efgh")
	testing.expect_value(t, lines[2], "ij")
}

@(test)
wrapped_line_never_starts_with_a_space :: proc(t:^testing.T) {
	font := test_font()
	lines := wrap_text(font, "aaaa   bbbb", 5, context.temp_allocator)

	testing.expect_value(t, len(lines), 2)
	testing.expect_value(t, lines[1], "bbbb")
}

@(test)
block_height_counts_gaps_between_lines :: proc(t:^testing.T) {
	font := test_font()
	testing.expect_value(t, text_block_height(font, 0), 0)
	testing.expect_value(t, text_block_height(font, 1), measure_text(font, "a").y)
	testing.expect(t, text_block_height(font, 2) > 2 * measure_text(font, "a").y)
}

@(test)
floats_keep_their_minus_sign :: proc(t:^testing.T) {
	buffer:[64]u8
	testing.expect_value(t, format_float(buffer[:], 3.14), "3.14")
	testing.expect_value(t, format_float(buffer[:], -8.5), "-8.50")
}
