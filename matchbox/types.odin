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
Vert_Data :: struct #align(16) {
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
// Flipping is not in here -- that is a swap of uv_min/uv_max in Vert_Data. What
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

/*
	Which shape `shape.frag` should draw, in the one uniform it has room for.

	An enum rather than the two bare floats it used to be. The cbuffer field is
	a `float` and has to stay one, so the value is converted at the call site --
	but the conversion is the only place a raw number appears, and nothing else
	can be passed by accident. The shader's own numbering is the enum's order,
	so adding a third shape means adding it here and to the switch in the
	fragment shader, in that order.
*/
Shape_Kind :: enum {
	ELLIPSE,
	TRIANGLE,
}

// 32 bytes: (color) (border, pad).
//
// `border` is a half-extent in UV given per axis, not the single fraction the
// old version took. See draw_outline for why that changed.
Outline_Frag_Data :: struct #align(16) {
	color:  [4]f32,
	border: [2]f32,
	_pad:   [2]f32,
}

// 16 bytes.
Font_Frag_Data :: struct #align(16) {
	color: [4]f32,
}

// 16 bytes.
Rect_Frag_Data :: struct #align(16) {
	color: [4]f32,
}

// -----------------------------------------------------------------------
// Types -- GPU data, 3D
// -----------------------------------------------------------------------

/*
	A vertex of a real mesh, as opposed to a corner of the shared quad.

	32 bytes, and the three attributes are the three every glTF primitive in
	either game carries: POSITION, NORMAL, TEXCOORD_0. Nothing here is optional
	-- a file that omits normals gets them generated at load rather than a
	second vertex layout and a second pipeline to go with it.
*/
Vertex3D :: struct {
	pos:    [3]f32,
	normal: [3]f32,
	uv:     [2]f32,
}

/*
	A vertex of a skinned mesh: the same three attributes, plus the four joints
	that move it and how much each of them gets a say.

	64 bytes, against Vertex3D's 32. A separate type and a separate pipeline
	rather than two more fields on Vertex3D, because every cube, plane, sphere
	and unskinned model in every game would otherwise carry twenty-four bytes of
	zeroes per vertex for a feature it does not use. The line pipeline set the
	precedent: a part knows what it is and the draw call picks accordingly.

	`joints` indexes the *skin's joint list*, not the node list -- see
	`Model_Skin`. glTF stores them as bytes or shorts and they are widened to
	`u32` here, to match the `uint4` the shader declares exactly.

	**They used to be `u16`, fed through a `USHORT4` vertex format, and that
	cost a long hunt.** The shader's input is a 32-bit `uint4`, so a 16-bit
	format leaves the fetch to widen -- which D3D12 did correctly and Vulkan
	did not, on the same data, from the same file. The symptom was a handful of
	vertices reading joint indices far outside the palette, and since an
	out-of-range uniform read is defined on D3D12 (zero) and undefined on
	Vulkan, one backend absorbed it and the other threw a vertex across the
	room. Matching the widths removes the conversion, and with it the
	divergence.

	It also makes the vertex 64 bytes rather than 56, so `joints` lands at
	offset 32 and `weights` at 48 -- both 16-byte aligned, where the old layout
	had a stride no wider alignment divided.
*/
Vertex3D_Skinned :: struct {
	pos:     [3]f32,
	normal:  [3]f32,
	uv:      [2]f32,
	joints:  [4]u32,
	weights: [4]f32,
}

