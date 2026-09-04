package framebuffer_example

/*
	A Pixel_Buffer: a texture whose pixels are rewritten every frame.

	This is what an emulator draws with. Nothing here decodes an image or loads a
	file -- the picture is written a pixel at a time into an ordinary array, handed
	over once a frame, and drawn scaled up with nearest-neighbour filtering so the
	pixels stay square.

	The buffer is 160x144, which is a Game Boy, because that is the case this was
	built for. A Chip-8 is 64x32 and an NES is 256x240; nothing below changes but
	the two numbers.

	Things to try:

	  - resize the window. The image keeps its shape and stays centred rather than
	    stretching, which is pixel_buffer_fit doing the arithmetic every emulator
	    otherwise writes for itself
	  - press I. That turns on integer scaling, so one source pixel becomes an
	    exact block of screen pixels. Watch the checkerboard in the corners: at a
	    fractional scale some squares are three screen pixels across and others
	    two, and the seams wander. It costs a black margin, which is the trade
	  - press G for a grid of single pixels, which is the honest test of whether
	    one pixel is landing on one place
	  - paint on it. Left button draws, right button erases, and the box follows
	    whichever pixel is under the pointer. That is pixel_buffer_pick going the
	    other way from drawing: pointer in, array index out
	  - then turn integer scaling on, which leaves a black margin, and move the
	    pointer into it. The box disappears and the readout says "outside" rather
	    than sticking to the nearest edge pixel. At the default size the image
	    fills the window exactly and there is no margin to try that in, which is
	    the only reason it needs saying
	  - press O to open a PNG into the canvas and then paint over it, which is
	    the whole shape of a pixel art editor. load_image is what makes that
	    possible: every other way matchbox reads a file sends the pixels to the
	    GPU and frees them on the next line, which is right for a sprite and
	    useless for anything that wants to change one
*/

import "core:fmt"
import "core:math"

import mb "../../matchbox"

// A Game Boy screen. The rest of this file does not know that.
W :: 160
H :: 144

// The four shades of a Game Boy, greenest first.
SHADES := [4][4]u8{
	{0x0f, 0x38, 0x0f, 0xff},
	{0x30, 0x62, 0x30, 0xff},
	{0x8b, 0xac, 0x0f, 0xff},
	{0x9b, 0xbc, 0x0f, 0xff},
}

