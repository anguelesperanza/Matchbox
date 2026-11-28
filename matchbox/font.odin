package matchbox

import "core:log"

/*
	Font
	====
	Bakes a TTF into a texture atlas. Drawing with it lives in text.odin.

	The baking is each target's `bake_font_atlas`, and each uses its native text
	(render_plan.md, F2):
	- PC: stb_truetype bakes the TTF given (vendor:stb/truetype, font_windows.odin).
	- 3DS: the console's system font, copied out of its glyph sheets; the TTF is not read
	  (font_3ds_freestanding_arm32.odin).
	- Vita: the system font through ScePvf; the TTF is not read (font_vita_freestanding_arm32.odin).
	Everything else here is shared, and `Font` holds no type of any one baker, so a game
	is the same on every target.

	A font is baked at ONE pixel size, because stb bakes fixed-size glyphs rather
	than scaling them. Drawing a 26 pixel atlas at twice the size is a blurry 26
	pixel atlas. A game wanting several sizes makes several fonts.
*/

// Zerove, shipped inside the executable. It replaced Bitrimus, whose pixel shapes were hard to read at small sizes
DEFAULT_FONT_BYTES :: #load("fonts/Zerove-Regular.ttf")

// How many printable ASCII glyphs a font holds. A constant because it sizes `baked_chars`
FONT_GLYPH_COUNT :: 95

/*
	The values every font is baked and laid out with. Lives in `mbi.font_settings`;
	the values are set where `mbi` is declared, so they hold under `odin test` too,
	where `init` never runs.
*/
Font_Settings :: struct {
	// The atlas is one square texture holding the printable ASCII glyphs. It starts at the
	// smaller size and doubles until they all fit, so a big pixel size gets a big atlas
	atlas_min_size:i32,
	atlas_max_size:i32,
	first_glyph:rune, // the character of the first glyph baked: 32, the space
	line_spacing:f32, // the gap between lines, as a fraction of the line's height
}

/*
	One glyph's place in the atlas and how it sits on the baseline, in atlas pixels. The same
	layout as stb's `bakedchar`, so the PC's baker writes these directly; font_windows.odin
	asserts that, so a change on either side fails to compile rather than garbling text
*/
Baked_Glyph :: struct {
	x0, y0, x1, y1:u16, // the glyph's rectangle in the atlas, from its top left
	xoff, yoff:f32, // from the cursor on the baseline to the rectangle's top left, y down
	xadvance:f32, // how far the cursor moves on
}

Font :: struct {
	texture:Texture, // white RGB, with the glyph coverage in alpha
	baked_chars:[FONT_GLYPH_COUNT]Baked_Glyph,
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
	bitmap:[]u8
	font, bitmap = bake_font(bytes, pixel_size, pixels_per_unit)
	defer delete(bitmap)
	atlas := font.atlas_size

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

/*
	A font that can measure and cannot draw: the same sizes and advances create_font gives, with no atlas texture, so no
	window or GPU is needed. calculate_text_size, calculate_line_height and wrap_text work on it, so a layout can be tested
	headless; render_text on it draws nothing visible. It owns nothing, so there is no destroy_font to call
*/
create_font_metrics :: proc(bytes:[]byte, pixel_size:f32, pixels_per_unit:f32 = 0) -> Font {
	font, bitmap := bake_font(bytes, pixel_size, pixels_per_unit)
	delete(bitmap)
	return font
}

// The baking half of create_font, which needs no GPU: the glyph rectangles, the metrics, and the grayscale atlas (the caller frees it)
@(private)
bake_font :: proc(bytes:[]byte, pixel_size:f32, pixels_per_unit:f32) -> (font:Font, bitmap:[]u8) {
	ensure(pixel_size >= 1, "A font needs a pixel size of at least 1")

	font.size = pixel_size
	font.pixels_per_unit = pixels_per_unit if pixels_per_unit > 0 else pixel_size

	// Every printable ASCII glyph, as a grayscale bitmap, in the smallest atlas they fit in
	atlas := i32(mbi.font_settings.atlas_min_size)
	for {
		bitmap = make([]u8, atlas * atlas)

		rows_used := bake_font_atlas(bytes, pixel_size, bitmap, atlas, &font.baked_chars)
		if rows_used > 0 do break

		if atlas >= mbi.font_settings.atlas_max_size {
			log.errorf("font at %v pixels does not fit in a %vx%v atlas, so the last glyphs are missing", pixel_size, atlas, atlas)
			break
		}

		delete(bitmap)
		atlas *= 2
	}
	font.atlas_size = atlas

	// Where text is placed is the baseline, so something positioning text from the top of a
	// box needs the ascent. Measured off the glyphs that were baked: yoff is the baseline to
	// the top of the glyph, negative up
	for c in font.baked_chars {
		font.ascent = max(font.ascent, -c.yoff)
		font.descent = max(font.descent, c.yoff + (f32(c.y1) - f32(c.y0)))
	}
	return
}

/*Gives the font's atlas back to the GPU*/
destroy_font :: proc(font:Font) {
	destroy_texture(font.texture)
}
