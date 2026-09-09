package matchbox

import sdl "vendor:sdl3"

// The built-in shader set, compiled from matchbox/shaders and loaded by init.
//
// One vertex shader serves every draw: the old test.vert and font.vert had
// identical bodies and differed only in the field order of their uniform block.
Shaders :: struct {
	quad:    ^sdl.GPUShader,
	sprite:  ^sdl.GPUShader,
	rect:    ^sdl.GPUShader,
	outline: ^sdl.GPUShader,
	font:    ^sdl.GPUShader,
	shape:   ^sdl.GPUShader,

	// 3D. The first vertex shader that is not `quad`, because it is the first
	// thing that reads geometry instead of building it from a uniform block.
	mesh:      ^sdl.GPUShader,
	mesh_line: ^sdl.GPUShader,

	/*
		The one fragment shader every solid mesh pipeline shares now, textured
		or not -- see mesh.frag.hlsl's own doc comment. Before this rework
		there were two of these (`mesh_flat`/`mesh_textured`), differing only
		in whether they sampled a base-colour texture, which forced
		`lighting.hlsli`'s two shadow maps to sit at different register slots
		in each and `draw_model_immediate` to compute which. Binding a 1x1
		white default texture for an untextured part removes the need for a
		second shader entirely.
	*/
	mesh_frag: ^sdl.GPUShader,

	// mesh.vert with a skeleton in front of it. Shares every fragment shader
	// the unskinned one uses -- only the vertex stage differs.
	mesh_skinned: ^sdl.GPUShader,

	// The shadow pass's fragment shader -- writes nothing, paired with
	// mesh/mesh_skinned's own vertex shaders rather than one of its own. See
	// shadow.frag.hlsl.
	shadow: ^sdl.GPUShader,

	// The sky. One vertex shader making a triangle out of nothing, and a
	// fragment shader per source format.
	skybox:          ^sdl.GPUShader,
	skybox_panorama: ^sdl.GPUShader,
	skybox_cubemap:  ^sdl.GPUShader,

	// Post-processing. All three take the shared quad vertex shader.
	post: ^sdl.GPUShader,
	psx:  ^sdl.GPUShader,
	vhs:  ^sdl.GPUShader,
}

/*
	One pipeline per fragment shader.

	SDL3 has no dynamic shader or blend state -- the combination is baked into
	an object at creation. That is the whole reason this port exists: the
	previous backend got its dynamic state from VK_EXT_shader_object, which
	Intel's Vulkan driver does not provide at any driver version currently
	shipping, so an Arc B580 could not start the game at all.

	All of them share the one vertex shader and the same alpha blend.
*/
Pipelines :: struct {
	sprite:  ^sdl.GPUGraphicsPipeline,
	rect:    ^sdl.GPUGraphicsPipeline,
	outline: ^sdl.GPUGraphicsPipeline,
	font:    ^sdl.GPUGraphicsPipeline,
	shape:   ^sdl.GPUGraphicsPipeline, // ellipses and triangles, cut out in the fragment stage

	// The odd one out, and the reason create_pipeline takes arguments now: it
	// has its own vertex shader, a third vertex attribute, depth testing on,
	// back faces culled, and a depth-stencil target the others do not have.
	// Textured and untextured parts alike -- see `mesh_frag`'s own comment.
	mesh:    ^sdl.GPUGraphicsPipeline,

	// The same vertex shader and vertex layout as `mesh`, drawing line lists
	// instead of triangles and shading them flat. Wireframes, bounding boxes
	// and the ground grid.
	line:    ^sdl.GPUGraphicsPipeline,

	// `mesh` again, for parts a skeleton deforms. One rather than the two
	// this used to be (`mesh_skinned`/`mesh_skinned_textured`): both read
	// `mesh_frag` now, so the only thing that ever distinguished them --
	// whether a part carried a texture -- no longer picks a pipeline at all.
	mesh_skinned: ^sdl.GPUGraphicsPipeline,

	// Depth-only, biased, no colour target at all -- the shadow pass. Two for
	// the same reason mesh/mesh_skinned are two: a skinned caster needs the
	// skeleton's own vertex shader.
	shadow:         ^sdl.GPUGraphicsPipeline,
	shadow_skinned: ^sdl.GPUGraphicsPipeline,

	// Depth attached but neither tested nor written, so the sky is a background
	// rather than very distant geometry.
	skybox_panorama: ^sdl.GPUGraphicsPipeline,
	skybox_cubemap:  ^sdl.GPUGraphicsPipeline,

	// A render target drawn back over the window, with or without an effect on
	// the way. Colour-only and depthless, like every other 2D pipeline.
	post: ^sdl.GPUGraphicsPipeline,
	psx:  ^sdl.GPUGraphicsPipeline,
	vhs:  ^sdl.GPUGraphicsPipeline,
}

