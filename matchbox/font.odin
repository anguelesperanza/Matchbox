package matchbox

import "core:math"
import "core:strconv"

import "base:intrinsics"

import stbtt "vendor:stb/truetype"

// -----------------------------------------------------------------------
// Font
// -----------------------------------------------------------------------

// The font init bakes as mbi.font, and the one get_font bakes at other sizes.
// Exposed so a game can build its own set out of it, or measure against it
// without going through the cache.
DEFAULT_FONT_BYTES :: #load("fonts/Silver.ttf")

// What mbi.font is baked at. get_font hands that one back rather than baking a
// second copy of it.
DEFAULT_FONT_SIZE :: f32(32)

Font :: struct {
	using mesh:  Mesh,
	baked_chars: [96]stbtt.bakedchar,
	atlas_size:  i32,

	size:        f32, // pixel size the glyphs were baked at
	ascent:      f32, // baseline up to the tallest glyph
	descent:     f32, // baseline down to the lowest glyph
}

load_font :: proc(bytes: []byte, font_size: f32) -> Font {
	font: Font
	font.atlas_size = FONT_ATLAS_SIZE

	// Bake all printable ASCII glyphs into a grayscale bitmap
	bitmap := make([]u8, FONT_ATLAS_SIZE * FONT_ATLAS_SIZE)
	defer delete(bitmap)
	stbtt.BakeFontBitmap(raw_data(bytes), 0, font_size, raw_data(bitmap), FONT_ATLAS_SIZE, FONT_ATLAS_SIZE, 32, 96, raw_data(font.baked_chars[:]))

	// draw_text takes a baseline for its y, so anything positioning text against
	// the top of a box needs the ascent to shift by. Measured off the glyphs that
	// were actually baked -- yoff is the baseline-to-glyph-top offset, negative up.
	font.size = font_size
	for c in font.baked_chars {
		font.ascent  = max(font.ascent,  -c.yoff)
		font.descent = max(font.descent, c.yoff + (f32(c.y1) - f32(c.y0)))
	}

	// Expand grayscale to RGBA — white RGB, font mask as alpha
	rgba := make([]u8, FONT_ATLAS_SIZE * FONT_ATLAS_SIZE * 4)
	defer delete(rgba)
	for i in 0..<FONT_ATLAS_SIZE * FONT_ATLAS_SIZE {
		rgba[i*4 + 0] = 255
		rgba[i*4 + 1] = 255
		rgba[i*4 + 2] = 255
		rgba[i*4 + 3] = bitmap[i]
	}

	// Linear filtering, unlike a sprite's nearest: glyph quads rarely land on
	// whole pixels, and the atlas is a coverage mask that reads badly when it
	// is point sampled.
	font.texture = upload_texture(raw_data(rgba), FONT_ATLAS_SIZE, FONT_ATLAS_SIZE)
	font.sampler = mbi.renderer.font_sampler
	font.width   = FONT_ATLAS_SIZE
	font.height  = FONT_ATLAS_SIZE

	return font
}

destroy_font :: proc(font: ^Font) {
	destroy_mesh(&font.mesh)
}

draw_text_i64 :: proc(font: ^Font, integer: i64, x: f32, y: f32, color: [4]f32) {
    buf: [256]u8
    result := strconv.write_int(buf[:], integer, 10)
    draw_text_string(font, result[:], x, y, color)
}


draw_text_float :: proc(font: ^Font, float: $T, x: f32, y: f32, color: [4]f32) where intrinsics.type_is_float(T) {
    buf: [256]u8
    result := strconv.write_float(buf[:], cast(f64)float, 'f', 2, 64)
    draw_text_string(font, result[1:], x, y, color)
}


