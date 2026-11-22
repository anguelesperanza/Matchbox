package sheetpack

/*
	sheetpack -- packs a folder of frame images into one sprite sheet

	Every frame must be the same size. Frames are put in a grid, left to right
	and then down, in "natural" file name order (frame2 comes before frame10).
	Next to the sheet it writes a `.meta` file that Matchbox reads (see
	matchbox/texture_meta.odin).

	Usage:
	  sheetpack -o assets/images/hero.png -ppu 256 path/to/frames

	Also make a smaller sheet for the 3DS and/or the Vita (same grid, so frame
	numbers match):
	  sheetpack -o assets/images/hero.png -ppu 256 -3ds assets/3ds/images/hero.png -3ds-frame 64 path/to/frames
	  sheetpack -o assets/images/hero.png -ppu 256 -vita assets/vita/images/hero.png -vita-frame 128 path/to/frames

	Options:
	  -o <file.png>     the sheet to write (required)
	  -ppu <number>     image pixels per world unit, written to the .meta (default 1)
	  -columns <n>      frames per row (default: the smallest square-ish grid)
	  -3ds <file.png>   also write a 3DS sheet here (needs -3ds-frame)
	  -3ds-frame <n>    height in pixels of one frame on the 3DS sheet
	  -vita <file.png>  also write a Vita sheet here (needs -vita-frame)
	  -vita-frame <n>   height in pixels of one frame on the Vita sheet
	  -list             print each frame's number and file name
	  -h                this help
*/

import "core:fmt"
import "core:image"
import "core:image/png"
import "core:math"
import "core:mem"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strconv"
import "core:strings"

MAX_SHEET_SIDE :: 16384 // the most D3D11 accepts
MAX_3DS_SIDE   :: 1024  // the most the 3DS GPU accepts
MAX_VITA_SIDE  :: 4096  // the most the Vita GPU (GXM) accepts

Frame :: struct {
	name:   string, // file name, without the folder
	path:   string,
	pixels: []u8,   // RGBA, width * height * 4
}

fail :: proc(format: string, args: ..any) -> ! {
	fmt.eprintf("sheetpack: ")
	fmt.eprintfln(format, ..args)
	os.exit(1)
}

