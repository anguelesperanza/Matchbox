package matchbox

import "core:fmt"
import "core:log"
import "core:os"
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

	This says much less than the Vulkan-specific report it replaces, which
	could name the exact missing extension. It is also much less likely to be
	needed: the failure that motivated that report was a required extension
	the driver did not have, and SDL3 asks for nothing of the kind.
*/
@(private)
write_gpu_report :: proc() {
	sb := strings.builder_make_none()
	defer strings.builder_destroy(&sb)

	strings.write_string(&sb, "The renderer could not start.\n\n")

	if err := sdl.GetError(); err != nil && err != "" {
		fmt.sbprintf(&sb, "SDL said: %s\n\n", err)
	}

	// Which backends were compiled in, and which would take the shaders that
	// ship with this program. A backend listed as unsupported here is one the
	// machine cannot provide -- no driver, or too old a one.
	strings.write_string(&sb, "graphics backends:\n")
	for i in 0 ..< sdl.GetNumGPUDrivers() {
		name := sdl.GetGPUDriver(i)
		spirv := sdl.GPUSupportsShaderFormats({.SPIRV}, name)
		dxil  := sdl.GPUSupportsShaderFormats({.DXIL},  name)

		status := "unsupported on this machine"
		if spirv || dxil {
			status = "available"
		}

		fmt.sbprintf(&sb, "  %-14s %s", name, status)
		if spirv do strings.write_string(&sb, "  (SPIR-V)")
		if dxil  do strings.write_string(&sb, "  (DXIL)")
		strings.write_string(&sb, "\n")
	}

	strings.write_string(&sb,
		"\nIf nothing above is available, the graphics driver is the thing to\n" +
		"look at -- installing the newest one from the GPU maker's own site,\n" +
		"rather than through Windows Update, fixes the majority of these.\n")

	body := strings.to_string(sb)

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
	Loads one of the built-in shaders.

	Both a SPIR-V and a DXIL build of every shader is compiled in, and which
	one is handed over depends on the backend SDL picked. Declaring both at
	device creation is what makes the D3D12 fallback possible at all -- SDL
	will only offer a backend whose shader format it was told about.
*/
@(private)
create_builtin_shader :: proc(
	spirv, dxil:         []u8,
	stage:               sdl.GPUShaderStage,
	num_samplers:        u32,
	num_uniform_buffers: u32 = 1,
) -> ^sdl.GPUShader {
	formats := sdl.GetGPUShaderFormats(mbi.renderer.device)

	code:   []u8
	format: sdl.GPUShaderFormat

	switch {
	case .SPIRV in formats: code, format = spirv, {.SPIRV}
	case .DXIL  in formats: code, format = dxil,  {.DXIL}
	case:
		panic("GPU backend accepts neither SPIR-V nor DXIL")
	}

	shader := sdl.CreateGPUShader(mbi.renderer.device, {
		code_size           = len(code),
		code                = raw_data(code),
		entrypoint          = "main",
		format              = format,
		stage               = stage,
		num_samplers        = num_samplers,
		num_uniform_buffers = num_uniform_buffers,
	})

	if shader == nil {
		log.errorf("could not create shader: %s", sdl.GetError())
		panic("could not create a built-in shader")
	}

	return shader
}

/*
	Builds one pipeline: the shared vertex shader, the given fragment shader,
	and the alpha blend every draw in Matchbox uses.

	Culling is off. The quad's winding flips with the y negation in the vertex
	shader, and nothing here is a closed solid, so there is nothing to gain by
	being careful about it.
*/
@(private)
create_pipeline :: proc(fragment: ^sdl.GPUShader) -> ^sdl.GPUGraphicsPipeline {
	vertex_buffers := [1]sdl.GPUVertexBufferDescription{
		{slot = 0, pitch = size_of(Vertex), input_rate = .VERTEX},
	}

	attributes := [2]sdl.GPUVertexAttribute{
		{location = 0, buffer_slot = 0, format = .FLOAT3, offset = 0},
		{location = 1, buffer_slot = 0, format = .FLOAT2, offset = size_of([3]f32)},
	}

	color_targets := [1]sdl.GPUColorTargetDescription{
		{
			format = sdl.GetGPUSwapchainTextureFormat(mbi.renderer.device, mbi.window),
			blend_state = {
				enable_blend            = true,
				color_blend_op          = .ADD,
				src_color_blendfactor   = .SRC_ALPHA,
				dst_color_blendfactor   = .ONE_MINUS_SRC_ALPHA,
				alpha_blend_op          = .ADD,
				src_alpha_blendfactor   = .ONE,
				dst_alpha_blendfactor   = .ZERO,
				enable_color_write_mask = true,
				color_write_mask        = {.R, .G, .B, .A},
			},
		},
	}

	pipeline := sdl.CreateGPUGraphicsPipeline(mbi.renderer.device, {
		vertex_shader   = mbi.renderer.shaders.quad,
		fragment_shader = fragment,
		primitive_type  = .TRIANGLELIST,
		vertex_input_state = {
			vertex_buffer_descriptions = raw_data(vertex_buffers[:]),
			num_vertex_buffers         = 1,
			vertex_attributes          = raw_data(attributes[:]),
			num_vertex_attributes      = 2,
		},
		rasterizer_state = {fill_mode = .FILL, cull_mode = .NONE},
		target_info = {
			color_target_descriptions = raw_data(color_targets[:]),
			num_color_targets         = 1,
		},
	})

	if pipeline == nil {
		log.errorf("could not create pipeline: %s", sdl.GetError())
		panic("could not create a graphics pipeline")
	}

	return pipeline
}

/*
	Brings up SDL, the GPU backend and the window, and fills in the global `mbi`.
	Call this once before anything else in the package.

	The size is what you would like, not what you are guaranteed. It is capped
	to the display so a window never opens larger than the screen it is on.
*/
init :: proc(title: string, width: i32, height: i32) {
	width, height := width, height

	// No API-specific window flag. Asking for .VULKAN here would pin the window
	// to a Vulkan surface and take the D3D12 fallback away.
	mbi.flags            = {.HIGH_PIXEL_DENSITY, .RESIZABLE}
	mbi.title            = title
	mbi.running          = true
	mbi.max_delta_time   = 1.0 / 60
	mbi.input.escape_key = .ESCAPE

	mbi.input.gamepad_deadzone          = GAMEPAD_STICK_DEADZONE
	mbi.input.gamepad_trigger_threshold = GAMEPAD_TRIGGER_THRESHOLD

	// Odin's default logger discards everything, and the renderer reports why
	// it cannot start by logging -- so without this, a machine that cannot run
	// the game says "could not initialize gpu library" and nothing else.
	//
	// Only when the caller has not set one. A game with its own logger wants
	// its own logger.
	if context.logger.procedure == nil {
		mbi.logger     = log.create_console_logger()
		context.logger = mbi.logger
	}

	// The uniform structs are pushed straight at shader cbuffers, and a
	// mismatch shows up as wrong geometry or colour rather than an error.
	// Cheaper to find out here.
	#assert(size_of(VertData)        == 48)
	#assert(size_of(Sprite_Frag_Data) == 32)
	#assert(size_of(Shape_Frag_Data)  == 48)
	#assert(size_of(OutlineFragData) == 32)
	#assert(size_of(FontFragData)    == 16)
	#assert(size_of(Rect_Frag_Data)  == 16)

	// GAMEPAD pulls JOYSTICK in with it, and brings SDL's controller mapping
	// database along -- which is what lets a game ask for `.NORTH` rather than
	// working out that button 3 means something different on a DualSense.
	init_ok := sdl.Init({.VIDEO, .AUDIO, .GAMEPAD})
	if !init_ok {
		log.errorf("SDL_Init failed: %s", sdl.GetError())
		panic("Cannot init SDL3")
	}

	gamepads_init()

	mbi.ts_freq = sdl.GetPerformanceFrequency()

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

	// Window before device: SDL3 creates the device independently and then has
	// it claim a window, the reverse of the old swapchain-from-window order.
	//
	// SDL copies the title, so the clone is ours to free again -- it used to be
	// handed over and forgotten, which is a small leak but the only one the
	// tracking allocator found in a whole start-and-stop.
	title_cstring := strings.clone_to_cstring(title)
	defer delete(title_cstring)

	mbi.window = sdl.CreateWindow(title_cstring, width, height, mbi.flags)

	if mbi.window == nil { panic("Could not create SDL3 window") }

	// The size asked for was in points and the surface is in pixels, which on a
	// scaled display are not the same number. Asked rather than assumed, so that
	// anything reading mbi.window_width before the first begin_drawing gets the
	// truth -- poll_events is the one that matters, since it converts the mouse.
	mbi.pixel_density = 1
	if density := sdl.GetWindowPixelDensity(mbi.window); density > 0 {
		mbi.pixel_density = density
	}

	mbi.window_width  = width
	mbi.window_height = height
	sdl.GetWindowSizeInPixels(mbi.window, &mbi.window_width, &mbi.window_height)

	mbi.draw_scale    = 1
	mbi.draw_offset   = {0, 0}

	// Both shader formats are declared so SDL can fall back to D3D12 where
	// Vulkan is unavailable.
	mbi.renderer.device = sdl.CreateGPUDevice({.SPIRV, .DXIL}, ODIN_DEBUG, nil)
	if mbi.renderer.device == nil {
		write_gpu_report()
		panic("Could not create a GPU device -- see gpu-report.txt next to the program")
	}

	if !sdl.ClaimWindowForGPUDevice(mbi.renderer.device, mbi.window) {
		write_gpu_report()
		panic("Could not attach the window to the GPU device -- see gpu-report.txt next to the program")
	}

	log.infof("gpu backend: %s", sdl.GetGPUDeviceDriver(mbi.renderer.device))

	mbi.now_ts = sdl.GetPerformanceCounter()

	mbi.renderer.shaders.quad = create_builtin_shader(
		#load("shaders/quad.vert.spv"), #load("shaders/quad.vert.dxil"), .VERTEX, 0)
	// One sampler, and one uniform buffer for the tint.
	mbi.renderer.shaders.sprite = create_builtin_shader(
		#load("shaders/sprite.frag.spv"), #load("shaders/sprite.frag.dxil"), .FRAGMENT, 1)
	mbi.renderer.shaders.rect = create_builtin_shader(
		#load("shaders/rect.frag.spv"), #load("shaders/rect.frag.dxil"), .FRAGMENT, 0)
	mbi.renderer.shaders.outline = create_builtin_shader(
		#load("shaders/outline.frag.spv"), #load("shaders/outline.frag.dxil"), .FRAGMENT, 0)
	mbi.renderer.shaders.font = create_builtin_shader(
		#load("shaders/font.frag.spv"), #load("shaders/font.frag.dxil"), .FRAGMENT, 1)
	mbi.renderer.shaders.shape = create_builtin_shader(
		#load("shaders/shape.frag.spv"), #load("shaders/shape.frag.dxil"), .FRAGMENT, 0)

	mbi.renderer.pipelines.sprite  = create_pipeline(mbi.renderer.shaders.sprite)
	mbi.renderer.pipelines.rect    = create_pipeline(mbi.renderer.shaders.rect)
	mbi.renderer.pipelines.outline = create_pipeline(mbi.renderer.shaders.outline)
	mbi.renderer.pipelines.font    = create_pipeline(mbi.renderer.shaders.font)
	mbi.renderer.pipelines.shape   = create_pipeline(mbi.renderer.shaders.shape)

	// Every sprite wants the same filtering, and the font wants smoothing, so
	// two samplers serve the whole program.
	mbi.renderer.sprite_sampler = sdl.CreateGPUSampler(mbi.renderer.device, {
		min_filter = .NEAREST, mag_filter = .NEAREST,
	})
	mbi.renderer.font_sampler = sdl.CreateGPUSampler(mbi.renderer.device, {
		min_filter = .LINEAR, mag_filter = .LINEAR,
	})
	ensure(mbi.renderer.sprite_sampler != nil && mbi.renderer.font_sampler != nil,
		"could not create samplers")

	// The one quad every draw uses.
	{
		verts := [4]Vertex{
			{pos = {-0.5,  0.5, 0}, uv = {0, 1}},
			{pos = { 0.5, -0.5, 0}, uv = {1, 0}},
			{pos = { 0.5,  0.5, 0}, uv = {1, 1}},
			{pos = {-0.5, -0.5, 0}, uv = {0, 0}},
		}
		indices := [6]u32{0, 2, 1, 0, 1, 3}

		mbi.renderer.quad_verts   = upload_buffer(&verts,   size_of(verts),   {.VERTEX})
		mbi.renderer.quad_indices = upload_buffer(&indices, size_of(indices), {.INDEX})
	}

	mbi.font = load_font(DEFAULT_FONT_BYTES, DEFAULT_FONT_SIZE)

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
	gamepads_cleanup()

	device := mbi.renderer.device
	if device == nil do return

	// Nothing may be released while the GPU is still reading it.
	_ = sdl.WaitForGPUIdle(device)

	font_cache_destroy()
	destroy_font(&mbi.font)

	if mbi.renderer.quad_verts   != nil do sdl.ReleaseGPUBuffer(device, mbi.renderer.quad_verts)
	if mbi.renderer.quad_indices != nil do sdl.ReleaseGPUBuffer(device, mbi.renderer.quad_indices)

	if mbi.renderer.sprite_sampler != nil do sdl.ReleaseGPUSampler(device, mbi.renderer.sprite_sampler)
	if mbi.renderer.font_sampler   != nil do sdl.ReleaseGPUSampler(device, mbi.renderer.font_sampler)

	if mbi.renderer.pipelines.sprite  != nil do sdl.ReleaseGPUGraphicsPipeline(device, mbi.renderer.pipelines.sprite)
	if mbi.renderer.pipelines.rect    != nil do sdl.ReleaseGPUGraphicsPipeline(device, mbi.renderer.pipelines.rect)
	if mbi.renderer.pipelines.outline != nil do sdl.ReleaseGPUGraphicsPipeline(device, mbi.renderer.pipelines.outline)
	if mbi.renderer.pipelines.font    != nil do sdl.ReleaseGPUGraphicsPipeline(device, mbi.renderer.pipelines.font)
	if mbi.renderer.pipelines.shape   != nil do sdl.ReleaseGPUGraphicsPipeline(device, mbi.renderer.pipelines.shape)

	if mbi.renderer.shaders.quad    != nil do sdl.ReleaseGPUShader(device, mbi.renderer.shaders.quad)
	if mbi.renderer.shaders.sprite  != nil do sdl.ReleaseGPUShader(device, mbi.renderer.shaders.sprite)
	if mbi.renderer.shaders.rect    != nil do sdl.ReleaseGPUShader(device, mbi.renderer.shaders.rect)
	if mbi.renderer.shaders.outline != nil do sdl.ReleaseGPUShader(device, mbi.renderer.shaders.outline)
	if mbi.renderer.shaders.font    != nil do sdl.ReleaseGPUShader(device, mbi.renderer.shaders.font)
	if mbi.renderer.shaders.shape   != nil do sdl.ReleaseGPUShader(device, mbi.renderer.shaders.shape)

	sdl.ReleaseWindowFromGPUDevice(device, mbi.window)
	sdl.DestroyGPUDevice(device)
	mbi.renderer.device = nil
}

// Blocks until the GPU has finished everything submitted so far. Rarely needed
// -- the frame loop paces itself on the swapchain -- but kept for the cases
// where a game wants to be certain before tearing something down.
wait_idle :: proc() {
	if mbi.renderer.device != nil {
		_ = sdl.WaitForGPUIdle(mbi.renderer.device)
	}
}

// -----------------------------------------------------------------------
// Shaders
// -----------------------------------------------------------------------

/*
	Loads a shader off disk.

	`path` is given without the format extension: pass "shaders/water.frag" and
	the ".spv" or ".dxil" that matches the running backend is appended. Both
	need to exist beside each other for a game to keep working on either.
*/
load_shader :: proc(path: string, stage: sdl.GPUShaderStage, num_samplers: u32 = 0) -> ^sdl.GPUShader {
	formats := sdl.GetGPUShaderFormats(mbi.renderer.device)

	full:   string
	format: sdl.GPUShaderFormat

	switch {
	case .SPIRV in formats: full, format = fmt.tprintf("%s.spv",  path), {.SPIRV}
	case .DXIL  in formats: full, format = fmt.tprintf("%s.dxil", path), {.DXIL}
	case:
		panic("GPU backend accepts neither SPIR-V nor DXIL")
	}

	data, err := os.read_entire_file_from_path(full, context.allocator)
	if err != nil {
		log.errorf("could not read shader %s: %v", full, err)
		panic("Cannot read shader file")
	}

	shader := sdl.CreateGPUShader(mbi.renderer.device, {
		code_size           = len(data),
		code                = raw_data(data),
		entrypoint          = "main",
		format              = format,
		stage               = stage,
		num_samplers        = num_samplers,
		num_uniform_buffers = 1,
	})

	if shader == nil {
		log.errorf("could not create shader from %s: %s", full, sdl.GetError())
		panic("Cannot create shader")
	}

	return shader
}