/*
	Which slice of the joint buffer a skinned part's vertices read.

	Was a `[128]matrix[4,4]f32` pushed whole, once per skinned part -- a
	uniform, capped by SDL's Vulkan backend at `range = MAX_UBO_SECTION_SIZE`
	(4096 bytes, exactly 64 matrices) however much was actually pushed. D3D12's
	`UNIFORM_BUFFER_SIZE` is 32768 with no such sectioning, so the same file
	skinned correctly on Windows and threw geometry across the room on Linux --
	confirmed by measurement: forcing every vertex to joint 63 rendered a clean
	bind pose, forcing joint 64 destroyed the model, and an out-of-range
	uniform read is defined (zero) on D3D12 and undefined on Vulkan. See
	`refactor.md`'s "storage buffer" note for the full hunt.

	The palette is a `StructuredBuffer<float4x4>` now (`joints`, `t0 space0` in
	`mesh_skinned.vert.hlsl`), one per animator, holding every skinned part's
	palette back to back -- see `Model_Part.joint_offset`. A storage buffer has
	no 4KB sectioning, so what is pushed here shrank from the whole palette to
	just where this part's slice of it starts.
*/
Skin_Vert_Data :: struct #align(16) {
	joint_offset: u32,
}

// 192 bytes: three whole matrices, one after another.
//
// The normal matrix is 4x4 rather than the 3x3 it mathematically is, because a
// float3x3 in a cbuffer is three separate 16-byte rows with padding between
// them -- which is the packing trap this file exists to warn about, for the
// sake of saving 28 bytes once per draw.
Mesh_Vert_Data :: struct #align(16) {
	mvp:           matrix[4, 4]f32,
	model:         matrix[4, 4]f32,
	normal_matrix: matrix[4, 4]f32,
}

/*
	48 bytes: the camera's basis, ready to turn a screen position into a
	direction.

	`right` and `up` arrive already scaled by the field of view and the aspect,
	so the skybox vertex shader adds three vectors and is done -- no projection
	matrix, and no inverting one. Each is a [4]f32 rather than the [3]f32 it
	is, for the packing reason the top of this file exists to warn about.
*/
Skybox_Vert_Data :: struct #align(16) {
	right:   [4]f32,
	up:      [4]f32,
	forward: [4]f32,
}

// 16 bytes. The skybox's own fragment uniform -- a tint and nothing else, so
// it does not share `Material_Frag_Data` (material.odin) with the meshes:
// the sky is not a material and has no shading model to carry.
Tint_Frag_Data :: struct #align(16) {
	tint: [4]f32,
}

// 32 bytes. Shared by every post-processing shader, so one block serves all of
// them and an effect that ignores a field simply ignores it.
Post_Frag_Data :: struct #align(16) {
	resolution: [2]f32, // the target, in pixels
	grid:       [2]f32, // PSX: the coarse pixel grid
	time:       f32,    // VHS: everything animated is driven from this
	_pad:       [3]f32,
}

/*
	One light, as the shader reads it. 64 bytes. An element of the
	`StructuredBuffer<Light>` `lighting_core.hlsli` declares (see
	`light.odin`'s own `Lighting.light_buffer`) rather than a fixed-size
	cbuffer array the way it was before this rework -- see `light.odin`'s top
	comment for why an unbounded list replaced `MAX_LIGHTS`.

	Everything is a [4]f32 and nothing is a [3]f32, which is the whole trick.
	HLSL refuses to let a vector straddle a 16-byte boundary and silently pads
	to avoid it, so a float3 followed by a float is 16 bytes or 32 depending on
	rules that are easy to misremember -- and getting it wrong gives wrong
	lighting rather than an error. Four floats everywhere means the two sides
	agree by construction.

	The spare components are not spare: `position.w` is whether the light is on,
	and `target.w` is which kind it is. `cone` only ever means anything for a
	spotlight -- see `create_spot_light` -- and rides along unread otherwise.
*/
Light_Uniform :: struct #align(16) {
	position: [4]f32, // xyz where it is,                     w 1 when enabled
	target:   [4]f32, // xyz direction (directional/spot), unused (point), w kind: 0/1/2
	color:    [4]f32,
	cone:     [4]f32, // x outer half-angle degrees, y inner half-angle degrees -- spot only
}

// GPU handle bundle — shared by Sprite, Animation_Clip, and Font.
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

// Transform + physics + uv — shared by Sprite and Animated_Sprite.
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

Parallax_Sprites :: struct {
	sprites:[dynamic]Sprite
}

