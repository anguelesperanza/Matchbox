package matchbox

import "core:math"
import "core:strings"
import "core:strconv"

import "base:intrinsics"

import "core:fmt"

import stbtt "vendor:stb/truetype"

// -----------------------------------------------------------------------
// Font
// -----------------------------------------------------------------------

// The font init bakes as mbi.font, and the one get_font bakes at other sizes.
// Exposed so a game can build its own set out of it, or measure against it
// without going through the cache.
DEFAULT_FONT_BYTES :: #load("fonts/Adapa.ttf")

// What mbi.font is baked at. get_font hands that one back rather than baking a
// second copy of it.
//
// A multiple of 13, and not the rounder 32, because the default font is a pixel
// font drawn on a 13-pixel em: at 26 every one of its design pixels covers
// exactly two screen pixels, and at anything between two multiples the stems
// come out as an uneven mix of two and three pixels with grey down one side.
// The same holds for any size asked of get_font -- 13, 26, 39, 52.
FONT_DEFAULTS :: Font_Defaults{
	size         = 26,
	line_spacing = 0.15,
	cache_limit  = 6,
}

Font :: struct {
	using mesh:  Mesh,
	baked_chars: [FONT_GLYPH_COUNT]stbtt.bakedchar,
	atlas_size:  i32,

	size:        f32, // pixel size the glyphs were baked at
	ascent:      f32, // baseline up to the tallest glyph
	descent:     f32, // baseline down to the lowest glyph
}

