package matchbox

/*
	Texture meta
	============
	Reads the small text file that can sit next to an image: `name.meta`.
	Shared by all targets: it only parses text.

	Example (meme_cat.meta):

		# lines starting with # are comments
		ppu     = 100   # image pixels per world unit
		columns = 2     # frames across
		rows    = 2     # frames down
		frames  = 4     # optional: how many of the columns * rows cells are used

	A missing file means: ppu 1, one frame.
*/

import "core:strings"
import "core:strconv"

Texture_Meta :: struct {
	pixels_per_unit:f32,
	columns:i32,
	rows:i32,
	frame_count:i32,
}

/*What a texture with no .meta file gets*/
default_texture_meta :: proc() -> Texture_Meta {
	return Texture_Meta{pixels_per_unit = 1, columns = 1, rows = 1, frame_count = 1}
}

/*Parses the text of a .meta file. On a problem `error` says what and `line` says where (1 = first line)*/
parse_texture_meta :: proc(text:string) -> (meta:Texture_Meta, error:string, line:int) {
	meta = default_texture_meta()
	frames_given := false

	rest := text
	for raw_line in strings.split_lines_iterator(&rest) {
		line += 1

		// Cut off a comment, then the spaces around what is left
		content := raw_line
		if hash := strings.index_byte(content, '#'); hash >= 0 {
			content = content[:hash]
		}
		content = strings.trim_space(content)
		if len(content) == 0 {
			continue
		}

		equals := strings.index_byte(content, '=')
		if equals < 0 {
			return meta, "expected `name = value`", line
		}
		key := strings.trim_space(content[:equals])
		value := strings.trim_space(content[equals + 1:])

		switch key {
		case "ppu":
			number, ok := strconv.parse_f32(value)
			if ok == false || number <= 0 {
				return meta, "ppu must be a number above 0", line
			}
			meta.pixels_per_unit = number

		case "columns":
			number, ok := strconv.parse_int(value, 10)
			if ok == false || number < 1 {
				return meta, "columns must be a whole number of 1 or more", line
			}
			meta.columns = i32(number)

		case "rows":
			number, ok := strconv.parse_int(value, 10)
			if ok == false || number < 1 {
				return meta, "rows must be a whole number of 1 or more", line
			}
			meta.rows = i32(number)

		case "frames":
			number, ok := strconv.parse_int(value, 10)
			if ok == false || number < 1 {
				return meta, "frames must be a whole number of 1 or more", line
			}
			meta.frame_count = i32(number)
			frames_given = true

		case:
			return meta, "unknown name (expected ppu, columns, rows or frames)", line
		}
	}

	// Without `frames`, every cell of the grid is a frame
	if frames_given == false {
		meta.frame_count = meta.columns * meta.rows
	}
	if meta.frame_count > meta.columns * meta.rows {
		return meta, "frames is more than columns * rows", 0
	}

	line = 0
	return
}