/*
	Everything lighting owns: the scene's own settings, the light list on both
	sides of the upload, and the shadow system's state -- grouped under one
	field on `Renderer` (`lighting` below) per CLAUDE.md's "group like data
	into structs" rather than left as loose fields the way `Lighting_Data` and
	`Shadow` used to be side by side. See `lighting_rework.md` section 4.
*/
Lighting :: struct {
	settings: Lighting_Settings, // lighting.odin -- set by set_lighting

	// The light list, CPU side and GPU side. `light_data` is packed and
	// ready to upload -- see `light_uniform` (light.odin) -- and
	// `light_buffer`/`light_transfer` are its device-side twin, grown on
	// demand and rewritten through the transfer buffer rather than
	// recreated every call, the same shape `Animation_Pose.joint_buffer`
	// already has for the joint palette. `light_capacity` is how many
	// elements `light_buffer` currently holds, which is not `len(light_data)`
	// once the list has shrunk from a previous, longer one.
	light_data:     [dynamic]Light_Uniform,
	light_buffer:   ^sdl.GPUBuffer,
	light_transfer: ^sdl.GPUTransferBuffer,
	light_capacity: int,

	shadow: Shadow_State, // shadow.odin / shadow_standard.odin
}

// GPU-side state. Internal plumbing -- games should not need to touch any of
// this, which is why Matchbox_Info keeps it behind `mbi.renderer` instead of
// promoting the fields.
Renderer :: struct {
	device:    ^sdl.GPUDevice,
	shaders:   Shaders,
	pipelines: Pipelines,

	cmd:          ^sdl.GPUCommandBuffer,
	pass:         ^sdl.GPURenderPass,
	swapchain:    ^sdl.GPUTexture,
	frame_active: bool, // false when the swapchain had nothing for us this frame

	// The unit quad, uploaded once. Every mesh used to carry its own identical
	// copy of these four vertices and six indices.
	quad_verts:   ^sdl.GPUBuffer,
	quad_indices: ^sdl.GPUBuffer,

	// Two samplers for the whole program: nearest for sprites, linear for the
	// font atlas. The old backend allocated these out of a descriptor pool with
	// room for 32, which put a ceiling of about two dozen sprites on a program.
	sprite_sampler: ^sdl.GPUSampler,

	/*
		1x1 white, sampled wherever a mesh part has no base colour texture of
		its own. This is what lets `mesh.frag.hlsl` be one shader for textured
		and untextured parts alike -- see that file's own doc comment and
		`lighting_rework.md` section 3.4. The same trick `init` already used
		for the shadow maps' own placeholders, applied to the other side of
		the same sampler slot.
	*/
	default_texture: ^sdl.GPUTexture,

	// Linear, and wrapping across the seam where a panorama's longitude comes
	// back round to itself. Clamped in v, so the poles do not bleed into each
	// other. The cube map wants clamping on both, because the hardware filters
	// across its own face seams and wrapping would fight it.
	skybox_wrap_sampler:  ^sdl.GPUSampler,
	skybox_clamp_sampler: ^sdl.GPUSampler,
	font_sampler:   ^sdl.GPUSampler,

	// Nested clip rectangles, in window pixels and already intersected. See
	// clip.odin.
	clip_stack: [MAX_CLIP_DEPTH]sdl.Rect,
	clip_depth: int,

	// What the current render pass already has bound. Binding is pass state, so
	// all of this is void the moment a pass ends and bind_cache_reset says so.
	//
	// Every draw used to re-bind the pipeline, the vertex buffer and the index
	// buffer, however many of them ran back to back with identical state. A
	// screen of two thousand rects is one pipeline and one quad, described two
	// thousand times.
	bound_pipeline:     ^sdl.GPUGraphicsPipeline,
	bound_texture:      ^sdl.GPUTexture,
	bound_sampler:      ^sdl.GPUSampler,
	bound_quad:         bool, // the shared vertex and index buffers, which never change
	bound_joint_buffer: ^sdl.GPUBuffer, // a skinned model's palette; see draw_model

	// The all-identity fallback for a skinned model drawn with no animator --
	// see draw_model. Grown, never shrunk, so the common case of drawing the
	// same handful of rigs pays for one allocation rather than one a draw.
	identity_joints:       ^sdl.GPUBuffer,
	identity_joints_count: int,

	// 3D. The depth texture is made the first time a game asks for a 3D pass
	// and remade when the window changes size, so a program that never draws
	// 3D never pays for one. See render3d.odin.
	depth_texture: ^sdl.GPUTexture,
	depth_format:  sdl.GPUTextureFormat, // .INVALID until the first one is made
	depth_width:   i32,
	depth_height:  i32,

	// Where drawing is going: nil is the window, anything else is a texture the
	// game is building. See render_target.odin.
	target: ^Render_Target,

	// Lighting settings, the light list and the shadow system -- see
	// `Lighting`'s own doc comment. The scene half of this (`lighting.settings`,
	// `lighting.light_data`) is set whenever a game calls `set_lighting` or
	// `set_lights`; the per-frame half (the camera-derived `Scene_Frag_Data`)
	// is worked out and pushed by `push_lighting`, called from
	// `begin_drawing_3d` rather than from either setter, so a game may call
	// them anywhere -- including before `begin_drawing`.
	lighting: Lighting,

	mode_3d:         bool, // true between begin_drawing_3d and end_drawing_3d
	view_projection: matrix[4, 4]f32,
	camera3d:        Camera3D,

	// Whether draw_model is currently filling a shadow map rather than
	// drawing the scene it will be sampled by. See shadow_standard.odin.
	in_shadow_pass: bool,

	// What draw_model_immediate has bound for the non-shadow-pass fragment
	// shader beyond the per-part base texture (`bound_texture`/`bound_sampler`
	// above): the two shadow maps and the light storage buffer, none of
	// which change per part or per pipeline switch the way the base texture
	// does, but which can change mid-pass if a game calls set_lighting or
	// set_lights (growing the light buffer) between draw_model calls.
	bound_shadow_maps:  [MAX_SHADOW_CASTERS]^sdl.GPUTexture,
	bound_light_buffer: ^sdl.GPUBuffer,

	// draw_model calls made with casts_shadow = true before begin_drawing_3d
	// has a pass of any kind open yet, held until it does. See draw_model's
	// own doc comment.
	pending_shadow_models: [dynamic]Pending_Shadow_Model,

	// The shapes draw_cube and friends draw, built the first time one is asked
	// for. Same reasoning as the depth texture: a game that draws no 3D should
	// not be carrying a sphere it never uses. See shapes3d.odin.
	unit_cube:       Model,
	unit_cube_wires: Model,
	unit_plane:      Model,
	unit_sphere:     Model,

	// draw_grid's one grid, rebuilt when the numbers it was asked for change.
	grid:         Model,
	grid_slices:  int,
	grid_spacing: f32,
}

