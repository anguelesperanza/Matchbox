package vita2d

// Sharp system-font text at any size. Hand-written; not part of libvita2d.
//
// PvfDrawText(font, ..., scale, ...) with a scale other than 1.0 stretches an
// 18 px glyph bitmap on the GPU. Below 1.0 that drops pixels and squeezes the
// letters together, so small text is hard to read (see bridge.c).
//
// DrawText keeps one copy of the default system font per size, each rasterised
// at its real size (PvfSetBaseScale), and always draws with scale 1.0.
//
//   v2d.DrawText(24, 40, white, 0.8, "small and sharp")
//
// Each size costs one font instance and a 512x512 glyph atlas (256 KiB of
// CDRAM), created the first time that size is used. Use a handful of fixed
// sizes, not a size that changes every frame. Call FreeSizedFonts at shutdown,
// after WaitRenderingDone.

MAX_SIZED_FONTS :: 8

@(private = "file") Sized_Font :: struct {
    scale: f32,
    font:  ^Pvf,
}
@(private = "file") sized_fonts: [MAX_SIZED_FONTS]Sized_Font
@(private = "file") sized_count: int

// The default system font rasterised at `scale` (1.0 is 18 px tall). Returns
// nil if the font cannot be loaded. Draw with it at scale 1.0. Do not free it
// yourself; FreeSizedFonts does. When all MAX_SIZED_FONTS slots are in use,
// the font with the nearest size is returned instead.
PvfSized :: proc "contextless" (scale: f32) -> ^Pvf {
    for i in 0 ..< sized_count {
        if sized_fonts[i].scale == scale do return sized_fonts[i].font
    }
    if sized_count == MAX_SIZED_FONTS {
        best := 0
        best_d := abs(sized_fonts[0].scale - scale)
        for i in 1 ..< sized_count {
            d := abs(sized_fonts[i].scale - scale)
            if d < best_d {
                best, best_d = i, d
            }
        }
        return sized_fonts[best].font
    }
    font := LoadDefaultPvf()
    if font == nil do return nil
    PvfSetBaseScale(font, scale)
    sized_fonts[sized_count] = {scale, font}
    sized_count += 1
    return font
}

// Draws text with the default system font at `scale`. x, y is the left end of
// the baseline. Returns what PvfDrawText returns (the width drawn), or 0 if
// the font could not be loaded.
DrawText :: proc "contextless" (x, y: i32, color: u32, scale: f32, text: cstring) -> i32 {
    font := PvfSized(scale)
    if font == nil do return 0
    return PvfDrawText(font, x, y, color, 1.0, text)
}

// Width in pixels of `text` as DrawText would draw it.
TextWidth :: proc "contextless" (scale: f32, text: cstring) -> i32 {
    font := PvfSized(scale)
    if font == nil do return 0
    return PvfTextWidth(font, 1.0, text)
}

// Frees every font DrawText / PvfSized created. Call WaitRenderingDone first.
FreeSizedFonts :: proc "contextless" () {
    for i in 0 ..< sized_count {
        FreePvf(sized_fonts[i].font)
        sized_fonts[i] = {}
    }
    sized_count = 0
}
