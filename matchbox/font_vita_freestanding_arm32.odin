#+build freestanding arm32

package matchbox

/*
	Font baking -- Vita
	===================
	The Vita draws text with its own system font, through ScePvf (the scalable fonts the
	system UI uses), rather than the font the game passes (render_plan.md, F2: each target
	uses its native text). `bytes` is ignored here, as on the 3DS, so a game written against
	create_font runs unchanged, with the console's letters.

	ScePvf renders each glyph at the size asked for straight into the one grayscale atlas
	create_font expects, and its metrics fill the same Baked_Glyph stb gives on PC. From there
	everything is shared: create_font uploads the atlas, and text.odin lays out and draws the
	glyphs as sprites. Unlike the 3DS's bitmap font nothing is resampled, so text is as sharp
	at any size as the system's own.

	The library is opened for the bake and closed after it: the glyphs live in the atlas, so
	nothing of ScePvf is needed while drawing.

	Inside `when VITA` for the reason in backend_vita_freestanding_arm32.odin
*/

import "vito/sce"

// ScePvf asks for its memory through callbacks, which are C calls with no Odin context, so
// they go to the C heap directly
foreign import libc "system:c"

@(default_calling_convention = "c", private = "file")
foreign libc {
	malloc :: proc(size:uint) -> rawptr ---
	realloc :: proc(pointer:rawptr, size:uint) -> rawptr ---
	free :: proc(pointer:rawptr) ---
}

when VITA {

	/*
		Fills `bitmap` (atlas x atlas, one byte of coverage a pixel) and `glyphs` from the system
		font, packed in rows like stb packs them. Answers the first unused row, or 0 when the
		glyphs do not fit and create_font should try a bigger atlas
	*/
	@(private)
	bake_font_atlas :: proc(bytes:[]byte, pixel_size:f32, bitmap:[]u8, atlas:i32, glyphs:^[FONT_GLYPH_COUNT]Baked_Glyph) -> (rows_used:i32) {
		settings := sce.PvfInitRec {
			maxNumFonts = 1,
			allocFunc = pvf_allocate,
			reallocFunc = pvf_reallocate,
			freeFunc = pvf_free,
		}
		error:sce.PvfError
		library := sce.scePvfNewLib(&settings, &error)
		if library == nil {
			// No letters at all: say so, and leave the font empty so the game still runs
			print("ScePvf could not start, error", error, ": text will not be drawn")
			return 1
		}
		defer sce.scePvfDoneLib(library)

		// At 72 dots per inch a point is a pixel, so the size asked for is set as it is
		sce.scePvfSetResolution(library, 72, 72)

		style := sce.PvfFontStyleInfo {
			familyCode = u16(sce.PVF_FAMILY_SANSERIF),
			style = u16(sce.PVF_STYLE_REGULAR),
			languageCode = u16(sce.PVF_LANGUAGE_LATIN),
		}
		index := sce.scePvfFindOptimumFont(library, &style, &error)
		font:sce.PvfFontId
		if error >= 0 do font = sce.scePvfOpen(library, index, 1, &error)
		if font == nil {
			print("The Vita system font could not be opened, error", error, ": text will not be drawn")
			return 1
		}
		defer sce.scePvfClose(font)
		sce.scePvfSetCharSize(font, pixel_size, pixel_size)

		x, y:i32 = 1, 1 // one pixel of space around each glyph, as stb leaves
		row_height:i32 = 0

		for i in 0 ..< FONT_GLYPH_COUNT {
			code := sce.PvfCharCode(mbi.font_settings.first_glyph + rune(i))

			// The bitmap fields of PvfCharInfo stay 0: the drawn size comes from GetCharImageRect,
			// and where the glyph sits from the metrics' bearings (26.6 fixed point), as vita2d
			// reads them
			info:sce.PvfCharInfo
			rectangle:sce.PvfIrect
			if sce.scePvfGetCharInfo(font, code, &info) < 0 do continue // left empty: draws nothing
			if sce.scePvfGetCharImageRect(font, code, &rectangle) < 0 do continue
			metrics := info.glyphMetrics
			// Whole pixels, so the pen sits on one: left rounded down and top up keep the ink
			// inside the rectangle, and the clip below cuts any fraction that would spill over
			left := metrics.horizontalBearingX64 >> 6
			top := (metrics.horizontalBearingY64 + 63) >> 6

			width := i32(rectangle.width)
			height := i32(rectangle.height)
			if x + width + 1 > atlas {
				x = 1
				y += row_height + 1
				row_height = 0
			}
			if y + height + 1 > atlas do return 0

			if width > 0 && height > 0 {
				// The pen is on the baseline: put it `left` before and `top` below (x, y), so the
				// glyph's top left lands there. Clipped to its own rectangle, so a glyph can never
				// write over its neighbour in the atlas
				image := sce.PvfUserImageBufferRec {
					pixelFormat = sce.PVF_USERIMAGE_DIRECT8,
					xPos64 = (x - left) * 64,
					yPos64 = (y + top) * 64,
					rect = {width = u16(atlas), height = u16(atlas)},
					bytesPerLine = u16(atlas),
					buffer = raw_data(bitmap),
				}
				sce.scePvfGetCharGlyphImage_Clip(font, code, &image, x, y, u32(width), u32(height))
			}

			glyphs[i] = Baked_Glyph {
				x0 = u16(x),
				y0 = u16(y),
				x1 = u16(x + width),
				y1 = u16(y + height),
				xoff = f32(left),
				yoff = -f32(top), // y down from the baseline, as stb gives it
				xadvance = f32(metrics.horizontalAdvance64) / 64,
			}

			x += width + 1
			row_height = max(row_height, height)
		}
		return y + row_height + 1
	}

	@(private="file")
	pvf_allocate :: proc "c" (user:rawptr, size:u32) -> rawptr {
		return malloc(uint(size))
	}

	@(private="file")
	pvf_reallocate :: proc "c" (user:rawptr, pointer:rawptr, size:u32) -> rawptr {
		return realloc(pointer, uint(size))
	}

	@(private="file")
	pvf_free :: proc "c" (user:rawptr, pointer:rawptr) {
		free(pointer)
	}
}
