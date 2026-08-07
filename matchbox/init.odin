package matchbox

import "gpu"
import "core:os"
import "core:slice"
import "core:strings"

import sdl "vendor:sdl3"

// -----------------------------------------------------------------------
// Init / Cleanup
// -----------------------------------------------------------------------

init :: proc(title: string, width: i32, height: i32) -> MatchboxInfo {
	matchbox_info: MatchboxInfo
	matchbox_info.title            = title
	matchbox_info.width            = width
	matchbox_info.height           = height
	matchbox_info.flags            = {.HIGH_PIXEL_DENSITY, .VULKAN, .RESIZABLE}
	matchbox_info.running          = true
	matchbox_info.max_delta_time   = 1.0 / 60
	matchbox_info.input.escape_key = .ESCAPE

	init_ok := sdl.Init({.VIDEO, .AUDIO})
	if !init_ok { panic("Cannot init SDL3") }

	matchbox_info.ts_freq = sdl.GetPerformanceFrequency()

	gpu_ok := gpu.init()
	if !gpu_ok { panic("Could not initialize gpu library") }


	matchbox_info.window = sdl.CreateWindow(
		strings.clone_to_cstring(title),
		width, height,
		matchbox_info.flags,
	)

	if matchbox_info.window == nil { panic("Could not create SDL3 window") }
	matchbox_info.window_width  = width
	matchbox_info.window_height = height
	matchbox_info.draw_scale    = 1
	matchbox_info.draw_offset   = {0, 0}

	gpu.swapchain_init_from_sdl(matchbox_info.window, 3)

	matchbox_info.now_ts              = sdl.GetPerformanceCounter()
	matchbox_info.renderer.desc_pool  = gpu.desc_pool_create()
	matchbox_info.renderer.next_frame = 1
	matchbox_info.renderer.frame_sem  = gpu.semaphore_create(0)

	for &fa in matchbox_info.renderer.frame_arenas do fa = gpu.arena_create()

	matchbox_info.renderer.shaders.vertex    = gpu.shader_create(#load("shaders/test.vert.spv", []u32), .Vertex)
	matchbox_info.renderer.shaders.fragment  = gpu.shader_create(#load("shaders/test.frag.spv", []u32), .Fragment)
	matchbox_info.renderer.shaders.outline   = gpu.shader_create(#load("shaders/outline.frag.spv", []u32), .Fragment)
	matchbox_info.renderer.shaders.font_vert = gpu.shader_create(#load("shaders/font.vert.spv", []u32), .Vertex)
	matchbox_info.renderer.shaders.font_frag = gpu.shader_create(#load("shaders/font.frag.spv", []u32), .Fragment)
	matchbox_info.renderer.shaders.rect_frag = gpu.shader_create(#load("shaders/rect.frag.spv", []u32), .Fragment)

	// Upload shared rect quad (reused by every draw_rect call)
	{
		upload_arena := gpu.arena_create()
		defer gpu.arena_destroy(&upload_arena)

		stage_verts := gpu.arena_alloc(&upload_arena, Vertex, 4)
		stage_verts.cpu[0] = {pos = {-0.5,  0.5, 0}, uv = {0, 1}}
		stage_verts.cpu[1] = {pos = { 0.5, -0.5, 0}, uv = {1, 0}}
		stage_verts.cpu[2] = {pos = { 0.5,  0.5, 0}, uv = {1, 1}}
		stage_verts.cpu[3] = {pos = {-0.5, -0.5, 0}, uv = {0, 0}}

		stage_indices := gpu.arena_alloc(&upload_arena, u32, 6)
		stage_indices.cpu[0] = 0; stage_indices.cpu[1] = 2; stage_indices.cpu[2] = 1
		stage_indices.cpu[3] = 0; stage_indices.cpu[4] = 1; stage_indices.cpu[5] = 3

		matchbox_info.renderer.rect_verts   = gpu.mem_alloc(Vertex, 4, gpu.Memory.GPU)
		matchbox_info.renderer.rect_indices = gpu.mem_alloc(u32, 6, gpu.Memory.GPU)

		cmd := gpu.commands_begin(.Main)
		gpu.cmd_mem_copy(cmd, matchbox_info.renderer.rect_verts, stage_verts)
		gpu.cmd_mem_copy(cmd, matchbox_info.renderer.rect_indices, stage_indices)
		gpu.cmd_barrier(cmd, .Transfer, .All, {})
		gpu.queue_submit(.Main, {cmd})
		gpu.queue_wait_idle(.Main)
	}

	matchbox_info.font = load_font(&matchbox_info, #load("fonts/Silver.ttf"), 32)

	matchbox_info.camera = Camera{
		position = {f32(width) * 0.5, f32(height) * 0.5},
		zoom     = 1.0,
		active   = false,
	}

	set_logical_size(&matchbox_info, width, height)

	return matchbox_info
}

cleanup :: proc(matchbox_info: ^MatchboxInfo) {

	gpu.wait_idle()
	
	gpu.semaphore_destroy(matchbox_info.renderer.frame_sem)
	for &fa in matchbox_info.renderer.frame_arenas do gpu.arena_destroy(&fa)

	if matchbox_info.renderer.shaders.vertex    != nil do gpu.shader_destroy(matchbox_info.renderer.shaders.vertex)
	if matchbox_info.renderer.shaders.fragment  != nil do gpu.shader_destroy(matchbox_info.renderer.shaders.fragment)
	if matchbox_info.renderer.shaders.outline   != nil do gpu.shader_destroy(matchbox_info.renderer.shaders.outline)
	if matchbox_info.renderer.shaders.font_vert != nil do gpu.shader_destroy(matchbox_info.renderer.shaders.font_vert)
	if matchbox_info.renderer.shaders.font_frag != nil do gpu.shader_destroy(matchbox_info.renderer.shaders.font_frag)
	if matchbox_info.renderer.shaders.rect_frag != nil do gpu.shader_destroy(matchbox_info.renderer.shaders.rect_frag)

	gpu.mem_free(matchbox_info.renderer.rect_verts)
	gpu.mem_free(matchbox_info.renderer.rect_indices)

	destroy_font(matchbox_info, &matchbox_info.font)

	gpu.desc_pool_destroy(&matchbox_info.renderer.desc_pool)
	gpu.cleanup()
}

// Originally was used to call gpu.wait_idle in main loop,
// that has been moved to end_render. Leaving in for the time being
// but may remove if uneeded
wait_idle :: proc() {
	gpu.wait_idle()
}

// -----------------------------------------------------------------------
// Shaders
// -----------------------------------------------------------------------

load_shader :: proc(shader_path: string, shader_type: gpu.Shader_Type_Graphics) -> gpu.Shader {
	data, err := os.read_entire_file_from_path(shader_path, context.allocator)
	if err != nil { panic("Cannot read shader file") }
	return gpu.shader_create(slice.reinterpret([]u32, data), shader_type)
}
