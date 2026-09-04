package matchbox

import "core:math"

import stbtt "vendor:stb/truetype"

/*
	Font
	----
	Baking a TTF into an atlas, and keeping a few sizes of the default one.

	Drawing with a Font lives in `text.odin` -- this file is the asset and its
	cache, that one is everything that puts glyphs on screen.
*/

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
get_font_cache_len :: proc() -> int {
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
destroy_font_cache :: proc() {
	for _, cached in mbi.font_cache.sizes {
		destroy_font(cached.font)
		free(cached.font)
	}

	delete(mbi.font_cache.sizes)
	delete(mbi.font_cache.order)

	mbi.font_cache = {}
}