main :: proc() {
	args := os.args[1:]

	folder, output, output_3ds, output_vita: string
	ppu: f64 = 1
	columns := 0
	frame_3ds := 0
	frame_vita := 0
	list_frames := false

	i := 0
	for i < len(args) {
		arg := args[i]
		switch arg {
		case "-h", "--help":
			print_usage()
			os.exit(0)
		case "-o":
			i += 1
			output = option_value(args, i, arg)
		case "-3ds":
			i += 1
			output_3ds = option_value(args, i, arg)
		case "-vita":
			i += 1
			output_vita = option_value(args, i, arg)
		case "-ppu":
			i += 1
			number, ok := strconv.parse_f64(option_value(args, i, arg))
			if ok == false || number <= 0 {
				fail("-ppu needs a number above 0")
			}
			ppu = number
		case "-columns":
			i += 1
			number, ok := strconv.parse_int(option_value(args, i, arg), 10)
			if ok == false || number < 1 {
				fail("-columns needs a whole number of 1 or more")
			}
			columns = number
		case "-3ds-frame":
			i += 1
			number, ok := strconv.parse_int(option_value(args, i, arg), 10)
			if ok == false || number < 1 {
				fail("-3ds-frame needs a whole number of 1 or more")
			}
			frame_3ds = number
		case "-vita-frame":
			i += 1
			number, ok := strconv.parse_int(option_value(args, i, arg), 10)
			if ok == false || number < 1 {
				fail("-vita-frame needs a whole number of 1 or more")
			}
			frame_vita = number
		case "-list":
			list_frames = true
		case:
			if strings.has_prefix(arg, "-") {
				fail("unknown option %s (try -h)", arg)
			}
			if folder != "" {
				fail("only one frames folder is allowed (got '%s' and '%s')", folder, arg)
			}
			folder = arg
		}
		i += 1
	}

	if folder == "" || output == "" {
		print_usage()
		os.exit(1)
	}
	if output_3ds != "" && frame_3ds == 0 {
		fail("-3ds needs -3ds-frame")
	}
	if frame_3ds != 0 && output_3ds == "" {
		fail("-3ds-frame needs -3ds")
	}
	if output_vita != "" && frame_vita == 0 {
		fail("-vita needs -vita-frame")
	}
	if frame_vita != 0 && output_vita == "" {
		fail("-vita-frame needs -vita")
	}

	frames, frame_width, frame_height := load_frames(folder)
	count := len(frames)

	if columns == 0 {
		columns = int(math.ceil(math.sqrt(f64(count))))
	}
	columns = min(columns, count)
	rows := (count + columns - 1) / columns

	if list_frames == true {
		for frame, index in frames {
			fmt.printfln("%4d  %s", index, frame.name)
		}
	}

	// ---- The PC sheet ----
	sheet_width := columns * frame_width
	sheet_height := rows * frame_height
	if sheet_width > MAX_SHEET_SIDE || sheet_height > MAX_SHEET_SIDE {
		fail("the sheet would be %dx%d; the limit is %d. Use more -columns or smaller frames", sheet_width, sheet_height, MAX_SHEET_SIDE)
	}

	sheet := build_sheet(frames, frame_width, frame_height, columns, rows)
	write_png(output, sheet, sheet_width, sheet_height)
	write_meta(output, ppu, columns, rows, count, frame_width, frame_height)
	fmt.printfln("%d frames of %dx%d -> %dx%d grid, %dx%d pixels: %s", count, frame_width, frame_height, columns, rows, sheet_width, sheet_height, output)

	// ---- The smaller sheets ----
	if output_3ds != "" {
		write_scaled_sheet("3DS", output_3ds, MAX_3DS_SIDE, frame_3ds, frames, frame_width, frame_height, columns, rows, ppu)
	}
	if output_vita != "" {
		write_scaled_sheet("Vita", output_vita, MAX_VITA_SIDE, frame_vita, frames, frame_width, frame_height, columns, rows, ppu)
	}
}

/*Writes a sheet for a target with smaller frames, on the same grid so frame
numbers match. `ppu` is scaled by the same ratio, so a sprite is the same size
in the world on every target*/
write_scaled_sheet :: proc(
	target, path: string,
	max_side, small_height: int,
	frames: []Frame,
	frame_width, frame_height, columns, rows: int,
	ppu: f64,
) {
	small_width := max(1, int(math.round(f64(frame_width) * f64(small_height) / f64(frame_height))))

	sheet_width := columns * small_width
	sheet_height := rows * small_height
	if sheet_width > max_side || sheet_height > max_side {
		fail("the %s sheet would be %dx%d; the limit is %d. Use a smaller -%s-frame or more -columns", target, sheet_width, sheet_height, max_side, strings.to_lower(target, context.temp_allocator))
	}

	small_frames := make([]Frame, len(frames))
	for frame, index in frames {
		small_frames[index] = Frame {
			name   = frame.name,
			pixels = downscale(frame.pixels, frame_width, frame_height, small_width, small_height),
		}
	}

	sheet := build_sheet(small_frames, small_width, small_height, columns, rows)
	write_png(path, sheet, sheet_width, sheet_height)

	// The same art is smaller, so fewer pixels make a world unit
	small_ppu := ppu * f64(small_height) / f64(frame_height)
	write_meta(path, small_ppu, columns, rows, len(frames), small_width, small_height, source_ppu = ppu)
	fmt.printfln("%s: %dx%d frames -> %dx%d pixels: %s", target, small_width, small_height, sheet_width, sheet_height, path)
}

print_usage :: proc() {
	fmt.println("sheetpack: pack a folder of same-sized frames into one sprite sheet plus a .meta file")
	fmt.println()
	fmt.println("  sheetpack -o sheet.png [-ppu N] [-columns N] [-list] [-3ds small.png -3ds-frame N] [-vita small.png -vita-frame N] frames_folder")
	fmt.println()
	fmt.println("  -o <file.png>     the sheet to write (required)")
	fmt.println("  -ppu <number>     image pixels per world unit, written to the .meta (default 1)")
	fmt.println("  -columns <n>      frames per row (default: the smallest square-ish grid)")
	fmt.println("  -3ds <file.png>   also write a 3DS sheet here (needs -3ds-frame)")
	fmt.println("  -3ds-frame <n>    height in pixels of one frame on the 3DS sheet")
	fmt.println("  -vita <file.png>  also write a Vita sheet here (needs -vita-frame)")
	fmt.println("  -vita-frame <n>   height in pixels of one frame on the Vita sheet")
	fmt.println("  -list             print each frame's number and file name")
}

