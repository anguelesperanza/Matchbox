#+build freestanding arm32

package matchbox

/*
	Font baking -- 3DS
	==================
	The 3DS draws text with its own system font, the one in the console's shared memory that
	the HOME menu uses, rather than the font the game passes (render_plan.md, F2: each target
	uses its native text). `bytes` is ignored here, so a game written against create_font
	runs unchanged, with the console's letters.

	The system font is a bitmap font in tiled 4-bit alpha sheets. This copies the printable
	ASCII glyphs out of them into the one grayscale atlas create_font expects, scaled from the
	font's own height to `pixel_size`, and fills in the same Baked_Glyph metrics stb gives on
	PC. From there everything is shared: the atlas is uploaded by create_font, and text.odin
	lays the glyphs out and draws them as sprites. Drawing straight from the sheets instead
	would mean a texture per sheet and a draw per glyph switch, and text.odin's one-texture
	layout would have to change on every target for the 3DS's sake.

	Inside `when !VITA` for the reason in backend_3ds_freestanding_arm32.odin
*/

import "core:math"

import "o3dx/c3d"
import "o3dx/ctru"

when !VITA {

	/*
		fontCalcGlyphPos's output, which o3dx binds as 48 opaque bytes. libctru's fontGlyphPos_s:
		an int, three floats, then two rectangles of four floats
	*/
	@(private="file")
	Glyph_Position :: struct {
		sheet_index:i32,
		x_offset:f32, // from the cursor to the glyph's left edge, in sheet pixels
		x_advance:f32, // how far the cursor moves on
		width:f32, // the glyph's drawn width
		texcoord:struct {
			left, top, right, bottom:f32, // in the sheet, v = 1 at its top
		},
		vtxcoord:struct {
			left, top, right, bottom:f32,
		},
	}
	#assert(size_of(Glyph_Position) == size_of(ctru.fontGlyphPos_s))

	/*
		Fills `bitmap` (atlas x atlas, one byte of coverage a pixel) and `glyphs` from the system
		font, packed in rows like stb packs them. Answers the first unused row, or 0 when the
		glyphs do not fit and create_font should try a bigger atlas
	*/
	@(private)
	bake_font_atlas :: proc(bytes:[]byte, pixel_size:f32, bitmap:[]u8, atlas:i32, glyphs:^[FONT_GLYPH_COUNT]Baked_Glyph) -> (rows_used:i32) {
		if ctru.fontEnsureMapped() < 0 {
			// Not mapped means no letters at all: say so once, and leave the font empty so the
			// game still runs. An emulator without the console's system files is the usual cause
			print("The 3DS system font could not be mapped: text will not be drawn")
			return 1
		}
		font := ctru.fontGetSystemFont()
		sheets := ctru.fontGetGlyphInfo(font)
		ensure(c3d.GPU_TEXCOLOR(sheets.sheetFmt) == .A4, "The 3DS system font's sheets are not 4-bit alpha")

		// The font is one size; the cell height is its line, so scaling it to pixel_size makes
		// a font of that size as stb would. Each atlas pixel averages a 4 x 4 grid of samples,
		// which keeps strokes when shrinking and blocks when growing
		scale := pixel_size / f32(sheets.cellHeight)
		samples :: 4

		x, y:i32 = 1, 1 // one pixel of space around each glyph, as stb leaves
		row_height:i32 = 0

		for i in 0 ..< FONT_GLYPH_COUNT {
			code := mbi.font_settings.first_glyph + rune(i)
			index := ctru.fontGlyphIndexFromCodePoint(font, u32(code))

			position:Glyph_Position
			ctru.fontCalcGlyphPos((^ctru.fontGlyphPos_s)(&position), font, index, 0, 1, 1)

			// The glyph's rectangle in its sheet, in pixels from the sheet's top left
			sheet_width := f32(sheets.sheetWidth)
			sheet_height := f32(sheets.sheetHeight)
			source_left := i32(math.round(position.texcoord.left * sheet_width))
			source_top := i32(math.round((1 - position.texcoord.top) * sheet_height))
			source_width := i32(math.round((position.texcoord.right - position.texcoord.left) * sheet_width))
			source_height := i32(math.round((position.texcoord.top - position.texcoord.bottom) * sheet_height))
			sheet := ([^]u8)(ctru.fontGetGlyphSheetTex(font, position.sheet_index))

			width := i32(math.ceil(f32(source_width) * scale))
			height := i32(math.ceil(f32(source_height) * scale))

			if x + width + 1 > atlas {
				x = 1
				y += row_height + 1
				row_height = 0
			}
			if y + height + 1 > atlas do return 0

			for atlas_y in 0 ..< height {
				for atlas_x in 0 ..< width {
					total:i32 = 0
					for sample_y in 0 ..< samples {
						for sample_x in 0 ..< samples {
							glyph_x := i32((f32(atlas_x) + (f32(sample_x) + 0.5) / samples) / scale)
							glyph_y := i32((f32(atlas_y) + (f32(sample_y) + 0.5) / samples) / scale)
							if glyph_x < source_width && glyph_y < source_height {
								total += i32(read_sheet_alpha(sheet, i32(sheets.sheetWidth), source_left + glyph_x, source_top + glyph_y))
							}
						}
					}
					bitmap[(y + atlas_y) * atlas + x + atlas_x] = u8(total / (samples * samples))
				}
			}

			glyphs[i] = Baked_Glyph {
				x0 = u16(x),
				y0 = u16(y),
				x1 = u16(x + width),
				y1 = u16(y + height),
				xoff = position.x_offset * scale,
				yoff = -f32(sheets.baselinePos) * scale, // the cell's top is the baseline position above it
				xadvance = position.x_advance * scale,
			}

			x += width + 1
			row_height = max(row_height, height)
		}
		return y + row_height + 1
	}

	/*
		One pixel of a system font sheet, 0..255, (x, y) from the sheet's top left. The sheets
		are tiled like any PICA texture (8 x 8 tiles, Morton order inside, the top row of tiles
		first), at 4 bits a pixel, the first pixel of a pair in the low nibble
	*/
	@(private="file")
	read_sheet_alpha :: proc(sheet:[^]u8, sheet_width, x, y:i32) -> u8 {
		tile := (y / 8) * (sheet_width / 8) + x / 8
		inner_x := x & 7
		inner_y := y & 7
		morton := (inner_x & 1) | (inner_y & 1) << 1 | (inner_x & 2) << 1 | (inner_y & 2) << 2 | (inner_x & 4) << 2 | (inner_y & 4) << 3
		pixel := tile * 64 + morton
		nibble := sheet[pixel / 2] >> 4 if pixel & 1 == 1 else sheet[pixel / 2] & 0xF
		return nibble * 17
	}
}
