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
		can be fetched from. get_pref_path makes the directory if it is not there.
	*/
	path := "gpu-report.txt"

	if exe := os.args[0]; exe != "" {
		if cut := strings.last_index_any(exe, "/\\"); cut >= 0 {
			path = fmt.tprintf("%s/gpu-report.txt", exe[:cut])
		}
	}

	report := fmt.tprintf("%s%s", header, body)

	if !write_report_file(path, report) {
		if dir := get_pref_path("matchbox", mbi.title, context.temp_allocator); dir != "" {
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
	spirv, dxil:          []u8,
	stage:                sdl.GPUShaderStage,
	num_samplers:         u32,
	num_uniform_buffers:  u32 = 1,
	num_storage_buffers:  u32 = 0,
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
		code_size            = len(code),
		code                 = raw_data(code),
		entrypoint           = "main",
		format               = format,
		stage                = stage,
		num_samplers         = num_samplers,
		num_uniform_buffers  = num_uniform_buffers,
		num_storage_buffers  = num_storage_buffers,
	})

	if shader == nil {
		log.errorf("could not create shader: %s", sdl.GetError())
		panic("could not create a built-in shader")
	}

	return shader
}

/*
	How many colour targets `create_pipeline` will ever hand SDL3 at once.

	4 rather than a bigger, safer-looking number: Vulkan's own spec only
	guarantees `maxColorAttachments >= 4` (D3D12 and Metal both promise 8, but
	this package targets Android, where Vulkan's own floor is the one that
	matters -- the same reasoning `MESH_FRAG_SAMPLER_COUNT`'s own doc comment
	gives for pinning against Vulkan's sampler floor rather than a desktop
	driver's actual, higher number). P6's own G-buffer is exactly 4 targets
	for that reason -- see `pipeline_deferred.odin`'s own top comment -- so
	this is sized to what this package actually asks for, not rounded up.

	An array size, so CLAUDE.md's "no loose constants" carves it out the same
	way `MAX_LIGHTS`'s retired siblings (`MAX_CASCADES`, `MAX_SHADOW_CASTERS`)
	already are.
*/
@(private)
MAX_COLOR_TARGETS :: 4

