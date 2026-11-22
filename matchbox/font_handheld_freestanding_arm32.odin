#+build freestanding arm32

package matchbox

/*
	Font baking (handhelds)
	=======================
	No baker yet on the 3DS or the Vita: which one they get is still open (render_plan.md,
	F2 -- the 3DS system font, a pre-baked atlas, or stb compiled for ARM with a float
	bridge). Until then a font has no glyphs, so text measures as nothing and draws nothing,
	and a game that uses text still compiles and runs.

	One file for both handhelds: the answer is the same on each until F2 is decided.
*/

/*
	Leaves `bitmap` and `glyphs` empty and answers that they fit, so create_font stops at the
	smallest atlas instead of growing it to the largest looking for room
*/
@(private)
bake_font_atlas :: proc(bytes:[]byte, pixel_size:f32, bitmap:[]u8, atlas:i32, glyphs:^[FONT_GLYPH_COUNT]Baked_Glyph) -> (rows_used:i32) {
	return 1
}