option_value :: proc(args: []string, i: int, name: string) -> string {
	if i >= len(args) {
		fail("%s needs a value", name)
	}
	return args[i]
}

// ---- Frames ----

/*Loads every .png in the folder, in natural order. All must be the same size*/
load_frames :: proc(folder: string) -> (frames: []Frame, width, height: int) {
	entries, err := os.read_all_directory_by_path(folder, context.allocator)
	if err != nil {
		fail("could not read the folder '%s'", folder)
	}

	found: [dynamic]Frame
	for entry in entries {
		if entry.type == .Directory {
			continue
		}
		if strings.to_lower(filepath.ext(entry.name), context.temp_allocator) != ".png" {
			continue
		}
		append(&found, Frame{name = strings.clone(entry.name), path = strings.clone(entry.fullpath)})
	}
	if len(found) == 0 {
		fail("no .png files in '%s'", folder)
	}

	slice.sort_by(found[:], proc(a, b: Frame) -> bool {
		return natural_less(a.name, b.name)
	})

	for &frame, index in found {
		w, h: int
		frame.pixels, w, h = load_pixels(frame.path)
		if index == 0 {
			width, height = w, h
		} else if w != width || h != height {
			fail("'%s' is %dx%d but '%s' is %dx%d; every frame must be the same size", frame.name, w, h, found[0].name, width, height)
		}
	}
	return found[:], width, height
}

load_pixels :: proc(path: string) -> (pixels: []u8, width, height: int) {
	img, err := image.load_from_file(path, options = {.alpha_add_if_missing})
	if err != nil {
		fail("could not load '%s': %v", path, err)
	}
	defer image.destroy(img)

	if img.depth != 8 || img.channels != 4 {
		fail("'%s' must be 8 bits per channel", path)
	}

	pixels = make([]u8, len(img.pixels))
	copy(pixels, img.pixels[:])
	return pixels, img.width, img.height
}

// ---- Natural sort: "frame2" before "frame10", and case does not matter ----

natural_less :: proc(a, b: string) -> bool {
	i, j := 0, 0
	for i < len(a) && j < len(b) {
		if is_digit(a[i]) && is_digit(b[j]) {
			start_a := i
			for i < len(a) && is_digit(a[i]) { i += 1 }
			start_b := j
			for j < len(b) && is_digit(b[j]) { j += 1 }

			number_a := strings.trim_left(a[start_a:i], "0")
			number_b := strings.trim_left(b[start_b:j], "0")
			if len(number_a) != len(number_b) {
				return len(number_a) < len(number_b) // more digits = bigger number
			}
			if number_a != number_b {
				return number_a < number_b
			}
			continue
		}

		char_a, char_b := lower(a[i]), lower(b[j])
		if char_a != char_b {
			return char_a < char_b
		}
		i += 1
		j += 1
	}
	return len(a) - i < len(b) - j // the shorter name first
}

is_digit :: proc(c: u8) -> bool { return c >= '0' && c <= '9' }
lower :: proc(c: u8) -> u8 { return c + 32 if c >= 'A' && c <= 'Z' else c }

// ---- Building the sheet ----

build_sheet :: proc(frames: []Frame, frame_width, frame_height, columns, rows: int) -> []u8 {
	sheet_width := columns * frame_width
	sheet := make([]u8, sheet_width * rows * frame_height * 4) // starts transparent

	for frame, index in frames {
		column := index % columns
		row := index / columns
		for y in 0 ..< frame_height {
			from := y * frame_width * 4
			to := ((row * frame_height + y) * sheet_width + column * frame_width) * 4
			copy(sheet[to:to + frame_width * 4], frame.pixels[from:from + frame_width * 4])
		}
	}
	return sheet
}