draw_text_string :: proc(font: ^Font, text: string, x: f32, y: f32, color: [4]f32) {
	// Bound once for the whole string. The pipeline, the shared quad and the
	// atlas are the same for every character in it -- only the uniforms differ.
	if !bind_quad_state(mbi.renderer.pipelines.font, font.texture, font.sampler) do return

	cursor_x := x
	cursor_y := y

	for ch in text {
		if ch < 32 || ch >= 128 {
			continue
		}

		q: stbtt.aligned_quad
		stbtt.GetBakedQuad(raw_data(font.baked_chars[:]), font.atlas_size, font.atlas_size, cast(i32)ch - 32, &cursor_x, &cursor_y, &q, true)

		pos  := [2]f32{(q.x0 + q.x1) * 0.5, (q.y0 + q.y1) * 0.5}
		size := [2]f32{q.x1 - q.x0, q.y1 - q.y0}

		vert_data := VertData{
			position = screen_pos(pos),
			size     = screen_size(size),
			screen   = screen_dims(),
			uv_min   = {q.s0, q.t0},
			uv_max   = {q.s1, q.t1},
		}

		frag_data := FontFragData{color = color}

		push_quad(&vert_data, &frag_data, size_of(frag_data))
	}
}

draw_text :: proc {
	draw_text_string,
	draw_text_i64,
	draw_text_float
}

// How much room `text` takes up when drawn with draw_text.
//
// The height is the font's ascent plus descent rather than the extent of these
// particular glyphs, so "Play" and "Play Card" measure the same height and a
// line of text does not shift about vertically as its content changes.
measure_text :: proc(font: ^Font, text: string) -> [2]f32 {
	width: f32
	for ch in text {
		if ch < 32 || ch >= 128 {
			continue
		}
		width += font.baked_chars[cast(int)ch - 32].xadvance
	}
	return {width, font.ascent + font.descent}
}

// Screen-space text — coordinates and glyph size are in actual window pixels,
// draw_scale is NOT applied.  Use this for HUD / UI text when set_logical_size
// is active, so the font renders at its native baked size instead of being
// upscaled by the logical-resolution multiplier.
draw_text_ui_string :: proc(font: ^Font, text: string, x: f32, y: f32, color: [4]f32) {
	// Bound once for the whole string, as in draw_text_string.
	if !bind_quad_state(mbi.renderer.pipelines.font, font.texture, font.sampler) do return

	cursor_x := x
	cursor_y := y

	for ch in text {
		if ch < 32 || ch >= 128 {
			continue
		}

		q: stbtt.aligned_quad
		stbtt.GetBakedQuad(raw_data(font.baked_chars[:]), font.atlas_size, font.atlas_size, cast(i32)ch - 32, &cursor_x, &cursor_y, &q, true)

		pos  := [2]f32{(q.x0 + q.x1) * 0.5, (q.y0 + q.y1) * 0.5}
		size := [2]f32{q.x1 - q.x0, q.y1 - q.y0}

		// No screen_pos / screen_size here: that is what makes this the UI
		// variant, drawing at the font's baked size in window pixels.
		vert_data := VertData{
			position = pos,
			size     = size,
			screen   = screen_dims(),
			uv_min   = {q.s0, q.t0},
			uv_max   = {q.s1, q.t1},
		}

		frag_data := FontFragData{color = color}

		push_quad(&vert_data, &frag_data, size_of(frag_data))
	}
}

draw_text_ui_int :: proc(font: ^Font, integer: i64, x: f32, y: f32, color: [4]f32) {
    buf: [256]u8
    result := strconv.write_int(buf[:], integer, 10)
    draw_text_ui_string(font, result[:], x, y, color)
}

draw_text_ui_f32 :: proc(font: ^Font, float: f32, x: f32, y: f32, color: [4]f32) {
    buf: [256]u8
    result := strconv.write_float(buf[:], cast(f64)float, 'f', 2, 64)
    draw_text_ui_string(font, result[1:], x, y, color)
}

draw_text_ui :: proc {
    draw_text_ui_string,
    draw_text_ui_int,
    draw_text_ui_f32,
}

// -----------------------------------------------------------------------
// More than one size
// -----------------------------------------------------------------------

/*
	Fonts baked at sizes other than the default, kept so asking for one every
	frame costs one bake.

	The limit is on how many *sizes* are resident, and it is small because each
	one is a 512x512 RGBA atlas -- a megabyte of texture per size. Six covers a
	screen with a title, a heading, body text, a caption and a couple of odd
	ones, and a game wanting more than that wants its own set rather than a
	cache with a bigger number in it.

	Eviction is least-recently-used, and never touches a size that has been
	asked for during the current frame -- see font_cache_trim.
*/
FONT_CACHE_LIMIT :: 6

