#+build windows

package matchbox

import "core:log"

import stbtt "vendor:stb/truetype"

/*
	Font
	====
	Bakes a TTF into a texture atlas. Drawing with it lives in text.odin.

	The baking is stb_truetype (vendor:stb/truetype), as on the main branch. That
	may change: the aim is to drop the stb dependency later, and the rest of the
	engine only sees `Font`, so a different baker would not change a game.

	A font is baked at ONE pixel size, because stb bakes fixed-size glyphs rather
	than scaling them. Drawing a 26 pixel atlas at twice the size is a blurry 26
	pixel atlas. A game wanting several sizes makes several fonts.
*/

// Bitrimus, a pixel font made to be drawn at 16, 32, 64, 128 or 256 pixels. Shipped inside
// the executable. Use one of those sizes so its design pixels land on whole screen pixels
DEFAULT_FONT_BYTES :: #load("fonts/Bitrimus.ttf")

// The atlas is one square texture holding the printable ASCII glyphs. It starts at the
// smaller size and doubles until they all fit, so a big pixel size gets a big atlas
FONT_ATLAS_MIN_SIZE :: 256
FONT_ATLAS_MAX_SIZE :: 4096
FONT_FIRST_GLYPH :: 32
FONT_GLYPH_COUNT :: 95

// The gap between lines, as a fraction of the line's height
FONT_LINE_SPACING :: 0.15

Font :: struct {
	texture:Texture, // white RGB, with the glyph coverage in alpha
	baked_chars:[FONT_GLYPH_COUNT]stbtt.bakedchar,
	atlas_size:i32,

	size:f32, // pixels the glyphs were baked at
	pixels_per_unit:f32, // atlas pixels per world unit, the same idea as a sprite's
	ascent:f32, // baseline up to the tallest glyph, in pixels
	descent:f32, // baseline down to the lowest glyph, in pixels
}

/*
	Bakes `bytes` (the contents of a .ttf; `#load` works) at `pixel_size` pixels tall.

	`pixels_per_unit` is how many pixels make one world unit when the text is drawn,
	like a sprite's. 0 uses `pixel_size`, so one unit is the size of the font.
	The text is sharpest when that matches the screen: if the HUD is 90 screen
	pixels to the unit, bake at 32 with a `pixels_per_unit` of 90 and the glyphs are
	drawn at exactly 32 screen pixels.

	`pixel_size` should be a whole number, and for a pixel font one it was made for (the
	default font: 16, 32, 64, 128, 256), so its design pixels land on whole screen pixels.
	The atlas grows to fit the size: 256 pixels for 16 and 32, 512 for 64, 1024 for 128
	and 2048 for 256 (16 MB of texture).
	Linear filtering by default, because glyph quads rarely land on whole pixels; use
	.POINT for a pixel font drawn with pixel snapping.
*/
create_font :: proc(bytes:[]byte, pixel_size:f32, pixels_per_unit:f32 = 0, filter:Filter_Mode = .LINEAR) -> (font:Font) {
	ensure(pixel_size >= 1, "A font needs a pixel size of at least 1")

	font.size = pixel_size
	font.pixels_per_unit = pixels_per_unit if pixels_per_unit > 0 else pixel_size

	// Every printable ASCII glyph, as a grayscale bitmap, in the smallest atlas they fit in
	atlas := i32(FONT_ATLAS_MIN_SIZE)
	bitmap:[]u8
	for {
		bitmap = make([]u8, atlas * atlas)

		rows_used := stbtt.BakeFontBitmap(raw_data(bytes), 0, pixel_size, raw_data(bitmap), atlas, atlas, FONT_FIRST_GLYPH, FONT_GLYPH_COUNT, raw_data(font.baked_chars[:]))
		if rows_used > 0 do break

		if atlas >= FONT_ATLAS_MAX_SIZE {
			log.errorf("font at %v pixels does not fit in a %vx%v atlas, so the last glyphs are missing", pixel_size, atlas, atlas)
			break
		}

		delete(bitmap)
		atlas *= 2
	}
	defer delete(bitmap)
	font.atlas_size = atlas

	// Where text is placed is the baseline, so something positioning text from the top of a
	// box needs the ascent. Measured off the glyphs that were baked: yoff is the baseline to
	// the top of the glyph, negative up
	for c in font.baked_chars {
		font.ascent = max(font.ascent, -c.yoff)
		font.descent = max(font.descent, c.yoff + (f32(c.y1) - f32(c.y0)))
	}

	// Grayscale to RGBA: white, with the glyph coverage as alpha. The colour of the text
	// comes from the sprite tint
	rgba := make([]u8, atlas * atlas * 4)
	defer delete(rgba)
	for i in 0 ..< int(atlas * atlas) {
		rgba[i * 4 + 0] = 255
		rgba[i * 4 + 1] = 255
		rgba[i * 4 + 2] = 255
		rgba[i * 4 + 3] = bitmap[i]
	}

	font.texture = create_texture_from_pixels(raw_data(rgba), atlas, atlas, filter)
	return
}

/*Gives the font's atlas back to the GPU*/
destroy_font :: proc(font:Font) {
	destroy_texture(font.texture)
}
