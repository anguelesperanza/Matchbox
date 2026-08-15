package matchbox

import "core:log"

import sdl "vendor:sdl3"

// -----------------------------------------------------------------------
// Types -- GPU data
// -----------------------------------------------------------------------

/*
	Uniform blocks.

	These are pushed straight into SDL3's per-frame uniform ring with
	PushGPU*UniformData, so each one has to match the cbuffer its shader
	declares byte for byte. The packing rule that governs the layouts below is
	that a float2 may not straddle a 16-byte boundary -- get it wrong and the
	result is silently wrong colours or geometry rather than an error, which is
	why every struct here carries its size in a comment and init asserts it.

	The old bindless layout is gone: no `verts` pointer (there is a real vertex
	buffer now) and no texture/sampler ids (they are bound to the pass).
*/

Vertex :: struct {
	pos: [3]f32,
	uv:  [2]f32,
}

// 48 bytes: (position,size) (screen,uv_min) (uv_max,rotation,pad).
// Shared by every draw -- sprites, rects, outlines and glyphs all go through
// the one vertex shader, so the separate FontVertData is gone.
VertData :: struct #align(16) {
	position: [2]f32,
	size:     [2]f32,
	screen:   [2]f32,
	uv_min:   [2]f32,
	uv_max:   [2]f32,
	rotation: f32,
	_pad:     f32,
}

// 32 bytes: (tint) (desaturate, pad).
//
// Flipping is not in here -- that is a swap of uv_min/uv_max in VertData. What
// is, is the tint, which a sprite had no way of carrying at all: the only way
// to dim one was a translucent rectangle drawn over the top, which is an extra
// draw that can only ever darken.
Sprite_Frag_Data :: struct #align(16) {
	color:      [4]f32,
	desaturate: f32,
	_pad:       [3]f32,
}

// 48 bytes: (color) (p0,p1) (p2,kind,thickness).
//
// The triangle's corners are in the quad's own uv space, because the quad is
// the shape's bounding box -- see draw_triangle for the mapping. `thickness` is
// in pixels and converted inside the shader, which is the one place that knows
// how big a pixel is after rotation, zoom and the letterbox.
Shape_Frag_Data :: struct #align(16) {
	color:     [4]f32,
	p0:        [2]f32,
	p1:        [2]f32,
	p2:        [2]f32,
	kind:      f32,
	thickness: f32,
}

SHAPE_ELLIPSE  :: f32(0)
SHAPE_TRIANGLE :: f32(1)

// 32 bytes: (color) (border, pad).
//
// `border` is a half-extent in UV given per axis, not the single fraction the
// old version took. See draw_outline for why that changed.
OutlineFragData :: struct #align(16) {
	color:  [4]f32,
	border: [2]f32,
	_pad:   [2]f32,
}

// 16 bytes.
FontFragData :: struct #align(16) {
	color: [4]f32,
}

// 16 bytes.
Rect_Frag_Data :: struct #align(16) {
	color: [4]f32,
}

// GPU handle bundle — shared by Sprite, AnimationClip, and Font.
//
// The quad's vertices and indices used to live here, one identical copy per
// mesh. There is now a single shared quad on the Renderer, so all a mesh owns
// is its texture. Width and height are kept alongside because an
// SDL_GPUTexture will not report its own dimensions back.
Mesh :: struct {
	texture: ^sdl.GPUTexture,
	sampler: ^sdl.GPUSampler,
	width:   i32,
	height:  i32,
}

// Transform + physics + uv — shared by Sprite and AnimatedSprite.
// No stored bounding_box: it is derived on demand by sprite_bounds().
Body :: struct {
	position:             [2]f32,
	size:                 [2]f32,
	velocity:             [2]f32,
	pivot:                [2]f32,
	uv_min:               [2]f32,
	uv_max:               [2]f32,
	bounding_box_padding: [4]f32,
	speed:                f32,
	jump_force:           f32,
	scale:                f32,
	rotation:             f32,

	// Multiplied into every pixel of the sprite. The zero value {0,0,0,0} means
	// "as it was painted" rather than "transparent black", because a struct that
	// has not been filled in has to draw the picture and not a hole. Fading out
	// is {1,1,1,a}, which is never all-zero, so the two do not collide.
	tint:                 [4]f32,

	// 0 leaves the colours alone, 1 takes them to grey. Separate from `tint`
	// because a multiply cannot remove saturation, only add or subtract it.
	desaturate:           f32,
	flip_x:               bool,
	flip_y:               bool,
	on_ground:            bool,
}

// -----------------------------------------------------------------------
// Types -- Application
// -----------------------------------------------------------------------

Rectangle :: struct {
	position: [2]f32,
	size:     [2]f32,
	color:    [4]f32,
	rotation: f32,

	// Fraction of `size` added to `position` to reach the centre. Note this is
	// the opposite way round from most engines, and matches Body: {0, 0} -- the
	// zero value -- means `position` already is the centre, and {0.5, 0.5} means
	// `position` is the top-left corner. Go through rect_center / rect_top_left
	// rather than reading `position` directly.
	pivot:    [2]f32,
}

ParallaxSprites :: struct {
	sprites:[dynamic]Sprite
}

// Every piece of state Matchbox needs to run, grouped by subsystem. There is
// exactly one of these -- the package-level `mbi` -- so nothing has to be
// threaded through procedure arguments.
//
// `display` and `clock` are `using` so the fields games reach for most often
// stay flat: `mbi.delta_time`, `mbi.width`, `mbi.window`. `renderer` is left
// qualified because it is internal plumbing that games should not touch.
MatchboxInfo :: struct {
	using display: Display,  // window, logical resolution, letterbox transform
	using clock:   Clock,    // frame timing
	renderer:      Renderer, // shaders, descriptor pool, per-frame GPU state
	input:         Input,    // keyboard + mouse
	camera:        Camera,
	font:          Font,     // default font, loaded by init
	running:       bool,     // false once the window is closed or escape is hit
	initialized:   bool,     // set by init; guards against using a zeroed mbi

	// Installed by init only when the caller had not set one, so the gpu
	// layer's account of why it could not start reaches somebody. Kept here so
	// cleanup can take it down again.
	logger:        log.Logger,
}

// The one and only Matchbox state, filled in by init. Everything in the
// package reads and writes this directly rather than taking it as an argument.
//
// Games are free to read it -- `matchbox.mbi.delta_time`, `matchbox.mbi.running`
// -- or go through the accessors where one exists. A local alias also works if
// the qualified name gets tiresome:
//
//	mbi := &matchbox.mbi
//
// Consequence worth knowing: one global means one window. Matchbox cannot run
// two independent instances in a process.
mbi: MatchboxInfo

// -----------------------------------------------------------------------
// Constants
// -----------------------------------------------------------------------

FONT_ATLAS_SIZE :: 512

// -----------------------------------------------------------------------
// Colors
// -----------------------------------------------------------------------

PUMPKIN_ORANGE: [4]f32 = {.75, .30, 0, 1}
BLACK:          [4]f32 = {0, 0, 0, 1}
WHITE:          [4]f32 = {1, 1, 1, 1}
LIME_GREEN:     [4]f32 = {0.39, 0.58, 0.29, 1}
CORNFLOWER_BLUE:[4]f32 = {0.39, 0.58, 0.92, 1}
RED:            [4]f32 = {1, 0, 0, 1}
