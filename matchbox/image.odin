package matchbox

/*
	Image
	-----
	Decoded pixels, in ordinary memory.

	Everything else here that reads an image file sends the pixels straight to the
	GPU and forgets them: `create_mesh` decodes with stb, uploads, and frees the
	bytes on the next line. That is right for a sprite, which is never looked at
	again after it is drawn -- and it is the whole problem for anything that wants
	to *edit* a picture rather than display one. A pixel art editor cannot open a
	file. Nor can a program that wants to read a palette out of a PNG, or use one
	as a heightmap, or a collision mask, or a tilemap's source data.

	So this is the same decode with the pixels kept:

		img, ok := matchbox.load_image_from_file("art/sprite.png")
		if !ok do return
		defer matchbox.destroy(&img)

		canvas := matchbox.create_pixel_buffer(img.width, img.height)
		matchbox.pixel_buffer_update(&canvas, img.pixels)

	Always RGBA, one byte a channel, whatever the file held -- stb is asked for
	four channels and converts. Straight alpha, not premultiplied, which is what
	the blend every pipeline uses expects.

	Writing one back out is deliberately not here. `vendor:stb/image` already has
	`write_png` and the library it needs ships with Odin, so a save is one call to
	a package matchbox is not in the middle of:

		stbi.write_png("out.png", w, h, 4, raw_data(pixels), w * 4)
*/

import "core:log"
import "core:os"

import stbi "vendor:stb/image"

/*
	A decoded image. `pixels` is width * height entries, row by row from the top.

	Indexed as `pixels[y * int(width) + x]`, and `[4]u8` rather than a flat byte
	slice because the thing being handed back is a grid of colours and every
	caller would otherwise write that multiply by four themselves. It goes
	straight into pixel_buffer_update, which takes a slice of anything four bytes
	wide.
*/
Image :: struct {
	pixels: [][4]u8,
	width:  i32,
	height: i32,

	// What the file itself held, before the conversion to RGBA: 1 grey, 2 grey
	// and alpha, 3 RGB, 4 RGBA. Informational -- `pixels` is four channels
	// regardless -- but it is the only way to know whether the source had any
	// transparency to begin with, which an editor wants when it decides what to
	// save back out.
	channels: i32,
}

/*
	Decodes an image held in memory. PNG, JPEG, BMP, TGA, GIF, PSD and the rest of
	what stb reads.

	Returns ok = false rather than panicking, and says why through the log. A file
	that will not decode is a content problem -- somebody chose it from a file
	dialog -- and bringing the program down over it is the wrong response. That is
	the same call `sprite_cache_get` makes for a missing file.

	The pixels are copied out of stb's own allocation into `allocator`, so the
	result is freed with `destroy` (or `delete`) like anything else, works under a
	tracking allocator, and can be put in the temp allocator when it is only being
	looked at once. The copy costs a memcpy against a decode that is tens of
	milliseconds, which is why it is not worth handing back stb's pointer and a
	rule about how to free it.
*/
load_image :: proc(bytes: []byte, allocator := context.allocator) -> (image: Image, ok: bool) {
	if len(bytes) == 0 {
		log.error("cannot decode an empty image")
		return {}, false
	}

	width, height, channels: i32

	// 4 forces RGBA out of whatever the file holds, which is what every consumer
	// here wants and what saves each of them a conversion.
	decoded := stbi.load_from_memory(raw_data(bytes), i32(len(bytes)), &width, &height, &channels, 4)
	if decoded == nil {
		log.errorf("could not decode image: %s", stbi.failure_reason())
		return {}, false
	}
	defer stbi.image_free(decoded)

	if width <= 0 || height <= 0 {
		log.errorf("image decoded to an impossible size: %dx%d", width, height)
		return {}, false
	}

	count  := int(width) * int(height)
	pixels := make([][4]u8, count, allocator)

	copy(pixels, (cast([^][4]u8)decoded)[:count])

	return Image{pixels = pixels, width = width, height = height, channels = channels}, true
}

/*
	The same, read from a path.

	Returns ok = false when the file cannot be read as well as when it cannot be
	decoded, and the log says which -- those are different problems and an editor
	reporting "could not open" for a corrupt PNG sends somebody looking in the
	wrong place.
*/
load_image_from_file :: proc(path: string, allocator := context.allocator) -> (image: Image, ok: bool) {
	bytes, err := os.read_entire_file_from_path(path, context.allocator)
	if err != nil {
		log.errorf("could not read image %s: %v", path, err)
		return {}, false
	}
	defer delete(bytes)

	return load_image(bytes, allocator)
}

/*
	How big an image is without decoding it.

	stb reads the header alone for this, so it is cheap next to a decode -- which
	is the point: a file browser showing dimensions beside a hundred thumbnails
	should not decode a hundred images to find them out.
*/
image_size :: proc(bytes: []byte) -> (width, height, channels: i32, ok: bool) {
	if len(bytes) == 0 do return 0, 0, 0, false

	if stbi.info_from_memory(raw_data(bytes), i32(len(bytes)), &width, &height, &channels) == 0 {
		return 0, 0, 0, false
	}

	return width, height, channels, true
}

// One pixel, or {0,0,0,0} when the coordinates are off the image. Bounds-checked
// because the common reason to reach for this is sampling from somewhere derived
// -- a scaled position, a neighbour, a brush offset -- rather than from a loop
// that already knows it is inside.
image_pixel :: proc(image: Image, x, y: int) -> [4]u8 {
	if x < 0 || y < 0 || x >= int(image.width) || y >= int(image.height) do return {}
	return image.pixels[y * int(image.width) + x]
}

// Frees the pixels. Reachable through `destroy`.
destroy_image :: proc(image: ^Image) {
	delete(image.pixels)

	image.pixels = nil
	image.width  = 0
	image.height = 0
}