/*Shrinks an RGBA image by averaging the source pixels under each new pixel.
Colours are weighted by alpha, so the transparent pixels around a sprite
do not darken its edges*/
downscale :: proc(src: []u8, src_width, src_height, dst_width, dst_height: int) -> []u8 {
	dst := make([]u8, dst_width * dst_height * 4)
	x_ratio := f64(src_width) / f64(dst_width)
	y_ratio := f64(src_height) / f64(dst_height)

	for dy in 0 ..< dst_height {
		y_start := f64(dy) * y_ratio
		y_end := y_start + y_ratio

		for dx in 0 ..< dst_width {
			x_start := f64(dx) * x_ratio
			x_end := x_start + x_ratio

			red, green, blue, alpha_sum, weight_sum: f64

			for sy in int(y_start) ..< min(int(math.ceil(y_end)), src_height) {
				y_weight := min(f64(sy + 1), y_end) - max(f64(sy), y_start)

				for sx in int(x_start) ..< min(int(math.ceil(x_end)), src_width) {
					x_weight := min(f64(sx + 1), x_end) - max(f64(sx), x_start)
					weight := x_weight * y_weight

					p := (sy * src_width + sx) * 4
					alpha := f64(src[p + 3]) / 255

					red += f64(src[p + 0]) * alpha * weight
					green += f64(src[p + 1]) * alpha * weight
					blue += f64(src[p + 2]) * alpha * weight
					alpha_sum += alpha * weight
					weight_sum += weight
				}
			}

			d := (dy * dst_width + dx) * 4
			if alpha_sum > 0 {
				dst[d + 0] = u8(clamp(red / alpha_sum + 0.5, 0, 255))
				dst[d + 1] = u8(clamp(green / alpha_sum + 0.5, 0, 255))
				dst[d + 2] = u8(clamp(blue / alpha_sum + 0.5, 0, 255))
			}
			dst[d + 3] = u8(clamp(alpha_sum / weight_sum * 255 + 0.5, 0, 255))
		}
	}
	return dst
}

// ---- Writing ----

write_png :: proc(path: string, pixels: []u8, width, height: int) {
	make_folder_for(path)

	img, ok := image.pixels_to_image(mem.slice_data_cast([][4]u8, pixels), width, height)
	if ok == false {
		fail("could not build the image for '%s'", path)
	}
	if err := png.save_to_file(path, &img); err != nil {
		fail("could not write '%s': %v", path, err)
	}
}

/*
	Writes `name.meta` next to `name.png`. `source_ppu` is the full-size sheet's ppu, given
	for a target's smaller copy: a game writes a clip's offset in the pixels of the art it
	drew, and Matchbox needs it to turn those into this sheet's pixels. 0 leaves it out
*/
write_meta :: proc(png_path: string, ppu: f64, columns, rows, frames, frame_width, frame_height: int, source_ppu: f64 = 0) {
	dot := strings.last_index_byte(png_path, '.')
	base := png_path[:dot] if dot >= 0 else png_path
	meta_path := strings.concatenate({base, ".meta"})

	builder := strings.builder_make()
	fmt.sbprintfln(&builder, "# Written by sheetpack: %d frames of %dx%d", frames, frame_width, frame_height)
	fmt.sbprintfln(&builder, "ppu     = %g", ppu)
	if source_ppu > 0 {
		fmt.sbprintfln(&builder, "source_ppu = %g # the full-size sheet's ppu: clip offsets are in its pixels", source_ppu)
	}
	fmt.sbprintfln(&builder, "columns = %d", columns)
	fmt.sbprintfln(&builder, "rows    = %d", rows)
	if frames != columns * rows {
		fmt.sbprintfln(&builder, "frames  = %d", frames) // the last row is not full
	}

	if err := os.write_entire_file(meta_path, strings.to_string(builder)); err != nil {
		fail("could not write '%s'", meta_path)
	}
}

make_folder_for :: proc(path: string) {
	dir := filepath.dir(path)
	if dir != "" && dir != "." {
		_ = os.make_directory_all(dir)
	}
}
