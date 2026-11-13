package gfx

// Text, drawn from a font atlas made on the PC by tools/make_font.py: one PNG
// holding every glyph, and a small .fnt file saying where each one is.
//
//   font, ok := gfx.load_font(#load("assets/font.png"), #load("assets/font.fnt"))
//   ...
//   gfx.begin_2d()
//   gfx.draw_text(&font, 16, 40, "Hello", gfx.WHITE)
//   gfx.end_2d()
//
// A glyph is a picture, so text is sharpest at the size the atlas was made
// for (scale 1) and softer the further it is scaled. Bake an atlas per size
// that matters; they are small.

// One entry of a .fnt file. All values are little-endian, in atlas pixels.
@(private) Glyph :: struct {
    codepoint: u32,
    x, y:      u16, // top left corner in the atlas
    w, h:      u16,
    offset_x:  i16, // from the pen position to the glyph's left edge
    offset_y:  i16, // from the baseline up to the glyph's top edge (positive is up)
    advance:   i16, // how far the pen moves, in 1/64 pixel
    _:         u16,
}
#assert(size_of(Glyph) == 20)

@(private) Font_Header :: struct {
    magic:       [4]u8, // "VFNT"
    version:     u16,
    glyph_count: u16,
    line_height: i16,
    ascent:      i16,
    size:        u16, // the pixel size the atlas was made for
    _:           u16,
}
#assert(size_of(Font_Header) == 16)

Font :: struct {
    texture:     Texture,
    glyphs:      []Glyph, // sorted by codepoint
    line_height: f32,     // distance between two lines' baselines
    ascent:      f32,     // from the baseline to the top of the tallest glyph
    size:        f32,
    memory:      rawptr,
}

// Loads a font from the two files tools/make_font.py writes.
load_font :: proc "contextless" (png: []u8, fnt: []u8) -> (font: Font, ok: bool) {
    if len(fnt) < size_of(Font_Header) do return {}, false
    header: Font_Header
    copy(([^]u8)(&header)[:size_of(Font_Header)], fnt)
    if header.magic != {'V', 'F', 'N', 'T'} || header.version != 1 do return {}, false
    count := int(header.glyph_count)
    if len(fnt) < size_of(Font_Header) + count * size_of(Glyph) do return {}, false

    font.texture = load_png(png, .LINEAR, .CLAMP) or_return
    // The glyph table is copied: #load data is not guaranteed to be aligned.
    font.memory = c_malloc(uint(count * size_of(Glyph)))
    if font.memory == nil {
        destroy_texture(&font.texture)
        return {}, false
    }
    font.glyphs = ([^]Glyph)(font.memory)[:count]
    copy(([^]u8)(font.memory)[:count * size_of(Glyph)], fnt[size_of(Font_Header):])
    font.line_height = f32(header.line_height)
    font.ascent      = f32(header.ascent)
    font.size        = f32(header.size)
    return font, true
}

// The GPU must be done with the font's texture (gfx.finish).
destroy_font :: proc "contextless" (font: ^Font) {
    destroy_texture(&font.texture)
    c_free(font.memory)
    font^ = {}
}

// Draws UTF-8 text. x is the left edge and y the baseline of the first line;
// "\n" starts a new line. Characters the font does not have are drawn as '?'.
// Returns the width of the widest line in pixels.
draw_text :: proc "contextless" (font: ^Font, x, y: f32, text: string, color := WHITE, scale: f32 = 1) -> f32 {
    return layout_text(font, x, y, text, color, scale, true)
}

// The width and height the text would take, without drawing it.
measure_text :: proc "contextless" (font: ^Font, text: string, scale: f32 = 1) -> (width, height: f32) {
    lines := 1
    for r in text do if r == '\n' do lines += 1
    return layout_text(font, 0, 0, text, WHITE, scale, false), f32(lines) * font.line_height * scale
}

@(private)
layout_text :: proc "contextless" (font: ^Font, x, y: f32, text: string, color: Color, scale: f32, draw: bool) -> f32 {
    pen_x, pen_y := x, y
    widest: f32
    inverse_w, inverse_h := 1 / f32(font.texture.width), 1 / f32(font.texture.height)
    for r in text {
        if r == '\n' {
            widest = max(widest, pen_x - x)
            pen_x = x
            pen_y += font.line_height * scale
            continue
        }
        glyph := find_glyph(font, u32(r))
        if glyph == nil do glyph = find_glyph(font, '?')
        if glyph == nil do continue
        if draw && glyph.w > 0 && glyph.h > 0 {
            // Whole pixels at scale 1, so glyphs stay sharp.
            left := pen_x + f32(glyph.offset_x) * scale
            top  := pen_y - f32(glyph.offset_y) * scale
            if scale == 1 {
                left = f32(i32(left + 0.5))
                top  = f32(i32(top + 0.5))
            }
            right, bottom := left + f32(glyph.w) * scale, top + f32(glyph.h) * scale
            push_quad(&font.texture, {{left, top}, {right, top}, {right, bottom}, {left, bottom}},
                      {f32(glyph.x) * inverse_w, f32(glyph.y) * inverse_h,
                       f32(glyph.x + glyph.w) * inverse_w, f32(glyph.y + glyph.h) * inverse_h}, color)
        }
        pen_x += f32(glyph.advance) / 64 * scale
    }
    return max(widest, pen_x - x)
}

@(private)
find_glyph :: proc "contextless" (font: ^Font, codepoint: u32) -> ^Glyph {
    low, high := 0, len(font.glyphs) - 1
    for low <= high {
        middle := (low + high) / 2
        value := font.glyphs[middle].codepoint
        switch {
        case value == codepoint: return &font.glyphs[middle]
        case value < codepoint:  low = middle + 1
        case:                    high = middle - 1
        }
    }
    return nil
}
