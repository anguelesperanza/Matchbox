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