// Called after every BeginGPURenderPass. A new pass starts with nothing bound,
// so a cache that outlived one would skip binds the GPU never received.
@(private)
bind_cache_reset :: proc() {
	r := &mbi.renderer
	r.bound_pipeline     = nil
	r.bound_texture      = nil
	r.bound_sampler      = nil
	r.bound_quad         = false
	r.bound_joint_buffer = nil
	r.bound_shadow_maps  = {}
	r.bound_light_buffer = nil
}

// -----------------------------------------------------------------------
// Frame loop
// -----------------------------------------------------------------------

/*
	Starts a frame: acquires a command buffer and the swapchain image.

	Everything drawn goes between this and `end_drawing`. A frame that cannot
	get a swapchain image -- a minimised window is the usual reason -- is
	skipped rather than failed, and every draw between the two quietly becomes
	a no-op.
*/
begin_drawing :: proc() {
	ensure(mbi.initialized, "matchbox.init must be called before begin_drawing")

	/*
		In pixels, not points.

		The window is created with .HIGH_PIXEL_DENSITY, which asks the platform for
		a backing surface at the display's real resolution -- so on a display at
		125% a 640x480 window has an 800x600 swapchain. This used to read
		GetWindowSize, which reports points, and window_width then disagreed with
		the thing being drawn into.

		Nothing looked broken, which is why it went unnoticed: get_screen_dims feeds
		this to the vertex shader as the divisor, so a full-width rect still
		reached the edge of the window. What was lost was the resolution that was
		asked for -- the whole frame was composed at point resolution and stretched
		over the pixels, so text baked at 32 was drawn across 40 and came out soft.
		For a nearest-filtered pixel image it is worse than soft: one source pixel
		lands on 1.25 screen pixels, and the seams fall in different places down
		the image.
	*/
	sdl.GetWindowSizeInPixels(mbi.window, &mbi.window_width, &mbi.window_height)

	if density := sdl.GetWindowPixelDensity(mbi.window); density > 0 {
		mbi.pixel_density = density
	}

	if !mbi.fixed_res {
		mbi.width  = mbi.window_width
		mbi.height = mbi.window_height
	}

	if mbi.fixed_res {
		scale_x := f32(mbi.window_width)  / f32(mbi.width)
		scale_y := f32(mbi.window_height) / f32(mbi.height)
		mbi.draw_scale = min(scale_x, scale_y)
		scaled_w := f32(mbi.width)  * mbi.draw_scale
		scaled_h := f32(mbi.height) * mbi.draw_scale
		mbi.draw_offset = {
			(f32(mbi.window_width)  - scaled_w) * 0.5,
			(f32(mbi.window_height) - scaled_h) * 0.5,
		}
	} else {
		mbi.draw_scale  = 1
		mbi.draw_offset = {0, 0}
	}

	if .MINIMIZED in sdl.GetWindowFlags(mbi.window) ||
	   mbi.window_width <= 0 || mbi.window_height <= 0 {
		sdl.Delay(16)
	}

	mbi.renderer.pass         = nil
	mbi.renderer.swapchain    = nil
	mbi.renderer.frame_active = false

	// A missing end_clip costs one frame rather than every frame after it.
	clip_reset()

	mbi.renderer.cmd = sdl.AcquireGPUCommandBuffer(mbi.renderer.device)
	if mbi.renderer.cmd == nil do return

	// Blocks until the swapchain has an image free, which is what paces the
	// frame. The old backend did this with a timeline semaphore and a manual
	// count of frames in flight, and then stalled the whole GPU on top of it.
	//
	// A minimized or zero-sized window legitimately hands back nothing. Every
	// draw checks frame_active so the frame quietly does nothing rather than
	// recording into a null pass.
	if !sdl.WaitAndAcquireGPUSwapchainTexture(
		mbi.renderer.cmd, mbi.window, &mbi.renderer.swapchain, nil, nil,
	) {
		return
	}
	if mbi.renderer.swapchain == nil do return

	mbi.renderer.frame_active = true

	// The swapchain is resized by SDL as the window changes, so the explicit
	// resize the old backend needed here is gone.
}

