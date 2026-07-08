package matchbox

/*
	Init
	----
	This contains all of the procedures and structs that are needed when initializing Matchbox
*/


// Core Imports
import "core:strings"

// Vendor Imports
import sdl "vendor:sdl3"

// Third Party Imports
import "gpu"

/*A struct that holds all the shared state for Matchbox*/
MatchboxInfo :: struct {
	// Window Information
	window:            ^sdl.Window,
	window_width:      i32,
	window_height:     i32,
	running:           bool,

	// Render Information
	frame_semaphore:   gpu.Semaphore,
	frame_arenas:      [3]gpu.Arena,
	frame_arena:       ^gpu.Arena,
	depth_desc:        gpu.Texture_Desc,
	depth_texture:     gpu.Owned_Texture,
	triangle_vertex_shader:     gpu.Shader,
	triangle_frag_shader:       gpu.Shader,
	rectangle_vertex_shader:    gpu.Shader,
	rectangle_frag_shader:      gpu.Shader,
	circle_vertex_shader:       gpu.Shader, 
	circle_frag_shader:         gpu.Shader, 
	now_ts:            u64,
	ts_freq:           u64,
	max_delta_time:    f32,
	command:           gpu.Command_Buffer,
	frame_command:     gpu.Command_Buffer,
	next_frame:        u64,
	target_frame_time: f32,

	// Input Information
	input:             Input,
	escape_key:        sdl.Scancode,
}


/*
Initializes all the behind the scene things needed for matchbox
returns an instance of the "MatchboxInfo" struct called "matchbox_info"
*/
init :: proc(
	window_title: string,window_width: i32,	window_height: i32,	window_flags: sdl.WindowFlags = {.HIGH_PIXEL_DENSITY, .VULKAN, .RESIZABLE}) -> (matchbox_info: MatchboxInfo) {

	// SDL3 Setup
	ensure(condition = sdl.Init({.VIDEO, .AUDIO}), message = "Could not initialize SDL3")
	matchbox_info.window = sdl.CreateWindow(
		strings.clone_to_cstring(window_title),
		window_width,
		window_height,
		window_flags,
	)
	ensure(condition = matchbox_info.window != nil, message = "Could not create SDL 3 Window")

	// no_gfx_api Setup
	ensure(condition = gpu.init(), message = "Could not initialize no_gfx_api graphics")
	gpu.swapchain_init_from_sdl(matchbox_info.window, 3)

	matchbox_info.window_width = window_width
	matchbox_info.window_height = window_height
	matchbox_info.escape_key = .ESCAPE

	matchbox_info.ts_freq = sdl.GetPerformanceFrequency()
	matchbox_info.max_delta_time = 1.0 / 60.0

	matchbox_info.target_frame_time = 0 // 0 being uncapped framerate

	matchbox_info.next_frame = 1

	matchbox_info.depth_desc = gpu.Texture_Desc {
		dimensions = {cast(u32)window_width, cast(u32)window_height, 1},
		format     = .D32_Float,
		usage      = {.Depth_Stencil_Attachment},
	}

	matchbox_info.depth_texture = gpu.texture_alloc_and_create(matchbox_info.depth_desc)

	next_frame := 1
	matchbox_info.frame_semaphore = gpu.semaphore_create(0)

	matchbox_info.now_ts = sdl.GetPerformanceCounter()

	for &frame_arena in matchbox_info.frame_arenas {
		frame_arena = gpu.arena_create()
	}


	matchbox_info.triangle_vertex_shader = gpu.shader_create(
		#load("./shaders/triangle_shader.vert.spv", []u32),
		.Vertex,
	)
	matchbox_info.triangle_frag_shader = gpu.shader_create(
		#load("./shaders/triangle_shader.frag.spv", []u32),
		.Fragment,
	)
	matchbox_info.rectangle_vertex_shader = gpu.shader_create(
		#load("./shaders/rectangle_shader.vert.spv", []u32),
		.Vertex,
	)
	matchbox_info.rectangle_frag_shader = gpu.shader_create(
		#load("./shaders/rectangle_shader.frag.spv", []u32),
		.Fragment,
	)
	matchbox_info.circle_vertex_shader = gpu.shader_create(
		#load("./shaders/circle_shader.vert.spv", []u32),
		.Vertex,
	)
	matchbox_info.circle_frag_shader = gpu.shader_create(
		#load("./shaders/circle_shader.frag.spv", []u32),
		.Fragment,
	)

	matchbox_info.running = true

	matchbox_info.command = gpu.commands_begin(.Main)
	// gpu.cmd_mem_copy(...) or gpu.copy_to_texture, etc data to be sent to the gpu

	gpu.cmd_barrier(matchbox_info.command, .Transfer, .All, {})
	gpu.queue_submit(.Main, {matchbox_info.command})
	gpu.queue_wait_idle(.Main)

	return
}

/*
This procedure frees up everthing created by init.
Must be called otherwise application will not close properly.
*/
cleanup :: proc(matchbox_info: ^MatchboxInfo) {
	// Waits for the gpu to finish up whatever it's doing first
	gpu.wait_idle()

	for &frame_arena in matchbox_info.frame_arenas {
		gpu.arena_destroy(&frame_arena)
	}

	gpu.shader_destroy(matchbox_info.triangle_vertex_shader)
	gpu.shader_destroy(matchbox_info.triangle_frag_shader)
	gpu.shader_destroy(matchbox_info.rectangle_vertex_shader)
	gpu.shader_destroy(matchbox_info.rectangle_frag_shader)
	gpu.shader_destroy(matchbox_info.circle_vertex_shader)
	gpu.shader_destroy(matchbox_info.circle_frag_shader)
	gpu.texture_free_and_destroy(&matchbox_info.depth_texture)
	gpu.semaphore_destroy(matchbox_info.frame_semaphore)

	gpu.cleanup()
}
