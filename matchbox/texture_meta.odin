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

	A missing file means: ppu 1, one frame. An image with no file that is then
	animated gets a guessed grid instead (calculate_guessed_texture_meta below).
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

/*
	A best guess at how a sheet with no .meta file is laid out, from its pixels
	(RGBA, 8 bits a channel, `width * 4` bytes a row). A .meta file always wins
	over this; it is what an image gets when it is animated without one.

	Two guesses, in order:

	1. Transparent gaps. Frames that do not touch their cell's edge leave fully
	   transparent pixel columns and rows between them. The finest even grid
	   whose every cell edge lands on such a gap, with something drawn in every
	   column and row of cells, is taken. This is what sheetpack's sheets look
	   like, and it reads shia.png as the 13 x 13 its .meta says.
	2. A strip of square frames. Art that runs edge to edge leaves no gaps, so an
	   image a whole number of times wider than it is tall is read as one row of
	   square frames (or one column, the other way round).

	Without either, one frame. Trailing empty cells (a last row half filled) are
	not counted as frames. `ppu` is the frame's height, as sheetpack writes it,
	so a guessed sheet comes out the same size as a packed one.

	Not used on images that are only drawn, never animated: a wrong guess there
	would crop a plain picture -- a background with gaps in it -- to its first cell.
*/
@(private)
calculate_guessed_texture_meta :: proc(pixels:[]u8, width, height:i32) -> Texture_Meta {
	meta := default_texture_meta()
	if width <= 0 || height <= 0 || len(pixels) < int(width * height * 4) {
		return meta
	}

	// Which pixel columns and rows have anything in them (alpha above 0)
	column_used := make([]bool, width, context.temp_allocator)
	row_used := make([]bool, height, context.temp_allocator)
	for y in 0..<height {
		for x in 0..<width {
			if pixels[(y * width + x) * 4 + 3] > 0 {
				column_used[x] = true
				row_used[y] = true
			}
		}
	}

	meta.columns = calculate_gap_divisions(column_used)
	meta.rows = calculate_gap_divisions(row_used)

	if meta.columns == 1 && meta.rows == 1 {
		if width > height && width % height == 0 {
			meta.columns = width / height
		} else if height > width && height % width == 0 {
			meta.rows = height / width
		}
	}

	// Count frames up to the last cell with something in it
	cell_width := width / meta.columns
	cell_height := height / meta.rows
	meta.frame_count = 1
	for cell in 0..<meta.columns * meta.rows {
		left := (cell % meta.columns) * cell_width
		top := (cell / meta.columns) * cell_height
		if is_cell_drawn(pixels, width, left, top, cell_width, cell_height) {
			meta.frame_count = cell + 1
		}
	}

	if meta.columns * meta.rows > 1 {
		meta.pixels_per_unit = f32(cell_height)
	}
	return meta
}

// How many equal pieces the line splits into along transparent gaps: the most
// pieces such that no drawn run crosses a piece's edge and every piece has
// something in it. 1 when there is no such split.
@(private="file")
calculate_gap_divisions :: proc(used:[]bool) -> i32 {
	length := len(used)
	best := 1
	for count in 2..=length {
		if length % count != 0 do continue
		size := length / count

		fits := true
		for piece in 0..<count {
			// The edge before this piece: a drawn pixel on both sides means art crosses it
			edge := piece * size
			if piece > 0 && used[edge - 1] && used[edge] {
				fits = false
				break
			}
			drawn := false
			for i in edge..<edge + size {
				if used[i] {
					drawn = true
					break
				}
			}
			if drawn == false {
				fits = false
				break
			}
		}
		if fits do best = count
	}
	return i32(best)
}

@(private="file")
is_cell_drawn :: proc(pixels:[]u8, width, left, top, cell_width, cell_height:i32) -> bool {
	for y in top..<top + cell_height {
		for x in left..<left + cell_width {
			if pixels[(y * width + x) * 4 + 3] > 0 do return true
		}
	}
	return false
}
