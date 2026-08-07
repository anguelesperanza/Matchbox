package matchbox

import "gpu"

// -----------------------------------------------------------------------
// Types -- GPU data
// -----------------------------------------------------------------------

Vertex :: struct {
	pos: [3]f32,
	uv:  [2]f32,
}

VertData :: struct {
	verts:    rawptr,
	position: [2]f32,
	size:     [2]f32,
	screen:   [2]f32,
	uv_min:   [2]f32,
	uv_max:   [2]f32,
	rotation: f32,
	flip_x:   b32,
	flip_y:   b32,
}

FragData :: struct {
	texture_a: u32,
	sampler:   u32,
	flip_x:    b32,
	flip_y:    b32,
}

// #align(16): the `color` vec4 is read by outline.frag as a single 128-bit
// (Aligned 16) buffer_reference load, which requires the allocation to be
// 16-byte aligned. Odin gives [4]f32 only 4-byte alignment by default, so
// without this the per-frame arena can place it on an 8-aligned address and
// NVIDIA reads from the address rounded down to 16 -> wrong color / zero alpha.
OutlineFragData :: struct #align(16) {
	color:  [4]f32,
	border: f32,
	flip_x: b32,
	flip_y: b32,
}

FontVertData :: struct {
	verts:    rawptr,
	position: [2]f32,
	size:     [2]f32,
	screen:   [2]f32,
	rotation: f32,
	flip_x:   b32,
	flip_y:   b32,
	uv_min:   [2]f32,
	uv_max:   [2]f32,
}

FontFragData :: struct {
    texture_a: u32,
    sampler:   u32,
    color:     [4]f32,
}

// #align(16): see OutlineFragData. rect.frag reads `color` as a single 128-bit
// (Aligned 16) buffer_reference load, so the allocation must be 16-byte aligned.
Rect_Frag_Data :: struct #align(16) {
	color: [4]f32,
}

// GPU handle bundle — shared by Sprite, AnimationClip, and Font.
Mesh :: struct {
	gpu_texture:   gpu.Owned_Texture,
	verts_local:   gpu.slice_t(Vertex),
	indices_local: gpu.slice_t(u32),
	tex_id:        u32,
	sampler_id:    u32,
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