@(private)
Cached_Font :: struct {
	font:    ^Font,
	used_on: u64, // the frame it was last handed out
}

@(private)
font_cache: map[i32]Cached_Font

@(private)
font_cache_order: [dynamic]i32 // least recently used first

/*
	The default font baked at `size` pixels.

	`init` bakes one atlas at 32 and never rebuilds it, which is why text used to
	be the one thing on screen that did not scale: a layout worked out as a
	fraction of the window had to treat the line height as a fixed constant and
	arrange itself around it. On a large display everything grew except the
	words.

	Ask for a size off the window and the words grow with it:

		font := matchbox.get_font(f32(matchbox.mbi.height) * 0.03)
		matchbox.draw_text(font, name, x, y, matchbox.WHITE)

	Sizes are rounded to whole pixels, since that is the resolution stb bakes
	at, so a window being dragged rebakes only when it crosses a pixel and not
	on every frame of the drag.

	**The pointer is good for the frame it was asked in.** It is a cache with a
	limit, and something has to be given up when the limit is reached -- but
	nothing asked for during the current frame is ever the thing given up, so
	holding one across a few draw calls is safe and holding one in a struct
	between frames is not. Ask again; a hit costs a map lookup.
*/
get_font :: proc(size: f32) -> ^Font {
	px := i32(math.round(size))
	if px < 1 do px = 1

	// The one init already baked. Handing back a second copy of it would be a
	// megabyte of atlas to say the same thing.
	if f32(px) == DEFAULT_FONT_SIZE do return &mbi.font

	if cached, found := font_cache[px]; found {
		cached.used_on = mbi.frame
		font_cache[px] = cached
		font_cache_touch(px)
		return cached.font
	}

	font  := new(Font)
	font^ = load_font(DEFAULT_FONT_BYTES, f32(px))

	font_cache[px] = Cached_Font{font = font, used_on = mbi.frame}
	append(&font_cache_order, px)

	// After inserting rather than before, so nothing is thrown out to make room
	// for something that then turns out to be resident already.
	font_cache_trim()

	return font
}

// How many extra sizes are resident, not counting the default one. For an
// example or a debug overlay that wants to show the cache doing its job.
font_cache_len :: proc() -> int {
	return len(font_cache)
}

@(private)
font_cache_touch :: proc(px: i32) {
	for k, i in font_cache_order {
		if k == px {
			ordered_remove(&font_cache_order, i)
			append(&font_cache_order, px)
			return
		}
	}
}

/*
	Evicts from the least-recently-used end until the limit is met.

	Stops at anything used during the current frame, whatever the limit says.
	A screen drawing seven sizes would otherwise free the atlas belonging to a
	pointer it handed out moments earlier and is still drawing through -- the
	cache would be doing exactly what it was told and the game would be reading
	a released texture. Going one over the limit for a frame is the cheaper
	mistake, and the extra is collected as soon as the screen stops asking.
*/
@(private)
font_cache_trim :: proc() {
	for len(font_cache_order) > FONT_CACHE_LIMIT {
		oldest := font_cache_order[0]

		if cached, found := font_cache[oldest]; found {
			// `mbi.frame > 0` matters: it is 0 until the first poll_events, and
			// so is every used_on recorded before then. Without it, sizes baked
			// during setup all look like they are in use by the frame that has
			// not started yet, and the limit does nothing at exactly the moment
			// a game is most likely to ask for a dozen sizes at once.
			if mbi.frame > 0 && cached.used_on == mbi.frame do return

			destroy_font(cached.font)
			free(cached.font)
			delete_key(&font_cache, oldest)
		}

		ordered_remove(&font_cache_order, 0)
	}
}

// Frees every cached size. Called by cleanup; a game does not need to.
@(private)
font_cache_destroy :: proc() {
	for _, cached in font_cache {
		destroy_font(cached.font)
		free(cached.font)
	}

	delete(font_cache)
	delete(font_cache_order)

	font_cache       = nil
	font_cache_order = nil
}