/*
	Bakes a TTF into an atlas at one pixel size.

	One size per atlas, because stb bakes glyphs at a fixed size rather than
	scaling them -- drawing a 26px atlas at 64px is a blurry 26px atlas. A game
	wanting several sizes calls `get_font`, which keeps a small cache of them.

	`bytes` is the file's contents, so `#load` works and the font ships inside
	the executable.
*/
load_font :: proc(bytes: []byte, font_size: f32) -> Font {
	font: Font
	font.atlas_size = FONT_ATLAS_SIZE

	// Bake all printable ASCII glyphs into a grayscale bitmap
	bitmap := make([]u8, FONT_ATLAS_SIZE * FONT_ATLAS_SIZE)
	defer delete(bitmap)
	stbtt.BakeFontBitmap(raw_data(bytes), 0, font_size, raw_data(bitmap), FONT_ATLAS_SIZE, FONT_ATLAS_SIZE, FONT_FIRST_GLYPH, FONT_GLYPH_COUNT, raw_data(font.baked_chars[:]))

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

// Gives the font's atlas texture and vertex buffer back to the GPU.
destroy_font :: proc(font: ^Font) {
	destroy_mesh(&font.mesh)
}

@(private)
trim_plus :: proc(s: string) -> string {
	return s[1:] if len(s) > 0 && s[0] == '+' else s
}

// An integer, without the caller building a string for it. Part of the
// `draw_text` group.
draw_text_i64 :: proc(font: ^Font, integer: i64, x: f32, y: f32, color: [4]f32) {
    buf: [256]u8
    result := strconv.write_int(buf[:], integer, 10)
    draw_text_string(font, result[:], x, y, color)
}

/*
	`strconv.write_float`'s leading sign, dropped when it is a plus and kept
	when it is a minus.

	`write_float` always writes a sign, so "3.14" comes back as "+3.14" and has
	to be trimmed. Trimming it as `result[1:]` is the obvious thing and it is
	wrong: it takes whichever character is first, so -8.5 draws as "8.50". On a
	position readout that is half the values on screen rendering as their own
	mirror image, with nothing on screen to say so.
*/

draw_text_2_i64 :: proc(font: ^Font, integers:[2]i64, x:f32, y:f32, color:[4]f32, separator:string = " ") {
	
	buf_one: [256]u8
	buf_two: [256]u8

	result_one := strconv.write_int(buf_one[:], integers[0], 10)
	result_two := strconv.write_int(buf_two[:], integers[1], 10)

	// Temp, not the context allocator: this is a draw call, so a game showing a
	// position every frame would otherwise leak a string per frame forever. The
	// temp allocator is reset at the end of the frame, which is exactly as long
	// as the text needs to live.
	text, _ := strings.concatenate({trim_plus(result_one), separator, trim_plus(result_two)},context.temp_allocator)

	draw_text_string(font = font, text = text, x = x, y = y, color = color)
}

// Two floats separated by `separator` -- a position or a size, without the
// caller building a string for it. Part of the `draw_text` group.
draw_text_2_float :: proc(font: ^Font, float: [2]$T, x: f32, y: f32, color: [4]f32, separator: string = " ") {
	buf_one: [256]u8
	buf_two: [256]u8

	result_one := strconv.write_float(buf_one[:], cast(f64)float[0], 'f', 2, 64)
	result_two := strconv.write_float(buf_two[:], cast(f64)float[1], 'f', 2, 64)

	// Temp, not the context allocator: this is a draw call, so a game showing a
	// position every frame would otherwise leak a string per frame forever. The
	// temp allocator is reset at the end of the frame, which is exactly as long
	// as the text needs to live.
	text, _ := strings.concatenate({trim_plus(result_one), separator, trim_plus(result_two)},
		context.temp_allocator)

	draw_text_string(font = font, text = text, x = x, y = y, color = color)
}



// A float at two decimal places, without the caller building a string. Part of
// the `draw_text` group.
draw_text_float :: proc(font: ^Font, float: $T, x: f32, y: f32, color: [4]f32) where intrinsics.type_is_float(T) {
    buf: [256]u8
    result := strconv.write_float(buf[:], cast(f64)float, 'f', 2, 64)
    draw_text_string(font, trim_plus(result), x, y, color)
}


// A string at a position, in world coordinates -- so it moves with the camera
// and scales with the letterbox. `draw_text_ui` is the one that does not.
//
// `x` and `y` are the left end of the baseline, not the top-left corner.
draw_text_string :: proc(font: ^Font, text: string, x: f32, y: f32, color: [4]f32) {
	// Bound once for the whole string. The pipeline, the shared quad and the
	// atlas are the same for every character in it -- only the uniforms differ.
	if !bind_quad_state(mbi.renderer.pipelines.font, font.texture, font.sampler) do return

	// Once for the whole string, not once per glyph. A pushed uniform block stays
	// in force for every draw after it until something pushes over it, and the
	// colour is the same for every character -- so this was the same sixteen
	// bytes handed over twenty times for a twenty character line.
	frag_data := Font_Frag_Data{color = color}
	push_frag_uniform(&frag_data, size_of(frag_data))

	cursor_x := x
	cursor_y := y

	for ch in text {
		if ch < FONT_FIRST_GLYPH || ch >= FONT_FIRST_GLYPH + FONT_GLYPH_COUNT {
			continue
		}

		q: stbtt.aligned_quad
		stbtt.GetBakedQuad(raw_data(font.baked_chars[:]), font.atlas_size, font.atlas_size, cast(i32)ch - FONT_FIRST_GLYPH, &cursor_x, &cursor_y, &q, true)

		pos  := [2]f32{(q.x0 + q.x1) * 0.5, (q.y0 + q.y1) * 0.5}
		size := [2]f32{q.x1 - q.x0, q.y1 - q.y0}

		vert_data := Vert_Data{
			position = screen_pos(pos),
			size     = screen_size(size),
			screen   = screen_dims(),
			uv_min   = {q.s0, q.t0},
			uv_max   = {q.s1, q.t1},
		}

		push_quad(&vert_data, nil, 0)
	}
}

// Draws a string, an integer or a float, so a game does not build a string for
// a number it wants on screen.
draw_text :: proc {
	draw_text_string,
	draw_text_i64,
	draw_text_float,
	draw_text_2_float,
}

// How much room `text` takes up when drawn with draw_text.
//
// The height is the font's ascent plus descent rather than the extent of these
// particular glyphs, so "Play" and "Play Card" measure the same height and a
// line of text does not shift about vertically as its content changes.
measure_text :: proc(font: ^Font, text: string) -> [2]f32 {
	width: f32
	for ch in text {
		if ch < FONT_FIRST_GLYPH || ch >= FONT_FIRST_GLYPH + FONT_GLYPH_COUNT {
			continue
		}
		width += font.baked_chars[cast(int)ch - FONT_FIRST_GLYPH].xadvance
	}
	return {width, font.ascent + font.descent}
}

// Screen-space text — coordinates and glyph size are in actual window pixels,
// draw_scale is NOT applied.  Use this for HUD / UI text when set_logical_size
// is active, so the font renders at its native baked size instead of being
// upscaled by the logical-resolution multiplier.
draw_text_ui_string :: proc(font: ^Font, text: string, x: f32, y: f32, color: [4]f32) {
	// Bound once for the whole string, as in draw_text_string, and the colour
	// pushed once for the same reason.
	if !bind_quad_state(mbi.renderer.pipelines.font, font.texture, font.sampler) do return

	frag_data := Font_Frag_Data{color = color}
	push_frag_uniform(&frag_data, size_of(frag_data))

	cursor_x := x
	cursor_y := y

	for ch in text {
		if ch < FONT_FIRST_GLYPH || ch >= FONT_FIRST_GLYPH + FONT_GLYPH_COUNT {
			continue
		}

		q: stbtt.aligned_quad
		stbtt.GetBakedQuad(raw_data(font.baked_chars[:]), font.atlas_size, font.atlas_size, cast(i32)ch - FONT_FIRST_GLYPH, &cursor_x, &cursor_y, &q, true)

		pos  := [2]f32{(q.x0 + q.x1) * 0.5, (q.y0 + q.y1) * 0.5}
		size := [2]f32{q.x1 - q.x0, q.y1 - q.y0}

		// No screen_pos / screen_size here: that is what makes this the UI
		// variant, drawing at the font's baked size in window pixels.
		vert_data := Vert_Data{
			position = pos,
			size     = size,
			screen   = screen_dims(),
			uv_min   = {q.s0, q.t0},
			uv_max   = {q.s1, q.t1},
		}

		push_quad(&vert_data, nil, 0)
	}
}

// An integer in screen coordinates. Part of the `draw_text_ui` group.
draw_text_ui_int :: proc(font: ^Font, integer: i64, x: f32, y: f32, color: [4]f32) {
    buf: [256]u8
    result := strconv.write_int(buf[:], integer, 10)
    draw_text_ui_string(font, result[:], x, y, color)
}

// A float in screen coordinates, two decimal places. Part of the
// `draw_text_ui` group.
draw_text_ui_f32 :: proc(font: ^Font, float: f32, x: f32, y: f32, color: [4]f32) {
    buf: [256]u8
    result := strconv.write_float(buf[:], cast(f64)float, 'f', 2, 64)
    draw_text_ui_string(font, trim_plus(result), x, y, color)
}

// `draw_text`, but in screen coordinates: fixed to the window and untouched by
// the camera. What a HUD, a score or a debug readout wants.
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
// Kept as a name rather than reached for through FONT_DEFAULTS at every use,
// because this one is compared against a length in a loop.
@(private)
font_cache_limit :: proc() -> int { return FONT_DEFAULTS.cache_limit }

@(private)
Cached_Font :: struct {
	font:    ^Font,
	used_on: u64, // the frame it was last handed out
}

/*
	Every baked size of the default font, and the order they were last asked
	for.

	The two are one thing: the map answers "have we got this size", the slice
	answers "which size goes first when we are over the limit", and neither is
	meaningful without the other. They lived at package scope until the cleanup
	pass; they are state belonging to `mbi` like everything else.
*/
@(private)
Font_Cache :: struct {
	sizes: map[i32]Cached_Font,
	order: [dynamic]i32, // least recently used first
}

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

	A size worked out off the window like that lands wherever it lands, which is
	fine for a face with curves in it and less fine for the default one -- Adapa
	is a pixel font on a 13-pixel em, and only multiples of 13 put its design
	pixels on whole screen pixels. Snapping to the nearest one keeps it crisp
	while still growing with the window:

		size := f32(matchbox.mbi.height) * 0.03
		font := matchbox.get_font(math.round(size / 13) * 13)

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
	if f32(px) == FONT_DEFAULTS.size do return &mbi.font

	if cached, found := mbi.font_cache.sizes[px]; found {
		cached.used_on = mbi.frame
		mbi.font_cache.sizes[px] = cached
		font_cache_touch(px)
		return cached.font
	}

	font  := new(Font)
	font^ = load_font(DEFAULT_FONT_BYTES, f32(px))

	mbi.font_cache.sizes[px] = Cached_Font{font = font, used_on = mbi.frame}
	append(&mbi.font_cache.order, px)

	// After inserting rather than before, so nothing is thrown out to make room
	// for something that then turns out to be resident already.
	font_cache_trim()

	return font
}