// Ends the frame and hands it to the GPU. Nothing appears on screen until this
// is called.
end_drawing :: proc() {
	r := &mbi.renderer
	if r.cmd == nil do return

	if r.pass != nil {
		sdl.EndGPURenderPass(r.pass)
		r.pass = nil
	}

	// Submitted even on a frame that drew nothing: a command buffer that has
	// been acquired has to be handed back one way or another.
	_ = sdl.SubmitGPUCommandBuffer(r.cmd)
	r.cmd          = nil
	r.frame_active = false
}

// Fills the frame with one colour. Call it just after `begin_drawing`: it
// starts a fresh render pass, so anything drawn before it is thrown away.
clear_background :: proc(color: [4]f32 = {0, 0, 0, 1}) {
	r := &mbi.renderer
	if !r.frame_active do return

	if r.pass != nil {
		sdl.EndGPURenderPass(r.pass)
		r.pass = nil
	}

	target := sdl.GPUColorTargetInfo{
		texture     = current_color_texture(),
		clear_color = {color[0], color[1], color[2], color[3]},
		load_op     = .CLEAR,
		store_op    = .STORE,
	}
	r.pass = sdl.BeginGPURenderPass(r.cmd, &target, 1, nil)
	bind_cache_reset()

	// A fresh pass starts with the scissor covering the whole target, so an
	// active clip has to be put back.
	apply_clip()
}

