#+build windows

package matchbox

import "core:testing"

@(test)
meta_parses_all_keys :: proc(t:^testing.T) {
	meta, err, _ := parse_texture_meta("# hi\nppu = 16  # c\r\ncolumns=8\nrows = 4\nframes = 30\n")
	testing.expect_value(t, err, "")
	testing.expect_value(t, meta.pixels_per_unit, 16)
	testing.expect_value(t, meta.columns, 8)
	testing.expect_value(t, meta.rows, 4)
	testing.expect_value(t, meta.frame_count, 30)
}

@(test)
meta_defaults :: proc(t:^testing.T) {
	meta, err, _ := parse_texture_meta("")
	testing.expect_value(t, err, "")
	testing.expect_value(t, meta, default_texture_meta())

	meta, err, _ = parse_texture_meta("columns = 3\nrows = 2")
	testing.expect_value(t, meta.frame_count, 6)
}

@(test)
meta_errors :: proc(t:^testing.T) {
	_, err, line := parse_texture_meta("ppu = 4\nppuu = 5")
	testing.expect(t, err != "")
	testing.expect_value(t, line, 2)

	_, err, line = parse_texture_meta("ppu = zero")
	testing.expect_value(t, line, 1)

	_, err, line = parse_texture_meta("columns = 2\nrows = 2\nframes = 9")
	testing.expect(t, err != "")

	_, err, line = parse_texture_meta("just words")
	testing.expect_value(t, line, 1)
}

// An RGBA image `width` x `height`, transparent, with `filled` cells of a
// `columns` x `rows` grid each given an opaque square `inset` pixels in from its edges
@(private="file")
make_sheet_pixels :: proc(width, height, columns, rows, filled, inset:i32) -> []u8 {
	pixels := make([]u8, width * height * 4, context.temp_allocator)
	cell_width, cell_height := width / columns, height / rows
	for cell in 0..<filled {
		left := (cell % columns) * cell_width
		top := (cell / columns) * cell_height
		for y in top + inset..<top + cell_height - inset {
			for x in left + inset..<left + cell_width - inset {
				pixels[(y * width + x) * 4 + 3] = 255
			}
		}
	}
	return pixels
}

@(test)
guess_finds_a_grid_from_transparent_gaps :: proc(t:^testing.T) {
	defer free_all(context.temp_allocator)

	meta := calculate_guessed_texture_meta(make_sheet_pixels(24, 16, 3, 2, 6, 2), 24, 16)
	testing.expect_value(t, meta, Texture_Meta{pixels_per_unit = 1, columns = 3, rows = 2, frame_count = 6})

	// The last cell empty: still a 3 x 2 grid, but five frames
	meta = calculate_guessed_texture_meta(make_sheet_pixels(24, 16, 3, 2, 5, 2), 24, 16)
	testing.expect_value(t, meta, Texture_Meta{pixels_per_unit = 1, columns = 3, rows = 2, frame_count = 5})

	// Non-square cells
	meta = calculate_guessed_texture_meta(make_sheet_pixels(40, 12, 4, 1, 4, 1), 40, 12)
	testing.expect_value(t, meta, Texture_Meta{pixels_per_unit = 1, columns = 4, rows = 1, frame_count = 4})
}

@(test)
guess_reads_an_edge_to_edge_strip_as_square_frames :: proc(t:^testing.T) {
	defer free_all(context.temp_allocator)

	// Fully opaque, so no gaps: 32 x 8 is four 8 x 8 frames across, 8 x 24 three down
	meta := calculate_guessed_texture_meta(make_sheet_pixels(32, 8, 1, 1, 1, 0), 32, 8)
	testing.expect_value(t, meta, Texture_Meta{pixels_per_unit = 1, columns = 4, rows = 1, frame_count = 4})

	meta = calculate_guessed_texture_meta(make_sheet_pixels(8, 24, 1, 1, 1, 0), 8, 24)
	testing.expect_value(t, meta, Texture_Meta{pixels_per_unit = 1, columns = 1, rows = 3, frame_count = 3})
}

@(test)
guess_leaves_a_plain_picture_as_one_frame :: proc(t:^testing.T) {
	defer free_all(context.temp_allocator)

	// Opaque and not a whole number of squares
	meta := calculate_guessed_texture_meta(make_sheet_pixels(10, 7, 1, 1, 1, 0), 10, 7)
	testing.expect_value(t, meta, default_texture_meta())

	// Two blobs with a gap between them that no even split lands on: columns 0-2
	// and 6-8 of 9. Thirds would leave the middle third empty, so it is one frame
	pixels := make([]u8, 9 * 4 * 4, context.temp_allocator)
	for y in 0..<4 {
		for x in 0..<9 {
			if x <= 2 || x >= 6 do pixels[(y * 9 + x) * 4 + 3] = 255
		}
	}
	testing.expect_value(t, calculate_guessed_texture_meta(pixels, 9, 4), default_texture_meta())

	// Nothing drawn at all
	empty := make([]u8, 16 * 16 * 4, context.temp_allocator)
	testing.expect_value(t, calculate_guessed_texture_meta(empty, 16, 16), default_texture_meta())
}