// How many extra sizes are resident, not counting the default one. For an
// example or a debug overlay that wants to show the cache doing its job.
font_cache_len :: proc() -> int {
	return len(mbi.font_cache.sizes)
}

@(private)
font_cache_touch :: proc(px: i32) {
	for k, i in mbi.font_cache.order {
		if k == px {
			ordered_remove(&mbi.font_cache.order, i)
			append(&mbi.font_cache.order, px)
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
	for len(mbi.font_cache.order) > font_cache_limit() {
		oldest := mbi.font_cache.order[0]

		if cached, found := mbi.font_cache.sizes[oldest]; found {
			// `mbi.frame > 0` matters: it is 0 until the first poll_events, and
			// so is every used_on recorded before then. Without it, sizes baked
			// during setup all look like they are in use by the frame that has
			// not started yet, and the limit does nothing at exactly the moment
			// a game is most likely to ask for a dozen sizes at once.
			if mbi.frame > 0 && cached.used_on == mbi.frame do return

			destroy_font(cached.font)
			free(cached.font)
			delete_key(&mbi.font_cache.sizes, oldest)
		}

		ordered_remove(&mbi.font_cache.order, 0)
	}
}

// Frees every cached size. Called by cleanup; a game does not need to.
@(private)
font_cache_destroy :: proc() {
	for _, cached in mbi.font_cache.sizes {
		destroy_font(cached.font)
		free(cached.font)
	}

	delete(mbi.font_cache.sizes)
	delete(mbi.font_cache.order)

	mbi.font_cache = {}
}