/*
	How a pipeline's colour target combines what a fragment produces with what
	is already there.

	`ALPHA` is the source-alpha blend every draw in this package used before
	there was anything else, and is what all but three pipelines want.

	`NONE` writes the fragment straight through. The G-buffer fill needs it:
	blending two unrelated materials' normals or roughness together where
	their triangles anti-alias against each other is not a value a lighting
	pass could make sense of.

	`ADDITIVE` sums colour and overwrites alpha. Volumetric light needs it
	(volumetric.odin) -- light scattering off the air is scene light, and it
	is added to the HDR target the 3D pass already wrote rather than
	composited later.

	**P7a considered this enum and rejected it**, and the record is worth
	keeping: the bloom chain's upsample looked like it needed an additive
	mode, and turned out to want the ordinary alpha blend with its own mix
	weight written into alpha instead -- a better answer for reasons that had
	nothing to do with blend state (see bloom_upsample.frag.hlsl). So the bool
	stayed a bool. P7b is the caller that could not be talked out of it: there
	is no alpha a fullscreen additive pass could write that would make
	source-alpha blending sum two values.
*/
@(private)
Color_Blend :: enum {
	ALPHA,
	NONE,
	ADDITIVE,
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

	// False for the shadow pass alone, which writes nothing but depth -- SDL3
	// permits zero colour targets on a pipeline, and the pass it runs in
	// opens with none bound to match. Every other caller keeps the one
	// colour target every pipeline before this had.
	color_target: bool = true,

	// .INVALID means "whatever the main 3D pass's own depth buffer is",
	// which is every caller before the shadow pass. The shadow pipelines are
	// the one exception: their pass writes into one of
	// `mbi.renderer.lighting.shadow.textures`, a separate, differently-sized, possibly
	// differently-formatted texture, and a pipeline's depth format has to
	// agree with the pass it runs in or SDL3 rejects it outright.
	depth_format: sdl.GPUTextureFormat = .INVALID,

	/*
		.INVALID means "the swapchain's own format", which is every 2D
		pipeline, including the tonemap resolve itself -- it writes into
		current_color_texture(), never into the HDR target it reads from.
		The five pipelines that draw inside the 3D pass (mesh, mesh_skinned,
		line, both skyboxes) pass mbi.renderer.lighting.targets.format
		instead: SDL3 bakes a pipeline's colour format in at creation the
		same way it does the depth format above, so a pipeline built against
		the swapchain's format cannot be bound in the HDR pass and vice
		versa. See tonemap.odin's own top comment for why that pass exists
		at all.
	*/
	color_format: sdl.GPUTextureFormat = .INVALID,

	// Zero for every pipeline except the shadow pair, which need a push away
	// from the surface they are rasterizing before comparing it against
	// itself from the light's own point of view -- see shadow.odin for why a
	// constant-plus-slope bias is what fixes that rather than a shader-side
	// epsilon alone.
	depth_bias:       f32 = 0,
	depth_bias_slope: f32 = 0,

	/*
		P6's own addition, for the G-buffer fill pipelines
		(`pipeline_deferred.odin`) -- a G-buffer pass writes several targets
		at once, which `color_target`/`color_format` above have no room to
		say (they are one bool and one format, the shape every pipeline
		before this one needed). Non-nil overrides `color_target`/
		`color_format` entirely: `len(color_formats)` targets are created,
		each in its own listed format, and neither of the older two
		parameters is read at all in that case.

		Left nil, which is every caller before this phase, behaviour is
		bit-for-bit what it always was -- this is purely additive, the same
		"grew without disturbing an existing caller" shape `MESH_FRAG_SAMPLER_COUNT`
		itself grew by across P3b and P4 without any caller of
		`create_builtin_shader` needing to change.
	*/
	color_formats: []sdl.GPUTextureFormat = nil,

	// How the colour target(s) built here combine with what is already in
	// them -- see `Color_Blend`.
	blend: Color_Blend = .ALPHA,
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
			{location = 3, buffer_slot = 0, format = .UINT4,   offset = u32(offset_of(Vertex3D_Skinned, joints))},
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

	blend_state := sdl.GPUColorTargetBlendState{
		enable_blend            = blend != .NONE,
		color_blend_op          = .ADD,

		// ONE rather than SRC_ALPHA is the whole difference between the two
		// enabled modes: the source contributes in full instead of being
		// weighted by an alpha the additive callers do not write. Alpha
		// itself is ONE/ZERO either way, so the destination's alpha becomes
		// the source's -- and nothing downstream of either mode reads it.
		src_color_blendfactor   = .ONE if blend == .ADDITIVE else .SRC_ALPHA,
		dst_color_blendfactor   = .ONE if blend == .ADDITIVE else .ONE_MINUS_SRC_ALPHA,

		alpha_blend_op          = .ADD,
		src_alpha_blendfactor   = .ONE,
		dst_alpha_blendfactor   = .ZERO,
		enable_color_write_mask = true,
		color_write_mask        = {.R, .G, .B, .A},
	}

	color_targets:     [MAX_COLOR_TARGETS]sdl.GPUColorTargetDescription
	num_color_targets: u32

	switch {
	case len(color_formats) > 0:
		ensure(len(color_formats) <= MAX_COLOR_TARGETS, "create_pipeline: more color_formats than MAX_COLOR_TARGETS")
		for format, i in color_formats {
			color_targets[i] = sdl.GPUColorTargetDescription{format = format, blend_state = blend_state}
		}
		num_color_targets = u32(len(color_formats))
	case color_target:
		color_targets[0] = sdl.GPUColorTargetDescription{
			format      = color_format if color_format != .INVALID else sdl.GetGPUSwapchainTextureFormat(mbi.renderer.device, mbi.window),
			blend_state = blend_state,
		}
		num_color_targets = 1
	case:
		num_color_targets = 0
	}

	color_target_descriptions: [^]sdl.GPUColorTargetDescription = raw_data(color_targets[:]) if num_color_targets > 0 else nil

	resolved_depth_format := depth_format if depth_format != .INVALID else mbi.renderer.depth_format

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
			// create_cube_model is wound to match.
			front_face = .COUNTER_CLOCKWISE,

			// Clip, do not clamp. SDL3 reads this field the way it is named --
			// false means depth *clamp*, where geometry outside the near and far
			// planes is squashed onto them and drawn anyway instead of being
			// discarded. Leaving it at the zero value gives you a near plane
			// that does not cut, which hides a whole class of projection bug
			// behind a picture that looks almost right.
			enable_depth_clip = true,

			// Zero for every polygon pipeline except the shadow pair. A
			// wireframe drawn over the surface it outlines badly needs a bias
			// too, but this state is specified for polygons and a line list
			// is not one -- setting it here for mesh_line was tried, silently
			// ignored, and cost an afternoon. The offset that works there is
			// in mesh_line.frag, which writes SV_Depth directly instead.
			enable_depth_bias          = depth_bias != 0 || depth_bias_slope != 0,
			depth_bias_constant_factor = depth_bias,
			depth_bias_slope_factor    = depth_bias_slope,
		},
		depth_stencil_state = {
			// Nearer wins, and nearer is the smaller number: the projections in
			// math3d.odin put the near plane at 0 and the far plane at 1.
			compare_op         = .LESS if depth else .INVALID,
			enable_depth_test  = depth,
			enable_depth_write = depth,
		},
		target_info = {
			color_target_descriptions = color_target_descriptions,
			num_color_targets         = num_color_targets,
			depth_stencil_format      = resolved_depth_format,
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

	mbi.input.gamepad_deadzone          = GAMEPAD_DEFAULTS.stick_deadzone
	mbi.input.gamepad_trigger_threshold = GAMEPAD_DEFAULTS.trigger_threshold

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
	#assert(size_of(Vert_Data)        == 48)
	#assert(size_of(Sprite_Frag_Data) == 32)
	#assert(size_of(Shape_Frag_Data)  == 48)
	#assert(size_of(Outline_Frag_Data) == 32)
	#assert(size_of(Font_Frag_Data)    == 16)
	#assert(size_of(Rect_Frag_Data)  == 16)
	#assert(size_of(Vertex3D)          == 32)
	#assert(size_of(Mesh_Vert_Data)    == 192)
	#assert(size_of(Tint_Frag_Data)    == 16)
	#assert(size_of(Material_Frag_Data) == 112)
	#assert(size_of(Light_Uniform)     == 112)
	#assert(size_of(Scene_Frag_Data)   == 288)
	#assert(size_of(Cluster_Range)     == 8)
	#assert(size_of(Cascade_Frag_Data) == 544)
	#assert(size_of(Cube_Frag_Data)    == 400)
	#assert(size_of(Post_Frag_Data)    == 32)
	#assert(size_of(Tonemap_Resolve_Frag_Data) == 80)
	#assert(size_of(Probe_Prefilter_Frag_Data) == 16)
	#assert(size_of(Bloom_Filter_Frag_Data)    == 16)
	#assert(size_of(Bloom_Prefilter_Frag_Data) == 32)
	#assert(size_of(Ssao_Frag_Data)            == 704)
	#assert(size_of(Ssao_Blur_Frag_Data)       == 16)
	#assert(size_of(Volumetric_Frag_Data)      == 96)
	#assert(size_of(Probe_Frag_Data)           == 144)
	#assert(size_of(Deferred_Lighting_Frag_Data) == 64)

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
	/*
		One fragment shader for every solid mesh part, textured or not -- see
		mesh.frag.hlsl's own doc comment and Shaders.mesh_frag's. Four uniform
		buffers: slot 0 the per-part material (material.odin), slot 1 the
		scene (lighting.odin), slot 2 CASCADED's own Cascade_Data, slot 3
		CUBE's own Cube_Data -- the last two pushed every pass regardless of
		which technique is running, see Cascade_Frag_Data/Cube_Frag_Data's
		own doc comments (lighting.odin) for why they are split out of Scene
		rather than folded into it. MESH_FRAG_SAMPLER_COUNT (render.odin)
		sampled textures -- base colour, three material maps, PCF/PCSS's two
		shadow maps, one Texture2DArray each for CASCADED and CUBE, and the
		environment probe's own two maps, t0-t9 -- and three storage buffers:
		the light list (light.odin) at t10, and CLUSTERED's own
		cluster_ranges/cluster_light_indices (light_cull.odin) at t11/t12,
		bound to a 1-element placeholder under FORWARD rather than left
		unbound (pipeline_forward.odin) since mesh.frag.hlsl declares all
		three unconditionally. See lighting_core.hlsli's own comment on
		`lights` for why a storage buffer's register number has to track the
		sampler count like this.

		This was twenty samplers through P3 -- one flat Texture2D per
		CASCADED/CUBE layer rather than one Texture2DArray per group -- which
		sits above Vulkan's guaranteed floor for both
		maxPerStageDescriptorSampledImages and maxPerStageDescriptorSamplers
		(16 each); see lighting_rework.md section 7.7 and
		render_test.odin for the regression this collapse is guarding
		against.
	*/
	mbi.renderer.shaders.mesh_frag = create_builtin_shader(
		#load("shaders/mesh.frag.spv"), #load("shaders/mesh.frag.dxil"), .FRAGMENT, MESH_FRAG_SAMPLER_COUNT, 5, 3)
	mbi.renderer.shaders.mesh_line = create_builtin_shader(
		#load("shaders/mesh_line.frag.spv"), #load("shaders/mesh_line.frag.dxil"), .FRAGMENT, 0)

	/*
		DEFERRED's own two fragment shaders (pipeline_deferred.odin).
		`gbuffer_frag` reads the four material textures and the identical
		`Material` cbuffer mesh_frag does (one uniform buffer, no storage
		buffers, four samplers) -- see gbuffer.frag.hlsl's own top comment
		for why it needs nothing shade_surface itself needs.
		`deferred_lighting_frag` is DEFERRED_LIGHTING_SAMPLER_COUNT samplers,
		its own one uniform buffer (Deferred_Lighting_Frag_Data) plus the
		three lighting_core.hlsli always pushes (Scene/Cascade/Cube, the same
		4 total mesh_frag takes), and the same three storage buffers
		(lights/cluster_ranges/cluster_light_indices) mesh_frag also
		declares -- see deferred_lighting.frag.hlsl's own top comment for
		the register renumbering that makes eleven samplers fit ahead of
		them instead of ten.
	*/
	mbi.renderer.shaders.gbuffer_frag = create_builtin_shader(
		#load("shaders/gbuffer.frag.spv"), #load("shaders/gbuffer.frag.dxil"), .FRAGMENT, 4, 1, 0)
	mbi.renderer.shaders.fullscreen = create_builtin_shader(
		#load("shaders/fullscreen.vert.spv"), #load("shaders/fullscreen.vert.dxil"), .VERTEX, 0, 0)
	mbi.renderer.shaders.deferred_lighting_frag = create_builtin_shader(
		#load("shaders/deferred_lighting.frag.spv"), #load("shaders/deferred_lighting.frag.dxil"),
		.FRAGMENT, DEFERRED_LIGHTING_SAMPLER_COUNT, 5, 3)

	// Post-processing. One sampler -- the render target -- and one uniform
	// block shared by all three, so an effect that ignores a field ignores it.
	mbi.renderer.shaders.post = create_builtin_shader(
		#load("shaders/post.frag.spv"), #load("shaders/post.frag.dxil"), .FRAGMENT, 1)
	mbi.renderer.shaders.psx = create_builtin_shader(
		#load("shaders/psx.frag.spv"), #load("shaders/psx.frag.dxil"), .FRAGMENT, 1)
	mbi.renderer.shaders.vhs = create_builtin_shader(
		#load("shaders/vhs.frag.spv"), #load("shaders/vhs.frag.dxil"), .FRAGMENT, 1)

	// The tonemap resolve -- **two** samplers since P7a (the HDR target at
	// t0, the bloom chain's level 0 at t1, which is a 1x1 black placeholder
	// whenever bloom is off) and one uniform block: exposure, which curve,
	// the bloom intensity and the whole colour grade. See tonemap.odin, and
	// post.odin for why the grade rides here rather than in a pass of its own.
	mbi.renderer.shaders.tonemap = create_builtin_shader(
		#load("shaders/tonemap.frag.spv"), #load("shaders/tonemap.frag.dxil"), .FRAGMENT, 2)

	// The bloom chain (bloom.odin). One sampler each -- whichever level or
	// scene target that pass is reading -- and one uniform block each, which
	// is a texel size for two of them and a texel size plus the brightness
	// knee for the prefilter.
	mbi.renderer.shaders.bloom_prefilter = create_builtin_shader(
		#load("shaders/bloom_prefilter.frag.spv"), #load("shaders/bloom_prefilter.frag.dxil"), .FRAGMENT, 1)
	mbi.renderer.shaders.bloom_downsample = create_builtin_shader(
		#load("shaders/bloom_downsample.frag.spv"), #load("shaders/bloom_downsample.frag.dxil"), .FRAGMENT, 1)
	mbi.renderer.shaders.bloom_upsample = create_builtin_shader(
		#load("shaders/bloom_upsample.frag.spv"), #load("shaders/bloom_upsample.frag.dxil"), .FRAGMENT, 1)

	// SSAO (ssao.odin). One sampler each -- the depth buffer, then the AO
	// texture the first pass wrote -- and one uniform block each.
	mbi.renderer.shaders.ssao = create_builtin_shader(
		#load("shaders/ssao.frag.spv"), #load("shaders/ssao.frag.dxil"), .FRAGMENT, 1)
	mbi.renderer.shaders.ssao_blur = create_builtin_shader(
		#load("shaders/ssao_blur.frag.spv"), #load("shaders/ssao_blur.frag.dxil"), .FRAGMENT, 1)

	// Volumetric light (volumetric.odin). Eight samplers -- the depth buffer,
	// the four shadow textures, the two probe maps and the AO texture, the
	// last three of which it never reads and must still declare, since
	// lighting_core.hlsli declares them for every shader that includes it.
	// Four uniform blocks (its own, plus Scene/Cascade/Cube) and the same
	// three storage buffers every shader that includes that file gets.
	mbi.renderer.shaders.volumetric = create_builtin_shader(
		#load("shaders/volumetric.frag.spv"), #load("shaders/volumetric.frag.dxil"),
		.FRAGMENT, VOLUMETRIC_SAMPLER_COUNT, 5, 3)

	/*
		Environment probe baking (ambient.odin). Both read one sampler -- the
		source skybox's own cube map -- through the same `skybox.vert.hlsl`
		vertex shader `Shaders.skybox` already loaded above, reused rather
		than duplicated (see Shaders.probe_irradiance's own comment).
		`probe_irradiance` needs no uniform buffer at all: which face it is
		baking is entirely a function of the vertex data pushed for that
		draw. `probe_prefilter` needs one -- the roughness level being baked
		-- since one fragment shader bakes every level, not one per level.
	*/
	mbi.renderer.shaders.probe_irradiance = create_builtin_shader(
		#load("shaders/probe_irradiance.frag.spv"), #load("shaders/probe_irradiance.frag.dxil"), .FRAGMENT, 1, 0)
	mbi.renderer.shaders.probe_prefilter = create_builtin_shader(
		#load("shaders/probe_prefilter.frag.spv"), #load("shaders/probe_prefilter.frag.dxil"), .FRAGMENT, 1, 1)

	// Two uniform buffers -- the three matrices every mesh vertex shader
	// takes, and the joint offset behind them -- plus one storage buffer: the
	// joint palette itself, unbounded, where a uniform capped at 64 matrices
	// on Vulkan. See Skin_Vert_Data in types.odin.
	mbi.renderer.shaders.mesh_skinned = create_builtin_shader(
		#load("shaders/mesh_skinned.vert.spv"), #load("shaders/mesh_skinned.vert.dxil"), .VERTEX, 0, 2, 1)

	// No samplers and no uniform buffers of its own -- it writes nothing, see
	// shadow.frag.hlsl. Paired with mesh.vert/mesh_skinned.vert below rather
	// than a vertex shader of its own, since those already declare exactly
	// the layout and uniforms a shadow caster needs.
	mbi.renderer.shaders.shadow = create_builtin_shader(
		#load("shaders/shadow.frag.spv"), #load("shaders/shadow.frag.dxil"), .FRAGMENT, 0, 0)

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

	// Asked for now, same reasoning: mesh/mesh_skinned/line/both skyboxes
	// below all need it at creation, and the answer cannot change afterward.
	// See tonemap.odin's own top comment for why these five need a format of
	// their own at all.
	mbi.renderer.lighting.targets.format = pick_hdr_format()

	mbi.renderer.pipelines.sprite  = create_pipeline(mbi.renderer.shaders.sprite)
	mbi.renderer.pipelines.rect    = create_pipeline(mbi.renderer.shaders.rect)
	mbi.renderer.pipelines.outline = create_pipeline(mbi.renderer.shaders.outline)
	mbi.renderer.pipelines.font    = create_pipeline(mbi.renderer.shaders.font)
	mbi.renderer.pipelines.shape   = create_pipeline(mbi.renderer.shaders.shape)

	mbi.renderer.pipelines.mesh = create_pipeline(
		mbi.renderer.shaders.mesh_frag,
		vertex       = mbi.renderer.shaders.mesh,
		layout       = .MESH,
		depth        = true,
		cull         = .BACK,
		color_format = mbi.renderer.lighting.targets.format,
	)

	mbi.renderer.pipelines.post    = create_pipeline(mbi.renderer.shaders.post)
	mbi.renderer.pipelines.psx     = create_pipeline(mbi.renderer.shaders.psx)
	mbi.renderer.pipelines.vhs     = create_pipeline(mbi.renderer.shaders.vhs)
	mbi.renderer.pipelines.tonemap = create_pipeline(mbi.renderer.shaders.tonemap)

	/*
		The bloom chain (bloom.odin). Built against the HDR target's own float
		format rather than the swapchain's, because every level of the chain
		holds unbounded linear light -- the same reason the five pipelines
		that draw *inside* the 3D pass need it, arrived at from the other
		side: these draw after that pass has closed but still never touch the
		swapchain.

		All three take the ordinary source-alpha blend, including the
		upsample: it writes `scatter` into its own alpha and lets that blend
		do the mixing, rather than needing a blend mode of its own. See
		bloom_upsample.frag.hlsl for why mixing and not adding.
	*/
	mbi.renderer.pipelines.bloom_prefilter = create_pipeline(
		mbi.renderer.shaders.bloom_prefilter,
		color_format = mbi.renderer.lighting.targets.format,
	)
	mbi.renderer.pipelines.bloom_downsample = create_pipeline(
		mbi.renderer.shaders.bloom_downsample,
		color_format = mbi.renderer.lighting.targets.format,
	)
	mbi.renderer.pipelines.bloom_upsample = create_pipeline(
		mbi.renderer.shaders.bloom_upsample,
		color_format = mbi.renderer.lighting.targets.format,
	)

	/*
		SSAO's own two. The device's answer for the AO format is settled here
		rather than at first use, for the same reason the G-buffer's is
		(`ensure_gbuffer_targets`): SDL3 bakes a colour format into a pipeline
		at creation and the answer cannot change afterward, so asking now
		means `ensure_ssao_targets` later finds it already resolved rather
		than picking one a pipeline was not built against.
	*/
	mbi.renderer.lighting.ssao.format = pick_ssao_format()

	/*
		P7c's capture bookkeeping starts at -1, which is the one field in this
		package whose zero value is actively wrong: `begin_probe_capture`
		asserts that no capture is already open by testing `capturing_probe < 0`,
		and a zero would read as "probe 0 is mid-capture" and fire that
		assertion on the very first call. Set here rather than defended against
		at the use site, so there is one answer rather than two.
	*/
	mbi.renderer.lighting.reflection.capturing_probe = -1
	mbi.renderer.lighting.reflection.capturing_face  = -1
	mbi.renderer.lighting.reflection.settings        = ENVIRONMENT_PROBE_DEFAULTS

	mbi.renderer.pipelines.ssao = create_pipeline(
		mbi.renderer.shaders.ssao,
		color_format = mbi.renderer.lighting.ssao.format,
	)
	mbi.renderer.pipelines.ssao_blur = create_pipeline(
		mbi.renderer.shaders.ssao_blur,
		color_format = mbi.renderer.lighting.ssao.format,
	)

	// Volumetric light: the HDR target's own format, since it adds into it,
	// and the one additive pipeline here.
	mbi.renderer.pipelines.volumetric = create_pipeline(
		mbi.renderer.shaders.volumetric,
		color_format = mbi.renderer.lighting.targets.format,
		blend        = .ADDITIVE,
	)

	/*
		Environment probe baking -- the skybox's own vertex shader (no
		geometry, SV_VertexID triangle, see Vertex_Layout.NONE), no depth
		(these write into a Texture2DArray of their own, never into any pass
		a game's draw calls share), and the HDR target's own float format --
		see ambient.odin's own top comment for why these write float-format
		targets that are never the swapchain.
	*/
	mbi.renderer.pipelines.probe_irradiance = create_pipeline(
		mbi.renderer.shaders.probe_irradiance,
		vertex       = mbi.renderer.shaders.skybox,
		layout       = .NONE,
		depth        = false,
		cull         = .NONE,
		color_format = mbi.renderer.lighting.targets.format,
	)
	mbi.renderer.pipelines.probe_prefilter = create_pipeline(
		mbi.renderer.shaders.probe_prefilter,
		vertex       = mbi.renderer.shaders.skybox,
		layout       = .NONE,
		depth        = false,
		cull         = .NONE,
		color_format = mbi.renderer.lighting.targets.format,
	)

	mbi.renderer.pipelines.mesh_skinned = create_pipeline(
		mbi.renderer.shaders.mesh_frag,
		vertex       = mbi.renderer.shaders.mesh_skinned,
		layout       = .SKINNED,
		depth        = true,
		cull         = .BACK,
		color_format = mbi.renderer.lighting.targets.format,
	)

	/*
		DEFERRED's own three pipelines -- see pipeline_deferred.odin's own
		top comment and Pipelines.gbuffer's own doc comment (render.odin)
		just above. Both formats are asked for now, same reasoning as
		`lighting.targets.format`/`lighting.shadow.format` just above and
		below: a depth-testing or MRT pipeline has to name its formats at
		creation and the answer cannot change afterward, so `ensure_gbuffer_targets`
		(gbuffer.odin) later finds both already resolved rather than picking
		them itself.
	*/
	mbi.renderer.lighting.gbuffer.format       = pick_gbuffer_format()
	mbi.renderer.lighting.gbuffer.depth_format = pick_shadow_format()

	gbuffer_formats := [4]sdl.GPUTextureFormat{
		mbi.renderer.lighting.gbuffer.format,
		mbi.renderer.lighting.gbuffer.format,
		mbi.renderer.lighting.gbuffer.format,
		mbi.renderer.lighting.gbuffer.format,
	}

	mbi.renderer.pipelines.gbuffer = create_pipeline(
		mbi.renderer.shaders.gbuffer_frag,
		vertex         = mbi.renderer.shaders.mesh,
		layout         = .MESH,
		depth          = true,
		cull           = .BACK,
		depth_format   = mbi.renderer.lighting.gbuffer.depth_format,
		color_formats  = gbuffer_formats[:],
		blend          = .NONE, // a fill pass writes Surface fields, not colours to blend -- see Material.transparent's own doc comment (material.odin)
	)

	mbi.renderer.pipelines.gbuffer_skinned = create_pipeline(
		mbi.renderer.shaders.gbuffer_frag,
		vertex         = mbi.renderer.shaders.mesh_skinned,
		layout         = .SKINNED,
		depth          = true,
		cull           = .BACK,
		depth_format   = mbi.renderer.lighting.gbuffer.depth_format,
		color_formats  = gbuffer_formats[:],
		blend          = .NONE,
	)

	// Built the same shape skybox_panorama/skybox_cubemap already are (just
	// below) -- Vertex_Layout.NONE, depth_ignore rather than depth, the HDR
	// target's own colour format -- so it runs in the identical final pass
	// those two and the forward-fallback mesh/line pipelines already share.
	// See pipeline_deferred.odin's own top comment for that pass's shape.
	mbi.renderer.pipelines.deferred_lighting = create_pipeline(
		mbi.renderer.shaders.deferred_lighting_frag,
		vertex       = mbi.renderer.shaders.fullscreen,
		layout       = .NONE,
		depth        = false,
		cull         = .NONE,
		depth_ignore = true,
		color_format = mbi.renderer.lighting.targets.format,
	)

	/*
		The shadow pass's own pair, depth-only and biased away from the
		surface they rasterize -- see create_pipeline's own comment on
		depth_bias for why a wireframe's line pipeline cannot use this same
		mechanism and these two, being ordinary triangle lists, can.

		mbi.renderer.lighting.shadow.format is asked for here rather than reused from
		mbi.renderer.depth_format: the shadow map is sampled as well as
		written, a combination the main depth buffer never needs, and the two
		can legitimately land on different formats.
	*/
	mbi.renderer.lighting.shadow.format = pick_shadow_format()

	mbi.renderer.pipelines.shadow = create_pipeline(
		mbi.renderer.shaders.shadow,
		vertex           = mbi.renderer.shaders.mesh,
		layout           = .MESH,
		depth            = true,
		cull             = .BACK,
		color_target     = false,
		depth_format     = mbi.renderer.lighting.shadow.format,
		depth_bias       = 2.0,
		depth_bias_slope = 2.0,
	)

	mbi.renderer.pipelines.shadow_skinned = create_pipeline(
		mbi.renderer.shaders.shadow,
		vertex           = mbi.renderer.shaders.mesh_skinned,
		layout           = .SKINNED,
		depth            = true,
		cull             = .BACK,
		color_target     = false,
		depth_format     = mbi.renderer.lighting.shadow.format,
		depth_bias       = 2.0,
		depth_bias_slope = 2.0,
	)

	// No geometry, no culling and no depth. Drawn first, so everything after it
	// covers it; see draw_skybox.
	/*
		The depth prepass (pipeline_forward.odin) -- the shadow pipelines'
		own shape, with the two differences that matter: the *main* depth
		format, since this writes into the pass's own depth buffer rather
		than a shadow map, and no bias at all, since its depth has to match
		bit for bit what the scene pass will write over it.
	*/
	mbi.renderer.pipelines.depth_prepass = create_pipeline(
		mbi.renderer.shaders.shadow,
		vertex       = mbi.renderer.shaders.mesh,
		layout       = .MESH,
		depth        = true,
		cull         = .BACK,
		color_target = false,
	)

	mbi.renderer.pipelines.depth_prepass_skinned = create_pipeline(
		mbi.renderer.shaders.shadow,
		vertex       = mbi.renderer.shaders.mesh_skinned,
		layout       = .SKINNED,
		depth        = true,
		cull         = .BACK,
		color_target = false,
	)

	mbi.renderer.pipelines.skybox_panorama = create_pipeline(
		mbi.renderer.shaders.skybox_panorama,
		vertex       = mbi.renderer.shaders.skybox,
		layout       = .NONE,
		depth        = false,
		cull         = .NONE,
		depth_ignore = true,
		color_format = mbi.renderer.lighting.targets.format,
	)

	mbi.renderer.pipelines.skybox_cubemap = create_pipeline(
		mbi.renderer.shaders.skybox_cubemap,
		vertex       = mbi.renderer.shaders.skybox,
		layout       = .NONE,
		depth        = false,
		cull         = .NONE,
		depth_ignore = true,
		color_format = mbi.renderer.lighting.targets.format,
	)

	// Lines are never culled -- an edge has no facing -- and they are biased
	// towards the camera. See `lines` in create_pipeline for why.
	mbi.renderer.pipelines.line = create_pipeline(
		mbi.renderer.shaders.mesh_line,
		vertex       = mbi.renderer.shaders.mesh,
		layout       = .MESH,
		depth        = true,
		cull         = .NONE,
		lines        = true,
		color_format = mbi.renderer.lighting.targets.format,
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
	/*
		Linear, clamped on all three axes -- the environment probe's own two
		maps and every pass of the bloom chain (bloom.odin) read through this
		one. There is no wrap-around to be had inside one probe face's own
		image, nor across the edge of the screen a bloom level is a shrunken
		copy of, the same reasoning `skybox_clamp_sampler` already gives for a
		cube map's own faces. See `Renderer.linear_clamp_sampler` for why one
		sampler serves both. Mip filtering is irrelevant: `probe_layer_uv`
		(lighting_core.hlsli) always reads mip 0 of whichever layer it
		picked, since roughness selects a *layer* here rather than a real mip
		level (ambient.odin's own top comment explains why) -- `min_lod`/
		`max_lod` are left at their zero-value default for exactly that
		reason, not tuned for a mip chain neither probe texture actually has.
	*/
	mbi.renderer.linear_clamp_sampler = sdl.CreateGPUSampler(mbi.renderer.device, {
		min_filter     = .LINEAR,
		mag_filter     = .LINEAR,
		address_mode_u = .CLAMP_TO_EDGE,
		address_mode_v = .CLAMP_TO_EDGE,
		address_mode_w = .CLAMP_TO_EDGE,
	})

	/*
		The shadow sampler compares rather than just filters -- SampleCmpLevelZero
		in lighting.hlsli reads compare_op/enable_compare, not the filter mode
		alone, to turn "how far is this texel" into "is this texel lit",
		filtered across neighbours for free rather than a hand-rolled PCF loop.
		Clamped on both axes: nothing outside the light's own frustum should
		wrap around and sample the opposite edge.

		One sampler still serves both maps -- the comparison settings are the
		shadow system's own choice, not a per-light one.

		The 1x1 placeholders (one per MAX_SHADOW_CASTERS slot) exist so
		mesh.frag.hlsl -- which declares both slots unconditionally, for every
		game -- always has something valid bound, whether or not a game ever
		turns shadows on via set_lighting or ever has two shadow-casting
		lights at once. Their contents are never actually read:
		shadow_visibility (lighting_core.hlsli) only samples a slot whose
		caster index push_lighting actually set, which it never does unless
		Shadow_Settings.enabled is true, and set_lighting (by way of
		apply_shadow_settings, shadow_standard.odin) is what replaces these
		placeholders the moment shadows are turned on.
	*/
	mbi.renderer.lighting.shadow.sampler = sdl.CreateGPUSampler(mbi.renderer.device, {
		min_filter     = .LINEAR,
		mag_filter     = .LINEAR,
		address_mode_u = .CLAMP_TO_EDGE,
		address_mode_v = .CLAMP_TO_EDGE,
		address_mode_w = .CLAMP_TO_EDGE,
		compare_op     = .LESS_OR_EQUAL,
		enable_compare = true,
	})

	shadow_placeholders_ok := true
	for slot in 0 ..< MAX_SHADOW_CASTERS {
		mbi.renderer.lighting.shadow.textures[slot] = sdl.CreateGPUTexture(mbi.renderer.device, {
			type                 = .D2,
			format               = mbi.renderer.lighting.shadow.format,
			usage                = {.DEPTH_STENCIL_TARGET, .SAMPLER},
			width                = 1,
			height               = 1,
			layer_count_or_depth = 1,
			num_levels           = 1,
		})
		shadow_placeholders_ok &= mbi.renderer.lighting.shadow.textures[slot] != nil
	}

	/*
		The same 1x1 placeholder shape, for CASCADED's and CUBE's own map
		groups -- `mesh.frag.hlsl` declares `cascade_maps`/`cube_maps`
		unconditionally (see that file's own comment), so both need something
		valid bound from the moment a device exists, whether or not this
		game's scene ever selects CASCADED or ever casts a cube shadow.
		Real maps replace these the same way `apply_cascade_shadow_textures`/
		`apply_cube_shadow_textures` (shadow_cascaded.odin, shadow_cube.odin)
		already replace the two just above, the first time their own
		technique is actually turned on.

		One `D2_ARRAY` texture apiece, not one `D2` texture per layer, since
		P3b -- see `shadow.odin`'s own doc comment on `Shadow_State` for why:
		`GPUDepthStencilTargetInfo.layer` targets one layer of a larger
		texture, so the layers a placeholder needs to cover are one texture
		with that many layers rather than that many separate textures.
	*/
	mbi.renderer.lighting.shadow.cascade_texture = sdl.CreateGPUTexture(mbi.renderer.device, {
		type                 = .D2_ARRAY,
		format               = mbi.renderer.lighting.shadow.format,
		usage                = {.DEPTH_STENCIL_TARGET, .SAMPLER},
		width                = 1,
		height               = 1,
		layer_count_or_depth = MAX_SHADOW_CASTERS * MAX_CASCADES,
		num_levels           = 1,
	})
	shadow_placeholders_ok &= mbi.renderer.lighting.shadow.cascade_texture != nil

	mbi.renderer.lighting.shadow.cube_texture = sdl.CreateGPUTexture(mbi.renderer.device, {
		type                 = .D2_ARRAY,
		format               = mbi.renderer.lighting.shadow.format,
		usage                = {.DEPTH_STENCIL_TARGET, .SAMPLER},
		width                = 1,
		height               = 1,
		layer_count_or_depth = MAX_POINT_SHADOW_CASTERS * 6,
		num_levels           = 1,
	})
	shadow_placeholders_ok &= mbi.renderer.lighting.shadow.cube_texture != nil

	mbi.renderer.lighting.shadow.resolution          = 1
	mbi.renderer.lighting.shadow.cascade_resolution  = 1
	mbi.renderer.lighting.shadow.cube_resolution     = 1
	mbi.renderer.lighting.shadow.caster_indices      = {-1, -1} // Odin's zero value is 0, a real slot -- -1 has to be said
	mbi.renderer.lighting.shadow.cube_caster_index   = {-1}

	/*
		1x1 white, sampled wherever a mesh part has no base colour, metallic-
		roughness, occlusion or emissive texture of its own -- see
		Renderer.default_texture's own doc comment (render.odin) and
		mesh.frag.hlsl. The same reasoning as the shadow placeholders just
		above: a slot mesh.frag.hlsl declares unconditionally must always have
		something valid bound, whether or not this particular part was ever
		textured on that channel.

		One texture standing in for all four rather than one per channel:
		every one of them is read as factor * texture, so the identity value
		a missing texture needs is 1.0 in every channel, for all four --
		see render3d.odin's own comment on this same reasoning for why that
		is also right for emissive, not just an accident of reusing what was
		already here for base colour.
	*/
	white_pixel := [4]u8{255, 255, 255, 255}
	default_texture_ok := false

	// SRGB, though it makes no numeric difference to any of the four slots
	// this stands in for -- white is 1.0 under either encoding, since sRGB's
	// transfer function fixes both endpoints. The reason to say SRGB anyway
	// is consistency: two of those slots (base colour, emissive) are SRGB
	// themselves, so this asks for the same format a textured part's own
	// colour channel would -- see Texture_Encoding.
	if texture, err := upload_texture(&white_pixel, 1, 1, .SRGB); err == nil {
		mbi.renderer.default_texture = texture
		default_texture_ok = true
	}

	/*
		1x1 black, six layers -- bound at both of the environment probe's own
		slots (`irradiance_map`/`prefiltered_map`, mesh.frag.hlsl) whenever
		`Renderer.lighting.probe` is empty. Six rather than one: `probe_layer_uv`
		picks a face (0..5) regardless of whether a real probe is bound, and a
		`Texture2DArray` sampled at a layer past its own count is exactly the
		undefined-read hazard `Vertex3D_Skinned`'s own doc comment already
		warns this package away from -- six matching layers of the same black
		pixel costs nothing and removes the question entirely. One texture
		serves both probe slots (see this proc's own doc comment on
		`Renderer.default_probe_texture`): with no real probe bound,
		`ambient_ground.w` is 0 (`push_lighting`, lighting.odin), so
		`pbr_environment_specular`'s own level math always lands on layer
		`0 * 6 + face`, inside this texture's six layers regardless.
	*/
	default_probe_texture_ok := false
	{
		black_pixel := [4]u8{0, 0, 0, 0}
		texture := sdl.CreateGPUTexture(mbi.renderer.device, {
			type                 = .D2_ARRAY,
			format               = .R8G8B8A8_UNORM,
			usage                = {.SAMPLER},
			width                = 1,
			height               = 1,
			layer_count_or_depth = 6,
			num_levels           = 1,
		})

		if texture != nil {
			ok := true
			for layer in 0 ..< 6 {
				if upload_texture_region(texture, &black_pixel, 1, 1, u32(layer)) != nil {
					ok = false
				}
			}

			if ok {
				mbi.renderer.default_probe_texture = texture
				default_probe_texture_ok = true
			} else {
				sdl.ReleaseGPUTexture(mbi.renderer.device, texture)
			}
		}
	}

	/*
		A 1-element Cluster_Range{0, 0} and a 1-element uint(0) -- bound
		whenever CLUSTERED is not the active pipeline, so mesh.frag.hlsl's own
		unconditional cluster_ranges/cluster_light_indices declarations
		(lighting_core.hlsli) always have something valid regardless. See
		Renderer.default_cluster_ranges_buffer's own doc comment (render.odin).
	*/
	cluster_placeholders_ok := false
	{
		zero_range: Cluster_Range
		zero_index: u32

		ranges_buffer,  ranges_err  := upload_buffer(&zero_range, size_of(Cluster_Range), {.GRAPHICS_STORAGE_READ})
		indices_buffer, indices_err := upload_buffer(&zero_index, size_of(u32), {.GRAPHICS_STORAGE_READ})

		if ranges_err == nil && indices_err == nil {
			mbi.renderer.default_cluster_ranges_buffer        = ranges_buffer
			mbi.renderer.default_cluster_light_indices_buffer = indices_buffer
			cluster_placeholders_ok = true
		} else {
			if ranges_err  == nil do sdl.ReleaseGPUBuffer(mbi.renderer.device, ranges_buffer)
			if indices_err == nil do sdl.ReleaseGPUBuffer(mbi.renderer.device, indices_buffer)
		}
	}

	ensure(mbi.renderer.sprite_sampler != nil && mbi.renderer.font_sampler != nil &&
		mbi.renderer.lighting.shadow.sampler != nil && shadow_placeholders_ok && default_texture_ok &&
		mbi.renderer.linear_clamp_sampler != nil && default_probe_texture_ok && cluster_placeholders_ok,
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

		/*
			Fatal, unlike everywhere else these errors are returned.

			`init` is the one caller with nobody to hand a failure to, and a
			program without the shared quad cannot draw anything at all -- every
			2D draw in Matchbox binds it. Carrying on would mean a window that
			opens and stays blank, which is a worse thing to debug than a
			message saying which allocation the driver refused.
		*/
		verts_err, indices_err: Error
		mbi.renderer.quad_verts,   verts_err   = upload_buffer(&verts,   size_of(verts),   {.VERTEX})
		mbi.renderer.quad_indices, indices_err = upload_buffer(&indices, size_of(indices), {.INDEX})

		if verts_err != nil || indices_err != nil {
			log.errorf("could not upload the shared quad: %v %v", verts_err, indices_err)
			panic("Cannot upload the quad every draw is built on")
		}
	}

	font, font_err := load_font(DEFAULT_FONT_BYTES, FONT_DEFAULTS.size)
	if font_err != nil {
		log.errorf("could not bake the default font: %v", font_err)
		panic("Cannot bake the built-in font")
	}
	mbi.font = font

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

	destroy_font_cache()
	destroy_font(&mbi.font)

	if mbi.renderer.quad_verts   != nil do sdl.ReleaseGPUBuffer(device, mbi.renderer.quad_verts)
	if mbi.renderer.quad_indices != nil do sdl.ReleaseGPUBuffer(device, mbi.renderer.quad_indices)

	if mbi.renderer.sprite_sampler != nil do sdl.ReleaseGPUSampler(device, mbi.renderer.sprite_sampler)
	if mbi.renderer.font_sampler   != nil do sdl.ReleaseGPUSampler(device, mbi.renderer.font_sampler)
	if mbi.renderer.lighting.shadow.sampler != nil do sdl.ReleaseGPUSampler(device, mbi.renderer.lighting.shadow.sampler)
	for texture in mbi.renderer.lighting.shadow.textures {
		if texture != nil do sdl.ReleaseGPUTexture(device, texture)
	}
	if mbi.renderer.lighting.shadow.cascade_texture != nil do sdl.ReleaseGPUTexture(device, mbi.renderer.lighting.shadow.cascade_texture)
	if mbi.renderer.lighting.shadow.cube_texture    != nil do sdl.ReleaseGPUTexture(device, mbi.renderer.lighting.shadow.cube_texture)
	if mbi.renderer.default_texture != nil do sdl.ReleaseGPUTexture(device, mbi.renderer.default_texture)
	if mbi.renderer.default_probe_texture != nil do sdl.ReleaseGPUTexture(device, mbi.renderer.default_probe_texture)
	if mbi.renderer.default_cluster_ranges_buffer        != nil do sdl.ReleaseGPUBuffer(device, mbi.renderer.default_cluster_ranges_buffer)
	if mbi.renderer.default_cluster_light_indices_buffer != nil do sdl.ReleaseGPUBuffer(device, mbi.renderer.default_cluster_light_indices_buffer)
	if mbi.renderer.linear_clamp_sampler != nil do sdl.ReleaseGPUSampler(device, mbi.renderer.linear_clamp_sampler)

	// A game's own probe, if one was ever loaded and set -- see
	// set_environment_probe (ambient.odin).
	destroy_environment_probe(&mbi.renderer.lighting.probe)

	if mbi.renderer.pipelines.sprite  != nil do sdl.ReleaseGPUGraphicsPipeline(device, mbi.renderer.pipelines.sprite)
	if mbi.renderer.pipelines.rect    != nil do sdl.ReleaseGPUGraphicsPipeline(device, mbi.renderer.pipelines.rect)
	if mbi.renderer.pipelines.outline != nil do sdl.ReleaseGPUGraphicsPipeline(device, mbi.renderer.pipelines.outline)
	if mbi.renderer.pipelines.font    != nil do sdl.ReleaseGPUGraphicsPipeline(device, mbi.renderer.pipelines.font)
	if mbi.renderer.pipelines.shape   != nil do sdl.ReleaseGPUGraphicsPipeline(device, mbi.renderer.pipelines.shape)
	if mbi.renderer.pipelines.mesh    != nil do sdl.ReleaseGPUGraphicsPipeline(device, mbi.renderer.pipelines.mesh)
	if mbi.renderer.pipelines.line    != nil do sdl.ReleaseGPUGraphicsPipeline(device, mbi.renderer.pipelines.line)
	if mbi.renderer.pipelines.mesh_skinned != nil do sdl.ReleaseGPUGraphicsPipeline(device, mbi.renderer.pipelines.mesh_skinned)
	if mbi.renderer.pipelines.gbuffer           != nil do sdl.ReleaseGPUGraphicsPipeline(device, mbi.renderer.pipelines.gbuffer)
	if mbi.renderer.pipelines.gbuffer_skinned   != nil do sdl.ReleaseGPUGraphicsPipeline(device, mbi.renderer.pipelines.gbuffer_skinned)
	if mbi.renderer.pipelines.deferred_lighting != nil do sdl.ReleaseGPUGraphicsPipeline(device, mbi.renderer.pipelines.deferred_lighting)
	if mbi.renderer.pipelines.shadow != nil do sdl.ReleaseGPUGraphicsPipeline(device, mbi.renderer.pipelines.shadow)
	if mbi.renderer.pipelines.shadow_skinned != nil do sdl.ReleaseGPUGraphicsPipeline(device, mbi.renderer.pipelines.shadow_skinned)
	if mbi.renderer.pipelines.skybox_panorama != nil do sdl.ReleaseGPUGraphicsPipeline(device, mbi.renderer.pipelines.skybox_panorama)
	if mbi.renderer.pipelines.skybox_cubemap != nil do sdl.ReleaseGPUGraphicsPipeline(device, mbi.renderer.pipelines.skybox_cubemap)
	if mbi.renderer.pipelines.post    != nil do sdl.ReleaseGPUGraphicsPipeline(device, mbi.renderer.pipelines.post)
	if mbi.renderer.pipelines.psx     != nil do sdl.ReleaseGPUGraphicsPipeline(device, mbi.renderer.pipelines.psx)
	if mbi.renderer.pipelines.vhs     != nil do sdl.ReleaseGPUGraphicsPipeline(device, mbi.renderer.pipelines.vhs)
	if mbi.renderer.pipelines.tonemap != nil do sdl.ReleaseGPUGraphicsPipeline(device, mbi.renderer.pipelines.tonemap)
	if mbi.renderer.pipelines.bloom_prefilter  != nil do sdl.ReleaseGPUGraphicsPipeline(device, mbi.renderer.pipelines.bloom_prefilter)
	if mbi.renderer.pipelines.bloom_downsample != nil do sdl.ReleaseGPUGraphicsPipeline(device, mbi.renderer.pipelines.bloom_downsample)
	if mbi.renderer.pipelines.bloom_upsample   != nil do sdl.ReleaseGPUGraphicsPipeline(device, mbi.renderer.pipelines.bloom_upsample)
	if mbi.renderer.pipelines.ssao      != nil do sdl.ReleaseGPUGraphicsPipeline(device, mbi.renderer.pipelines.ssao)
	if mbi.renderer.pipelines.ssao_blur != nil do sdl.ReleaseGPUGraphicsPipeline(device, mbi.renderer.pipelines.ssao_blur)
	if mbi.renderer.pipelines.volumetric != nil do sdl.ReleaseGPUGraphicsPipeline(device, mbi.renderer.pipelines.volumetric)
	if mbi.renderer.pipelines.depth_prepass         != nil do sdl.ReleaseGPUGraphicsPipeline(device, mbi.renderer.pipelines.depth_prepass)
	if mbi.renderer.pipelines.depth_prepass_skinned != nil do sdl.ReleaseGPUGraphicsPipeline(device, mbi.renderer.pipelines.depth_prepass_skinned)
	if mbi.renderer.pipelines.probe_irradiance != nil do sdl.ReleaseGPUGraphicsPipeline(device, mbi.renderer.pipelines.probe_irradiance)
	if mbi.renderer.pipelines.probe_prefilter  != nil do sdl.ReleaseGPUGraphicsPipeline(device, mbi.renderer.pipelines.probe_prefilter)

	if mbi.renderer.shaders.quad    != nil do sdl.ReleaseGPUShader(device, mbi.renderer.shaders.quad)
	if mbi.renderer.shaders.sprite  != nil do sdl.ReleaseGPUShader(device, mbi.renderer.shaders.sprite)
	if mbi.renderer.shaders.rect    != nil do sdl.ReleaseGPUShader(device, mbi.renderer.shaders.rect)
	if mbi.renderer.shaders.outline != nil do sdl.ReleaseGPUShader(device, mbi.renderer.shaders.outline)
	if mbi.renderer.shaders.font    != nil do sdl.ReleaseGPUShader(device, mbi.renderer.shaders.font)
	if mbi.renderer.shaders.shape   != nil do sdl.ReleaseGPUShader(device, mbi.renderer.shaders.shape)
	if mbi.renderer.shaders.mesh      != nil do sdl.ReleaseGPUShader(device, mbi.renderer.shaders.mesh)
	if mbi.renderer.shaders.mesh_frag != nil do sdl.ReleaseGPUShader(device, mbi.renderer.shaders.mesh_frag)
	if mbi.renderer.shaders.mesh_line != nil do sdl.ReleaseGPUShader(device, mbi.renderer.shaders.mesh_line)
	if mbi.renderer.shaders.mesh_skinned != nil do sdl.ReleaseGPUShader(device, mbi.renderer.shaders.mesh_skinned)
	if mbi.renderer.shaders.gbuffer_frag           != nil do sdl.ReleaseGPUShader(device, mbi.renderer.shaders.gbuffer_frag)
	if mbi.renderer.shaders.fullscreen             != nil do sdl.ReleaseGPUShader(device, mbi.renderer.shaders.fullscreen)
	if mbi.renderer.shaders.deferred_lighting_frag != nil do sdl.ReleaseGPUShader(device, mbi.renderer.shaders.deferred_lighting_frag)
	if mbi.renderer.shaders.shadow != nil do sdl.ReleaseGPUShader(device, mbi.renderer.shaders.shadow)
	if mbi.renderer.shaders.skybox != nil do sdl.ReleaseGPUShader(device, mbi.renderer.shaders.skybox)
	if mbi.renderer.shaders.skybox_panorama != nil do sdl.ReleaseGPUShader(device, mbi.renderer.shaders.skybox_panorama)
	if mbi.renderer.shaders.skybox_cubemap != nil do sdl.ReleaseGPUShader(device, mbi.renderer.shaders.skybox_cubemap)
	if mbi.renderer.shaders.post != nil do sdl.ReleaseGPUShader(device, mbi.renderer.shaders.post)
	if mbi.renderer.shaders.psx  != nil do sdl.ReleaseGPUShader(device, mbi.renderer.shaders.psx)
	if mbi.renderer.shaders.vhs  != nil do sdl.ReleaseGPUShader(device, mbi.renderer.shaders.vhs)
	if mbi.renderer.shaders.tonemap != nil do sdl.ReleaseGPUShader(device, mbi.renderer.shaders.tonemap)
	if mbi.renderer.shaders.bloom_prefilter  != nil do sdl.ReleaseGPUShader(device, mbi.renderer.shaders.bloom_prefilter)
	if mbi.renderer.shaders.bloom_downsample != nil do sdl.ReleaseGPUShader(device, mbi.renderer.shaders.bloom_downsample)
	if mbi.renderer.shaders.bloom_upsample   != nil do sdl.ReleaseGPUShader(device, mbi.renderer.shaders.bloom_upsample)
	if mbi.renderer.shaders.ssao      != nil do sdl.ReleaseGPUShader(device, mbi.renderer.shaders.ssao)
	if mbi.renderer.shaders.ssao_blur != nil do sdl.ReleaseGPUShader(device, mbi.renderer.shaders.ssao_blur)
	if mbi.renderer.shaders.volumetric != nil do sdl.ReleaseGPUShader(device, mbi.renderer.shaders.volumetric)
	if mbi.renderer.shaders.probe_irradiance != nil do sdl.ReleaseGPUShader(device, mbi.renderer.shaders.probe_irradiance)
	if mbi.renderer.shaders.probe_prefilter  != nil do sdl.ReleaseGPUShader(device, mbi.renderer.shaders.probe_prefilter)

	// The generated shapes, if anything ever asked for one.
	destroy_shapes3d()

	// Only ever made if the game asked for a 3D pass.
	if mbi.renderer.depth_texture != nil {
		sdl.ReleaseGPUTexture(device, mbi.renderer.depth_texture)
		mbi.renderer.depth_texture = nil
	}

	// The HDR scene target -- same "only ever made once 3D was asked for" as
	// the depth texture just above. See tonemap.odin.
	if mbi.renderer.lighting.targets.color != nil {
		sdl.ReleaseGPUTexture(device, mbi.renderer.lighting.targets.color)
		mbi.renderer.lighting.targets.color = nil
	}

	// The bloom chain's own levels -- only ever made once a game turns bloom
	// on. See bloom.odin.
	release_bloom_targets()

	// SSAO's own two, the same "only once a game turned it on". See ssao.odin.
	release_ssao_targets()

	// P7c's probe arrays and its capture cube -- only ever made once a game
	// captures a probe. See reflection.odin.
	release_reflection_targets()

	// DEFERRED's own targets -- only ever made once a game selects that
	// pipeline. See Gbuffer_Targets' own doc comment (gbuffer.odin).
	{
		g := &mbi.renderer.lighting.gbuffer
		if g.a     != nil do sdl.ReleaseGPUTexture(device, g.a)
		if g.b     != nil do sdl.ReleaseGPUTexture(device, g.b)
		if g.c     != nil do sdl.ReleaseGPUTexture(device, g.c)
		if g.d     != nil do sdl.ReleaseGPUTexture(device, g.d)
		if g.depth != nil do sdl.ReleaseGPUTexture(device, g.depth)
		g^ = {}
	}

	// Only ever made if a skinned model was drawn with no animator.
	if mbi.renderer.identity_joints != nil {
		sdl.ReleaseGPUBuffer(device, mbi.renderer.identity_joints)
		mbi.renderer.identity_joints = nil
	}

	// Only ever made once a game has called set_lights. See light.odin's
	// upload_light_buffer.
	if mbi.renderer.lighting.light_buffer   != nil do sdl.ReleaseGPUBuffer(device, mbi.renderer.lighting.light_buffer)
	if mbi.renderer.lighting.light_transfer != nil do sdl.ReleaseGPUTransferBuffer(device, mbi.renderer.lighting.light_transfer)
	delete(mbi.renderer.lighting.light_data)

	// CLUSTERED's own buffers, if this game ever selected that pipeline --
	// see light_cull.odin's own Cluster_State.
	c := &mbi.renderer.lighting.cluster
	if c.ranges_buffer          != nil do sdl.ReleaseGPUBuffer(device, c.ranges_buffer)
	if c.ranges_transfer        != nil do sdl.ReleaseGPUTransferBuffer(device, c.ranges_transfer)
	if c.light_indices_buffer   != nil do sdl.ReleaseGPUBuffer(device, c.light_indices_buffer)
	if c.light_indices_transfer != nil do sdl.ReleaseGPUTransferBuffer(device, c.light_indices_transfer)
	delete(c.ranges)
	delete(c.light_indices)

	delete(mbi.renderer.pending_shadow_models)
	delete(mbi.renderer.pending_deferred_forward_models)
	delete(mbi.renderer.pending_scene_models)

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
	data, read_err := read_entire_file(full, context.allocator)
	if read_err != nil {
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