// Every piece of state Matchbox needs to run, grouped by subsystem. There is
// exactly one of these -- the package-level `mbi` -- so nothing has to be
// threaded through procedure arguments.
//
// `display` and `clock` are `using` so the fields games reach for most often
// stay flat: `mbi.delta_time`, `mbi.width`, `mbi.window`. `renderer` is left
// qualified because it is internal plumbing that games should not touch.
Matchbox_Info :: struct {
	using display: Display,  // window, logical resolution, letterbox transform
	using clock:   Clock,    // frame timing
	renderer:      Renderer, // shaders, descriptor pool, per-frame GPU state
	input:         Input,    // keyboard + mouse
	camera:        Camera,
	font:          Font,     // default font, loaded by init
	font_cache:    Font_Cache, // the default font baked at other sizes
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
// **This is the only package-level global in Matchbox, and deliberately so.**
// The API is immediate-mode: `draw_rect` cannot take a renderer without every
// call site carrying one, and a game would be threading the same pointer
// through every draw it makes. Anything that needs to outlive a frame belongs
// in here as a field rather than beside it as a second global -- see CLAUDE.md.
//
// Games are free to read it -- `matchbox.mbi.delta_time`, `matchbox.mbi.running`
// -- or go through the accessors where one exists. A local alias also works if
// the qualified name gets tiresome:
//
//	mbi := &matchbox.mbi
//
// Consequence worth knowing: one global means one window. Matchbox cannot run
// two independent instances in a process.
mbi: Matchbox_Info

// -----------------------------------------------------------------------
// Constants
// -----------------------------------------------------------------------

/*
	The font numbers a game may reasonably want different.

	`size` is what `get_font` bakes when nobody asks for a size, `line_spacing`
	is the gap between wrapped lines as a fraction of the line height, and
	`cache_limit` is how many baked sizes are kept before the least recently
	used is evicted.

	The three atlas constants below are **not** here and cannot be: they size
	fixed arrays and index the baked glyph range, and Odin needs a compile-time
	constant for both. See CLAUDE.md.
*/
Font_Defaults :: struct {
	size:         f32,
	line_spacing: f32,
	cache_limit:  int,
}

FONT_ATLAS_SIZE :: 512

// The glyphs an atlas holds: printable ASCII, space through '~'.
//
// DEL is left out on purpose, which is why the count is 95 rather than the
// round 96. A font with no glyph at that codepoint -- most of them, the default
// one included -- gets stb's .notdef box baked there instead, and that box is
// drawn taller than any real letter. A font's ascent is a max over the glyphs
// that were baked, so taking DEL in would let a character nothing ever draws
// set the baseline for everything that does.
FONT_FIRST_GLYPH :: 32
FONT_GLYPH_COUNT :: 95

// -----------------------------------------------------------------------
// Colors
// -----------------------------------------------------------------------

PUMPKIN_ORANGE: [4]f32 = {.75, .30, 0, 1}
BLACK:          [4]f32 = {0, 0, 0, 1}
WHITE:          [4]f32 = {1, 1, 1, 1}
LIME_GREEN:     [4]f32 = {0.39, 0.58, 0.29, 1}
CORNFLOWER_BLUE:[4]f32 = {0.39, 0.58, 0.92, 1}
RED:            [4]f32 = {1, 0, 0, 1}
DEEP_AMBER_RED :[4]f32 = {1.0, 0.2, 0.0, 1}
BROWN          :[4]f32 = {0.50, 0.42, 0.31, 1}
GREEN     :: [4]f32{0.00, 0.89, 0.19, 1}
BLUE      :: [4]f32{0.00, 0.47, 0.95, 1}
MAROON    :: [4]f32{0.75, 0.13, 0.22, 1}
ORANGE    :: [4]f32{1.00, 0.63, 0.00, 1}
LIGHTGRAY :: [4]f32{0.78, 0.78, 0.78, 1}
PURPLE    :: [4]f32{0.78, 0.48, 1.00, 1}
SKYBLUE   :: [4]f32{0.40, 0.75, 1.00, 1}
