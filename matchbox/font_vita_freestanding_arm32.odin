#+build freestanding arm32

package matchbox

/*
	Font baking -- Vita
	===================
	The Vita gets its own native text (render_plan.md, F2), through its font system, once
	Phase V gives it a renderer to draw with. Until then a font has no glyphs, so text
	measures as nothing and draws nothing, and a game that uses text still compiles and runs.

	Inside `when VITA` for the reason in backend_vita_freestanding_arm32.odin
*/

when VITA {

	/*
		Leaves `bitmap` and `glyphs` empty and answers that they fit, so create_font stops at
		the smallest atlas instead of growing it to the largest looking for room
	*/
	@(private)
	bake_font_atlas :: proc(bytes:[]byte, pixel_size:f32, bitmap:[]u8, atlas:i32, glyphs:^[FONT_GLYPH_COUNT]Baked_Glyph) -> (rows_used:i32) {
		return 1
	}
}