main :: proc() {
	mb.init("Framebuffer", 160 * 4, 144 * 4)
	defer mb.cleanup()

	font := &mb.mbi.font

	screen, screen_err := mb.create_pixel_buffer(W, H)
	if screen_err != nil do return
	defer mb.destroy(&screen)

	// The pixels. An ordinary array that matchbox never sees except during the
	// one call that hands it over -- exactly where an emulator's framebuffer sits.
	pixels: [W * H][4]u8

	// What has been painted, over the top of the animation. Alpha 0 is untouched,
	// which is why this is a colour per pixel rather than a bool.
	paint: [W * H][4]u8

	integer := false
	grid    := false
	elapsed: f32

	for mb.is_running() {
		mb.poll_events()
		elapsed += mb.get_delta_time()

		if mb.is_key_pressed(.I) do integer = !integer
		if mb.is_key_pressed(.G) do grid    = !grid
		if mb.is_key_pressed(.C) do paint = {}

		// ---- open a real file into the canvas ------------------------------
		if mb.is_key_pressed(.O) {
			if img, err := mb.load_image_from_file("art/ember.png"); err == nil {
				defer mb.destroy(&img)

				// Nearest-sampled to fit, keeping its shape. Sampling by hand
				// rather than asking matchbox to scale it, because an editor
				// resamples on its own terms -- and because it shows that what
				// came back really is an addressable grid of colours.
				fit := min(f32(W) / f32(img.width), f32(H) / f32(img.height))
				dw  := int(f32(img.width)  * fit)
				dh  := int(f32(img.height) * fit)
				ox  := (W - dw) / 2
				oy  := (H - dh) / 2

				paint = {}
				for y in 0 ..< dh {
					for x in 0 ..< dw {
						paint[(oy + y) * W + ox + x] =
							mb.image_pixel(img, int(f32(x) / fit), int(f32(y) / fit))
					}
				}
			}
		}

		// ---- draw into the buffer, a pixel at a time ---------------------
		for y in 0 ..< H {
			for x in 0 ..< W {
				if p := paint[y * W + x]; p.a != 0 {
					pixels[y * W + x] = p
				} else {
					pixels[y * W + x] = shade_at(x, y, elapsed, grid)
				}
			}
		}

		mb.begin_drawing()

		// Before clear_background, which is the cheap place for it: the copy
		// cannot be recorded while a render pass is open, so handing the pixels
		// over after drawing has started closes the pass and the next draw
		// reopens it. Correct either way, just not free.
		mb.pixel_buffer_update(&screen, pixels[:])

		mb.clear_background({0.05, 0.05, 0.06, 1})

		// The biggest box of the buffer's shape that fits the window, centred.
		dest := mb.pixel_buffer_fit(&screen, integer = integer)
		mb.draw_pixel_buffer(&screen, dest)

		// ---- which pixel is under the pointer ------------------------------
		// The same `dest` that was just drawn with, not a fresh one: a pick that
		// worked the destination out again could disagree with what is on screen,
		// and the symptom would be a brush landing a pixel or two off the cursor.
		hovered := "outside"

		if px, py, ok := mb.pixel_buffer_pick_mouse(&screen, dest); ok {
			hovered = fmt.tprintf("pixel %d, %d", px, py)

			if mb.is_mouse_held(.LEFT)  do paint[py * W + px] = {0xff, 0x40, 0x60, 0xff}
			if mb.is_mouse_held(.RIGHT) do paint[py * W + px] = {}

			// A box round it, which is the inverse of the pick: index in, screen
			// rectangle out. One source pixel is `scale` screen pixels across.
			top := mb.rect_top_left(dest)
			s   := dest.size.x / f32(W)

			mb.draw_rect_border({
				position = {top.x + f32(px) * s, top.y + f32(py) * s},
				size     = {s, s},
				pivot    = {0.5, 0.5},
			}, mb.WHITE, max(1, s * 0.12))
		}

		// ---- what is on screen ---------------------------------------------
		scale := dest.size.x / f32(W)

		mb.draw_text_plate(font, fmt.tprintf("%dx%d  ->  %.0fx%.0f   scale %.3f",
			W, H, dest.size.x, dest.size.y, scale), {8, 8})

		mb.draw_text_plate(font,
			fmt.tprintf("I  integer scaling: %s", "on" if integer else "off"), {8, 44})
		mb.draw_text_plate(font,
			fmt.tprintf("G  pixel grid: %s", "on" if grid else "off"), {8, 76})
		mb.draw_text_plate(font,
			fmt.tprintf("%s   (drag to paint, right button erases)", hovered), {8, 108})
		mb.draw_text_plate(font, "O  open a png into the canvas    C  clear", {8, 140})

		mb.end_drawing()
		free_all(context.temp_allocator)
	}
}

/*
	What colour one pixel is.

	Two patterns, because they answer different questions. The plasma says the
	upload is landing at all and is not a frame behind. The checkerboard and the
	grid say whether one source pixel is becoming a clean block of screen pixels
	-- which is what integer scaling is for and what nearest filtering makes
	visible.
*/
shade_at :: proc(x, y: int, elapsed: f32, grid: bool) -> [4]u8 {
	// A single lit pixel every eight, on black. If any of these look like they
	// are different sizes, the scale is fractional.
	if grid {
		if x % 8 == 0 && y % 8 == 0 do return SHADES[3]
		return SHADES[0]
	}

	// One-pixel checkerboard in the corners, which is where unevenness shows
	// first and where a half-pixel offset turns the whole square to mush.
	corner := 24
	if (x < corner || x >= W - corner) && (y < corner || y >= H - corner) {
		return SHADES[3] if (x + y) % 2 == 0 else SHADES[0]
	}

	fx := f32(x) / f32(W)
	fy := f32(y) / f32(H)

	v := math.sin(fx * 8 + elapsed) +
	     math.sin(fy * 6 - elapsed * 0.7) +
	     math.sin((fx + fy) * 5 + elapsed * 1.3)

	// -3..3 into one of four shades, which is the whole of a Game Boy's palette.
	step := int((v + 3) / 6 * 4)
	return SHADES[clamp(step, 0, 3)]
}
