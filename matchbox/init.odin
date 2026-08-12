package matchbox

import "gpu"
import "core:fmt"
import "core:log"
import "core:os"
import "core:slice"
import "core:strings"

import sdl "vendor:sdl3"

// -----------------------------------------------------------------------
// Init / Cleanup
// -----------------------------------------------------------------------

/*
	Puts the renderer's account of a failed start next to the program.

	A file rather than console output, because the person this has to reach is
	whoever was handed a copy of the game: they double-clicked it, it died, and
	the only thing that can be asked of them is to send back a file sitting in
	the same folder. Anything requiring a terminal reaches the author and
	nobody else.

	Beside the executable rather than the working directory, since a shortcut
	can start a program anywhere and the folder they were given is the one
	place they will think to look.
*/
@(private)
write_gpu_report :: proc() {
	body := gpu.startup_report()
	if body == "" {
		body = "The renderer would not start, and had nothing further to say about why.\n"
	}

	header := fmt.tprintf(
		"%s could not start.\n\nSend this file to whoever gave you the game.\n\n%s\n\n",
		mbi.title, strings.repeat("-", 60, context.temp_allocator),
	)

	path := "gpu-report.txt"
	if exe := os.args[0]; exe != "" {
		if cut := strings.last_index_any(exe, "/\\"); cut >= 0 {
			path = fmt.tprintf("%s/gpu-report.txt", exe[:cut])
		}
	}

	if err := os.write_entire_file(path, fmt.tprintf("%s%s", header, body)); err != nil {
		// Nothing left to fall back on but the console, which is where this
		// went before there was a file at all
		log.errorf("could not write %s: %v", path, err)
	} else {
		log.errorf("wrote %s", path)
	}

	log.error(body)
}

