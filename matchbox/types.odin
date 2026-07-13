package matchbox

import "gpu"
import sdl "vendor:sdl3"

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

Mouse :: struct {
	x:f32,
	y:f32,
	buttons_pressed:[sdl.MouseButtonFlag]bool,
	buttons_down:[sdl.MouseButtonFlag]bool,
}

Rectangle :: struct {
	position: [2]f32,
	size:     [2]f32,
	color:    [4]f32,
	rotation: f32,
}

ParallaxSprites :: struct {
	sprites:[dynamic]Sprite
}

Camera :: struct {
	position: [2]f32, // world point the camera is centered on
	zoom:     f32,    // 1.0 = normal, >1 zooms in, <1 zooms out
	active:   bool,   // true while inside begin_drawing_2d / end_drawing_2d
	follow_speed:f32, // How fast the camera will follow the position (used for lerp)
}

MatchboxInfo :: struct {
	window:          ^sdl.Window,
	width:           i32,
	height:          i32,
	window_width:    i32,
	window_height:   i32,
	fixed_res:       bool,
	draw_scale:      f32,
	draw_offset:     [2]f32,
	title:           string,
	flags:           sdl.WindowFlags,
	running:         bool,
	vertex_shader:   gpu.Shader,
	fragment_shader: gpu.Shader,
	outline_shader:      gpu.Shader,
	font_vert_shader:    gpu.Shader,
	font_frag_shader:    gpu.Shader,
	rect_frag_shader:    gpu.Shader,
	rect_verts:          gpu.slice_t(Vertex),
	rect_indices:        gpu.slice_t(u32),
	ts_freq:         u64,
	now_ts:          u64,
	delta_time:        f32,
	max_delta_time:    f32,
	target_frame_time: f32,  // 0 = unlimited; set via set_target_fps
	frame_cmd:       gpu.Command_Buffer,
	desc_pool:       gpu.Descriptor_Pool,
	frame_arenas:    [3]gpu.Arena,
	frame_arena:     ^gpu.Arena,
	next_frame:      u64,
	frame_sem:       gpu.Semaphore,
	swapchain:       gpu.Texture,
	// Input
	keys_down:    #sparse[sdl.Scancode]bool,
	keys_pressed: #sparse[sdl.Scancode]bool,
	mouse:        Mouse,
	font:         Font,
	camera:       Camera,
}

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
