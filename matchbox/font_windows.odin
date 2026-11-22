#+build windows

package matchbox

/*
	Font baking (PC)
	================
	stb_truetype bakes the atlas. The only stb call in Matchbox: everything else in font.odin
	and text.odin is shared, so a different baker replaces this file and nothing else.
*/

import stbtt "vendor:stb/truetype"

// Baked_Glyph is passed to stb as its own bakedchar, so the two must match field for field
#assert(size_of(Baked_Glyph) == size_of(stbtt.bakedchar))
#assert(offset_of(Baked_Glyph, x0) == offset_of(stbtt.bakedchar, x0))
#assert(offset_of(Baked_Glyph, y1) == offset_of(stbtt.bakedchar, y1))
#assert(offset_of(Baked_Glyph, xoff) == offset_of(stbtt.bakedchar, xoff))
#assert(offset_of(Baked_Glyph, xadvance) == offset_of(stbtt.bakedchar, xadvance))

/*
	Bakes the printable ASCII glyphs of `bytes` into `bitmap`, an `atlas` x `atlas` grayscale
	image, and fills `glyphs`. Returns the rows used, or 0 or less when they did not all fit
	(stb's own answer), so create_font tries a bigger atlas
*/
@(private)
bake_font_atlas :: proc(bytes:[]byte, pixel_size:f32, bitmap:[]u8, atlas:i32, glyphs:^[FONT_GLYPH_COUNT]Baked_Glyph) -> (rows_used:i32) {
	return stbtt.BakeFontBitmap(raw_data(bytes), 0, pixel_size, raw_data(bitmap), atlas, atlas, i32(mbi.font_settings.first_glyph), FONT_GLYPH_COUNT, cast([^]stbtt.bakedchar)glyphs)
}