/*
	Brings up SDL, the GPU backend and the window, and fills in the global `mbi`.
	Call this once before anything else in the package.

	The size is what you would like, not what you are guaranteed. It is capped
	to the display so a window never opens larger than the screen it is on.
*/
init :: proc(title: string, width: i32, height: i32) {
	width, height := width, height

	mbi.flags            = {.HIGH_PIXEL_DENSITY, .VULKAN, .RESIZABLE}
	mbi.title            = title
	mbi.running          = true
	mbi.max_delta_time   = 1.0 / 60
	mbi.input.escape_key = .ESCAPE

	// Odin's default logger discards everything, and the gpu layer reports why
	// it cannot start by logging -- so without this, a machine that cannot run
	// the game says "could not initialize gpu library" and nothing else, when
	// it was ready to name the exact extension it was missing.
	//
	// Only when the caller has not set one. A game with its own logger wants
	// its own logger.
	if context.logger.procedure == nil {
		mbi.logger     = log.create_console_logger()
		context.logger = mbi.logger
	}

	init_ok := sdl.Init({.VIDEO, .AUDIO})
	if !init_ok {
		log.errorf("SDL_Init failed: %s", sdl.GetError())
		panic("Cannot init SDL3")
	}

	mbi.ts_freq = sdl.GetPerformanceFrequency()

	gpu_ok := gpu.init()
	if !gpu_ok {
		write_gpu_report()
		panic("Could not initialize gpu library -- see gpu-report.txt next to the program")
	}

	// A game written on a desktop asks for a desktop-sized window, and what
	// happens when it is opened on a laptop is up to the window manager: some
	// clamp it, some leave part of it off the screen where nothing can reach
	// it, and either way the game is drawing to a size it does not have.
	//
	// Usable bounds rather than the raw display size, so a taskbar, dock or
	// panel is already accounted for. A display that cannot be measured leaves
	// the request alone rather than guessing at it.
	bounds: sdl.Rect
	if sdl.GetDisplayUsableBounds(sdl.GetPrimaryDisplay(), &bounds) && bounds.w > 0 && bounds.h > 0 {
		width  = min(width,  bounds.w)
		height = min(height, bounds.h)
	}

	mbi.width  = width
	mbi.height = height

	mbi.window = sdl.CreateWindow(
		strings.clone_to_cstring(title),
		width, height,
		mbi.flags,
	)

	if mbi.window == nil { panic("Could not create SDL3 window") }
	mbi.window_width  = width
	mbi.window_height = height
	mbi.draw_scale    = 1
	mbi.draw_offset   = {0, 0}

	gpu.swapchain_init_from_sdl(mbi.window, 3)

	mbi.now_ts              = sdl.GetPerformanceCounter()
	mbi.renderer.desc_pool  = gpu.desc_pool_create()
	mbi.renderer.next_frame = 1
	mbi.renderer.frame_sem  = gpu.semaphore_create(0)

	for &fa in mbi.renderer.frame_arenas do fa = gpu.arena_create()

	// Every sprite wants the same filtering, and samplers are the scarcest thing
	// in the descriptor pool, so one is allocated here and shared by all of them
	mbi.renderer.sprite_sampler = gpu.desc_pool_alloc_sampler(
		&mbi.renderer.desc_pool,
		gpu.sampler_descriptor({min_filter = .Nearest, mag_filter = .Nearest}),
	)

	mbi.renderer.shaders.vertex    = gpu.shader_create(#load("shaders/test.vert.spv", []u32), .Vertex)
	mbi.renderer.shaders.fragment  = gpu.shader_create(#load("shaders/test.frag.spv", []u32), .Fragment)
	mbi.renderer.shaders.outline   = gpu.shader_create(#load("shaders/outline.frag.spv", []u32), .Fragment)
	mbi.renderer.shaders.font_vert = gpu.shader_create(#load("shaders/font.vert.spv", []u32), .Vertex)
	mbi.renderer.shaders.font_frag = gpu.shader_create(#load("shaders/font.frag.spv", []u32), .Fragment)
	mbi.renderer.shaders.rect_frag = gpu.shader_create(#load("shaders/rect.frag.spv", []u32), .Fragment)

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

		mbi.renderer.rect_verts   = gpu.mem_alloc(Vertex, 4, gpu.Memory.GPU)
		mbi.renderer.rect_indices = gpu.mem_alloc(u32, 6, gpu.Memory.GPU)

		cmd := gpu.commands_begin(.Main)
		gpu.cmd_mem_copy(cmd, mbi.renderer.rect_verts, stage_verts)
		gpu.cmd_mem_copy(cmd, mbi.renderer.rect_indices, stage_indices)
		gpu.cmd_barrier(cmd, .Transfer, .All, {})
		gpu.queue_submit(.Main, {cmd})
		gpu.queue_wait_idle(.Main)
	}

	mbi.font = load_font(#load("fonts/Silver.ttf"), 32)

	mbi.camera = Camera{
		position = {f32(width) * 0.5, f32(height) * 0.5},
		zoom     = 1.0,
		active   = false,
	}

	// fixed_res stays off: the logical size tracks the window, so a resize just
	// gives you more room to draw in. Call set_logical_size to pin a resolution
	// and letterbox it instead.

	mbi.initialized = true
}

// True until the window is closed or the escape key is pressed. The usual
// shape of a game loop is `for matchbox.is_running() { ... }`.
is_running :: proc() -> bool {
	return mbi.running
}

// Tears down everything init brought up. Call once, after the game loop ends.
cleanup :: proc() {

	gpu.wait_idle()
	
	gpu.semaphore_destroy(mbi.renderer.frame_sem)
	for &fa in mbi.renderer.frame_arenas do gpu.arena_destroy(&fa)

	if mbi.renderer.shaders.vertex    != nil do gpu.shader_destroy(mbi.renderer.shaders.vertex)
	if mbi.renderer.shaders.fragment  != nil do gpu.shader_destroy(mbi.renderer.shaders.fragment)
	if mbi.renderer.shaders.outline   != nil do gpu.shader_destroy(mbi.renderer.shaders.outline)
	if mbi.renderer.shaders.font_vert != nil do gpu.shader_destroy(mbi.renderer.shaders.font_vert)
	if mbi.renderer.shaders.font_frag != nil do gpu.shader_destroy(mbi.renderer.shaders.font_frag)
	if mbi.renderer.shaders.rect_frag != nil do gpu.shader_destroy(mbi.renderer.shaders.rect_frag)

	gpu.mem_free(mbi.renderer.rect_verts)
	gpu.mem_free(mbi.renderer.rect_indices)

	destroy_font(&mbi.font)

	gpu.desc_pool_destroy(&mbi.renderer.desc_pool)
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