/*
	Opens a render pass if the frame does not have one yet.

	clear_background is the usual way a frame gets its pass, but drawing
	without clearing first is legal, and previously produced a crash rather
	than a picture. This one loads what is already in the swapchain instead of
	clearing it.
*/
@(private)
ensure_pass :: proc() {
	r := &mbi.renderer
	if !r.frame_active || r.pass != nil do return

	target := sdl.GPUColorTargetInfo{
		texture  = current_color_texture(),
		load_op  = .LOAD,
		store_op = .STORE,
	}
	r.pass = sdl.BeginGPURenderPass(r.cmd, &target, 1, nil)
	bind_cache_reset()

	apply_clip()
}

// -----------------------------------------------------------------------
// Basic Shapes
// -----------------------------------------------------------------------

// The middle of a rectangle, which is the point the vertex shader builds the
// quad around. Mirrors draw_sprite: `pivot` is the fraction of the size added
// to `position` to reach the centre.
rect_center :: proc(rectangle: Rectangle) -> [2]f32 {
	return rectangle.position + rectangle.pivot * rectangle.size
}

// The top-left corner. Hit tests and anything laying content out inside a
// rectangle want this, not `position` -- the two are only the same thing when
// the pivot is {0.5, 0.5}.
rect_top_left :: proc(rectangle: Rectangle) -> [2]f32 {
	return rect_center(rectangle) - rectangle.size * 0.5
}

/*
	Whether a point is inside a rectangle.

	Off rect_top_left rather than `position`, so it is right whatever the pivot
	is. The two only agree at pivot {0.5, 0.5}, and testing against `position`
	directly puts the hitbox half a size away from the thing you can see --
	which is a bug that hides until somebody uses a pivot that is not the
	default.

	This is the one hit test. is_mouse_over_rect, is_mouse_over_button,
	is_mouse_over_text_field and is_mouse_over_sprite all come through here.
*/
is_point_in_rect :: proc(point: [2]f32, rectangle: Rectangle) -> bool {
	top_left := rect_top_left(rectangle)
	size     := rectangle.size

	return point.x >= top_left.x && point.x <= top_left.x + size.x &&
	       point.y >= top_left.y && point.y <= top_left.y + size.y
}

// A filled rectangle, rotated about its own pivot. The 2D primitive most of
// `ui.odin` is built from.
draw_rect :: proc(rectangle: Rectangle) {
	ensure_pass()

	vert_data := Vert_Data{
		position = screen_pos(rect_center(rectangle)),
		size     = screen_size(rectangle.size),
		screen   = get_screen_dims(),
		uv_min   = {0, 0},
		uv_max   = {1, 1},
		rotation = rectangle.rotation,
	}

	frag_data := Rect_Frag_Data{color = rectangle.color}

	draw_quad(mbi.renderer.pipelines.rect, &vert_data, &frag_data, size_of(frag_data))
}
