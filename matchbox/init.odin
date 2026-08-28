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

	/*
		Beside the executable, because the person this has to reach double-clicked
		the game and the folder they were given is the one place they will look.

		Except where there is no such folder. On Android an apk's directory is not
		writable and os.args[0] means nothing, so the fallback is the one place
		the program is allowed to write -- which is also somewhere a bug report
		can be fetched from. pref_path makes the directory if it is not there.
	*/
	path := "gpu-report.txt"

	if exe := os.args[0]; exe != "" {
		if cut := strings.last_index_any(exe, "/\\"); cut >= 0 {
			path = fmt.tprintf("%s/gpu-report.txt", exe[:cut])
		}
	}

	report := fmt.tprintf("%s%s", header, body)

	if !write_report_file(path, report) {
		if dir := pref_path("matchbox", mbi.title, context.temp_allocator); dir != "" {
			path = fmt.tprintf("%sgpu-report.txt", dir)
			if !write_report_file(path, report) {
				// Nothing left to fall back on but the console, which is where
				// this went before there was a file at all.
				log.error("could not write a gpu report anywhere")
			}
		}
	}

	log.error(body)
}

// Writes the report and says whether it landed. Through SDL so it works
// wherever SDL can write, which is not the same set of places core:os can.
@(private)
write_report_file :: proc(path: string, text: string) -> bool {
	c_path := strings.clone_to_cstring(path, context.temp_allocator)

	if !sdl.SaveFile(c_path, raw_data(text), len(text)) do return false

	log.errorf("wrote %s", path)
	return true
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

// Which geometry a pipeline reads: the shared quad, or a model's own vertices.
@(private)
Vertex_Layout :: enum {
	QUAD,    // Vertex           -- position and uv, the four corners every 2D draw uses
	MESH,    // Vertex3D         -- position, normal and uv, a model's own buffer
	SKINNED, // Vertex3D_Skinned -- the same three, plus four joints and their weights

	// Nothing at all. The vertex shader builds its own positions from
	// SV_VertexID, which is what the skybox does -- one triangle over the whole
	// screen, and no buffer to bind or upload.
	NONE,
}

/*
	Builds one pipeline: a vertex shader, a fragment shader, and the alpha blend
	every draw in Matchbox uses.

	The defaults are what every 2D pipeline wants, so the five calls that came
	before 3D pass a fragment shader alone and are unchanged by its arrival.

	Culling is off by default. The quad's winding flips with the y negation in
	quad.vert, and nothing 2D is a closed solid, so there is nothing to gain by
	being careful about it. A model is a closed solid and does gain, which is
	why `cull` is a parameter now.

	`depth` is what makes a pipeline usable in the 3D pass and unusable outside
	it: SDL3 bakes the target formats in here, and a pipeline whose targets
	disagree with the pass it is bound in is a validation failure. That is the
	whole reason 3D gets a pass of its own -- see render3d.odin.
*/
@(private)
create_pipeline :: proc(
	fragment: ^sdl.GPUShader,
	vertex:   ^sdl.GPUShader = nil, // nil means the shared quad shader
	layout:   Vertex_Layout  = .QUAD,
	depth:    bool           = false,
	cull:     sdl.GPUCullMode = .NONE,
	lines:    bool           = false,

	/*
		The pass has a depth buffer, but this pipeline neither tests nor writes
		it. Not the same as `depth = false`, which says the pass has no depth
		attachment at all -- a pipeline has to agree with the pass it is used
		in, so a skybox drawn inside the 3D pass must declare the attachment
		even though it ignores every value in it.
	*/
	depth_ignore: bool = false,
) -> ^sdl.GPUGraphicsPipeline {
	vertex_shader := vertex if vertex != nil else mbi.renderer.shaders.quad

	pitch: u32
	switch layout {
	case .QUAD:    pitch = size_of(Vertex)
	case .SKINNED: pitch = size_of(Vertex3D_Skinned)
	case .NONE:    pitch = 0
	case .MESH:    fallthrough
	case:          pitch = size_of(Vertex3D)
	}

	vertex_buffers := [1]sdl.GPUVertexBufferDescription{
		{slot = 0, pitch = pitch, input_rate = .VERTEX},
	}

	num_vertex_buffers: u32 = 1
	if layout == .NONE do num_vertex_buffers = 0

	// Five attributes for a skinned mesh, three for a plain one, two for the
	// quad. The mesh's third is the one the quad has no room for -- a normal --
	// and the skinned pair after that are the joints and their weights.
	attributes := [5]sdl.GPUVertexAttribute{
		{location = 0, buffer_slot = 0, format = .FLOAT3, offset = 0},
		{location = 1, buffer_slot = 0, format = .FLOAT2, offset = size_of([3]f32)},
		{}, {}, {},
	}
	num_attributes: u32 = 2

	switch layout {
	case .MESH:
		attributes = {
			{location = 0, buffer_slot = 0, format = .FLOAT3, offset = 0},
			{location = 1, buffer_slot = 0, format = .FLOAT3, offset = size_of([3]f32)},
			{location = 2, buffer_slot = 0, format = .FLOAT2, offset = size_of([3]f32) * 2},
			{}, {},
		}
		num_attributes = 3

	case .SKINNED:
		// Offsets taken from the type rather than written out, because the two
		// have to agree exactly and a hand-counted byte is a silent
		// misreading of every vertex rather than an error.
		attributes = {
			{location = 0, buffer_slot = 0, format = .FLOAT3,  offset = u32(offset_of(Vertex3D_Skinned, pos))},
			{location = 1, buffer_slot = 0, format = .FLOAT3,  offset = u32(offset_of(Vertex3D_Skinned, normal))},
			{location = 2, buffer_slot = 0, format = .FLOAT2,  offset = u32(offset_of(Vertex3D_Skinned, uv))},
			{location = 3, buffer_slot = 0, format = .USHORT4, offset = u32(offset_of(Vertex3D_Skinned, joints))},
			{location = 4, buffer_slot = 0, format = .FLOAT4,  offset = u32(offset_of(Vertex3D_Skinned, weights))},
		}
		num_attributes = 5

	case .NONE:
		num_attributes = 0

	case .QUAD:
		fallthrough
	case:
		// Already filled in above.
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
		vertex_shader   = vertex_shader,
		fragment_shader = fragment,
		primitive_type  = .LINELIST if lines else .TRIANGLELIST,
		vertex_input_state = {
			vertex_buffer_descriptions = raw_data(vertex_buffers[:]),
			num_vertex_buffers         = num_vertex_buffers,
			vertex_attributes          = raw_data(attributes[:]),
			num_vertex_attributes      = num_attributes,
		},
		rasterizer_state = {
			fill_mode  = .FILL,
			cull_mode  = cull,

			// Counter-clockwise is front, which is what glTF produces and what
			// cube_model is wound to match.
			front_face = .COUNTER_CLOCKWISE,

			// Clip, do not clamp. SDL3 reads this field the way it is named --
			// false means depth *clamp*, where geometry outside the near and far
			// planes is squashed onto them and drawn anyway instead of being
			// discarded. Leaving it at the zero value gives you a near plane
			// that does not cut, which hides a whole class of projection bug
			// behind a picture that looks almost right.
			enable_depth_clip = true,

			// No depth bias, though a wireframe drawn over the surface it
			// outlines badly needs one. This state is specified for polygons and
			// a line list is not one, so setting it here is accepted and then
			// ignored -- which was tried, and cost an afternoon. The offset that
			// does work is in mesh_line.frag, which writes SV_Depth.
		},
		depth_stencil_state = {
			// Nearer wins, and nearer is the smaller number: the projections in
			// math3d.odin put the near plane at 0 and the far plane at 1.
			compare_op         = .LESS if depth else .INVALID,
			enable_depth_test  = depth,
			enable_depth_write = depth,
		},
		target_info = {
			color_target_descriptions = raw_data(color_targets[:]),
			num_color_targets         = 1,
			depth_stencil_format      = mbi.renderer.depth_format,
			has_depth_stencil_target  = depth || depth_ignore,
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
	/*
		Only when the caller has not set one. A game with its own logger wants
		its own logger.

		Testing the procedure against nil is not enough, and testing only that
		is why this did not work for a long time: Odin's default context does
		not leave the logger empty, it fills it with `nil_logger_proc`, which is
		a real procedure that discards what it is given. So the check was always
		false, the console logger was never made, and every `log.error` in
		Matchbox went nowhere -- including the ones the comment above is about.
		`core:log` makes the same two-part test internally.
	*/
	if context.logger.procedure == nil || context.logger.procedure == log.nil_logger_proc {
		mbi.logger     = log.create_console_logger()
		context.logger = mbi.logger
	} else {
		mbi.logger = context.logger
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
	#assert(size_of(Vertex3D)        == 32)
	#assert(size_of(Mesh_Vert_Data)  == 192)
	#assert(size_of(Mesh_Frag_Data)  == 16)
	#assert(size_of(Light_Uniform)   == 48)
	#assert(size_of(Lighting_Data)   == 272)
	#assert(size_of(Post_Frag_Data)  == 32)

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

	mbi.now_ts   = sdl.GetPerformanceCounter()
	mbi.start_ts = mbi.now_ts

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

	// 3D. One uniform buffer each: three matrices going in, a tint coming out.
	mbi.renderer.shaders.mesh = create_builtin_shader(
		#load("shaders/mesh.vert.spv"), #load("shaders/mesh.vert.dxil"), .VERTEX, 0)
	// Two uniform buffers, not one: slot 0 is the per-draw tint and slot 1 is
	// the lighting, which is pushed once for a whole pass.
	mbi.renderer.shaders.mesh_flat = create_builtin_shader(
		#load("shaders/mesh_flat.frag.spv"), #load("shaders/mesh_flat.frag.dxil"), .FRAGMENT, 0, 2)
	mbi.renderer.shaders.mesh_line = create_builtin_shader(
		#load("shaders/mesh_line.frag.spv"), #load("shaders/mesh_line.frag.dxil"), .FRAGMENT, 0)

	// Post-processing. One sampler -- the render target -- and one uniform
	// block shared by all three, so an effect that ignores a field ignores it.
	mbi.renderer.shaders.post = create_builtin_shader(
		#load("shaders/post.frag.spv"), #load("shaders/post.frag.dxil"), .FRAGMENT, 1)
	mbi.renderer.shaders.psx = create_builtin_shader(
		#load("shaders/psx.frag.spv"), #load("shaders/psx.frag.dxil"), .FRAGMENT, 1)
	mbi.renderer.shaders.vhs = create_builtin_shader(
		#load("shaders/vhs.frag.spv"), #load("shaders/vhs.frag.dxil"), .FRAGMENT, 1)
	// One sampler: the model's base colour. Two uniform buffers, as above.
	mbi.renderer.shaders.mesh_textured = create_builtin_shader(
		#load("shaders/mesh_textured.frag.spv"), #load("shaders/mesh_textured.frag.dxil"), .FRAGMENT, 1, 2)

	// Two uniform buffers rather than one: the three matrices every mesh vertex
	// shader takes, and the joint palette behind them.
	mbi.renderer.shaders.mesh_skinned = create_builtin_shader(
		#load("shaders/mesh_skinned.vert.spv"), #load("shaders/mesh_skinned.vert.dxil"), .VERTEX, 0, 2)

	mbi.renderer.shaders.skybox = create_builtin_shader(
		#load("shaders/skybox.vert.spv"), #load("shaders/skybox.vert.dxil"), .VERTEX, 0)
	mbi.renderer.shaders.skybox_panorama = create_builtin_shader(
		#load("shaders/skybox_panorama.frag.spv"), #load("shaders/skybox_panorama.frag.dxil"), .FRAGMENT, 1)
	mbi.renderer.shaders.skybox_cubemap = create_builtin_shader(
		#load("shaders/skybox_cubemap.frag.spv"), #load("shaders/skybox_cubemap.frag.dxil"), .FRAGMENT, 1)

	// Asked before any pipeline is built, because a depth-testing pipeline has
	// to name the format it will be used with and the answer cannot change
	// afterwards. It is a capability query and allocates nothing, so a game
	// that never draws 3D pays a function call for it and no memory.
	mbi.renderer.depth_format = pick_depth_format()

	mbi.renderer.pipelines.sprite  = create_pipeline(mbi.renderer.shaders.sprite)
	mbi.renderer.pipelines.rect    = create_pipeline(mbi.renderer.shaders.rect)
	mbi.renderer.pipelines.outline = create_pipeline(mbi.renderer.shaders.outline)
	mbi.renderer.pipelines.font    = create_pipeline(mbi.renderer.shaders.font)
	mbi.renderer.pipelines.shape   = create_pipeline(mbi.renderer.shaders.shape)

	mbi.renderer.pipelines.mesh = create_pipeline(
		mbi.renderer.shaders.mesh_flat,
		vertex = mbi.renderer.shaders.mesh,
		layout = .MESH,
		depth  = true,
		cull   = .BACK,
	)

	mbi.renderer.pipelines.post = create_pipeline(mbi.renderer.shaders.post)
	mbi.renderer.pipelines.psx  = create_pipeline(mbi.renderer.shaders.psx)
	mbi.renderer.pipelines.vhs  = create_pipeline(mbi.renderer.shaders.vhs)

	mbi.renderer.pipelines.mesh_textured = create_pipeline(
		mbi.renderer.shaders.mesh_textured,
		vertex = mbi.renderer.shaders.mesh,
		layout = .MESH,
		depth  = true,
		cull   = .BACK,
	)

	mbi.renderer.pipelines.mesh_skinned = create_pipeline(
		mbi.renderer.shaders.mesh_flat,
		vertex = mbi.renderer.shaders.mesh_skinned,
		layout = .SKINNED,
		depth  = true,
		cull   = .BACK,
	)

	mbi.renderer.pipelines.mesh_skinned_textured = create_pipeline(
		mbi.renderer.shaders.mesh_textured,
		vertex = mbi.renderer.shaders.mesh_skinned,
		layout = .SKINNED,
		depth  = true,
		cull   = .BACK,
	)

	// No geometry, no culling and no depth. Drawn first, so everything after it
	// covers it; see draw_skybox.
	mbi.renderer.pipelines.skybox_panorama = create_pipeline(
		mbi.renderer.shaders.skybox_panorama,
		vertex       = mbi.renderer.shaders.skybox,
		layout       = .NONE,
		depth        = false,
		cull         = .NONE,
		depth_ignore = true,
	)

	mbi.renderer.pipelines.skybox_cubemap = create_pipeline(
		mbi.renderer.shaders.skybox_cubemap,
		vertex       = mbi.renderer.shaders.skybox,
		layout       = .NONE,
		depth        = false,
		cull         = .NONE,
		depth_ignore = true,
	)

	// Lines are never culled -- an edge has no facing -- and they are biased
	// towards the camera. See `lines` in create_pipeline for why.
	mbi.renderer.pipelines.line = create_pipeline(
		mbi.renderer.shaders.mesh_line,
		vertex = mbi.renderer.shaders.mesh,
		layout = .MESH,
		depth  = true,
		cull   = .NONE,
		lines  = true,
	)

	// Every sprite wants the same filtering, and the font wants smoothing, so
	// two samplers serve the whole program.
	mbi.renderer.sprite_sampler = sdl.CreateGPUSampler(mbi.renderer.device, {
		min_filter = .NEAREST, mag_filter = .NEAREST,
	})
	mbi.renderer.font_sampler = sdl.CreateGPUSampler(mbi.renderer.device, {
		min_filter = .LINEAR, mag_filter = .LINEAR,
	})

	// A panorama wraps in u and clamps in v: longitude comes back round to
	// itself, latitude stops at the poles. Without the wrap there is a seam
	// line down the sky where the filter runs off the edge of the image.
	mbi.renderer.skybox_wrap_sampler = sdl.CreateGPUSampler(mbi.renderer.device, {
		min_filter    = .LINEAR,
		mag_filter    = .LINEAR,
		address_mode_u = .REPEAT,
		address_mode_v = .CLAMP_TO_EDGE,
		address_mode_w = .CLAMP_TO_EDGE,
	})

	// A cube map clamps on all three. The hardware filters across the seams
	// between faces itself, and a wrapping address mode fights it.
	mbi.renderer.skybox_clamp_sampler = sdl.CreateGPUSampler(mbi.renderer.device, {
		min_filter    = .LINEAR,
		mag_filter    = .LINEAR,
		address_mode_u = .CLAMP_TO_EDGE,
		address_mode_v = .CLAMP_TO_EDGE,
		address_mode_w = .CLAMP_TO_EDGE,
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
	if mbi.renderer.pipelines.mesh    != nil do sdl.ReleaseGPUGraphicsPipeline(device, mbi.renderer.pipelines.mesh)
	if mbi.renderer.pipelines.line    != nil do sdl.ReleaseGPUGraphicsPipeline(device, mbi.renderer.pipelines.line)
	if mbi.renderer.pipelines.mesh_textured != nil do sdl.ReleaseGPUGraphicsPipeline(device, mbi.renderer.pipelines.mesh_textured)
	if mbi.renderer.pipelines.mesh_skinned != nil do sdl.ReleaseGPUGraphicsPipeline(device, mbi.renderer.pipelines.mesh_skinned)
	if mbi.renderer.pipelines.mesh_skinned_textured != nil do sdl.ReleaseGPUGraphicsPipeline(device, mbi.renderer.pipelines.mesh_skinned_textured)
	if mbi.renderer.pipelines.skybox_panorama != nil do sdl.ReleaseGPUGraphicsPipeline(device, mbi.renderer.pipelines.skybox_panorama)
	if mbi.renderer.pipelines.skybox_cubemap != nil do sdl.ReleaseGPUGraphicsPipeline(device, mbi.renderer.pipelines.skybox_cubemap)
	if mbi.renderer.pipelines.post    != nil do sdl.ReleaseGPUGraphicsPipeline(device, mbi.renderer.pipelines.post)
	if mbi.renderer.pipelines.psx     != nil do sdl.ReleaseGPUGraphicsPipeline(device, mbi.renderer.pipelines.psx)
	if mbi.renderer.pipelines.vhs     != nil do sdl.ReleaseGPUGraphicsPipeline(device, mbi.renderer.pipelines.vhs)

	if mbi.renderer.shaders.quad    != nil do sdl.ReleaseGPUShader(device, mbi.renderer.shaders.quad)
	if mbi.renderer.shaders.sprite  != nil do sdl.ReleaseGPUShader(device, mbi.renderer.shaders.sprite)
	if mbi.renderer.shaders.rect    != nil do sdl.ReleaseGPUShader(device, mbi.renderer.shaders.rect)
	if mbi.renderer.shaders.outline != nil do sdl.ReleaseGPUShader(device, mbi.renderer.shaders.outline)
	if mbi.renderer.shaders.font    != nil do sdl.ReleaseGPUShader(device, mbi.renderer.shaders.font)
	if mbi.renderer.shaders.shape   != nil do sdl.ReleaseGPUShader(device, mbi.renderer.shaders.shape)
	if mbi.renderer.shaders.mesh      != nil do sdl.ReleaseGPUShader(device, mbi.renderer.shaders.mesh)
	if mbi.renderer.shaders.mesh_flat != nil do sdl.ReleaseGPUShader(device, mbi.renderer.shaders.mesh_flat)
	if mbi.renderer.shaders.mesh_line != nil do sdl.ReleaseGPUShader(device, mbi.renderer.shaders.mesh_line)
	if mbi.renderer.shaders.mesh_textured != nil do sdl.ReleaseGPUShader(device, mbi.renderer.shaders.mesh_textured)
	if mbi.renderer.shaders.mesh_skinned != nil do sdl.ReleaseGPUShader(device, mbi.renderer.shaders.mesh_skinned)
	if mbi.renderer.shaders.skybox != nil do sdl.ReleaseGPUShader(device, mbi.renderer.shaders.skybox)
	if mbi.renderer.shaders.skybox_panorama != nil do sdl.ReleaseGPUShader(device, mbi.renderer.shaders.skybox_panorama)
	if mbi.renderer.shaders.skybox_cubemap != nil do sdl.ReleaseGPUShader(device, mbi.renderer.shaders.skybox_cubemap)
	if mbi.renderer.shaders.post != nil do sdl.ReleaseGPUShader(device, mbi.renderer.shaders.post)
	if mbi.renderer.shaders.psx  != nil do sdl.ReleaseGPUShader(device, mbi.renderer.shaders.psx)
	if mbi.renderer.shaders.vhs  != nil do sdl.ReleaseGPUShader(device, mbi.renderer.shaders.vhs)

	// The generated shapes, if anything ever asked for one.
	shapes3d_destroy()

	// Only ever made if the game asked for a 3D pass.
	if mbi.renderer.depth_texture != nil {
		sdl.ReleaseGPUTexture(device, mbi.renderer.depth_texture)
		mbi.renderer.depth_texture = nil
	}

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

	// Through SDL, so a shader shipped inside an apk is reachable. Still a panic
	// rather than a false, unlike the content loaders: a missing shader is a
	// broken build rather than a broken file somebody chose.
	data, read := read_entire_file(full, context.allocator)
	if !read {
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
