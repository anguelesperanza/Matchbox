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
}

/*
	One pipeline per fragment shader.

	SDL3 has no dynamic shader or blend state -- the combination is baked into
	an object at creation. That is the whole reason this port exists: the
	previous backend got its dynamic state from VK_EXT_shader_object, which
	Intel's Vulkan driver does not provide at any driver version currently
	shipping, so an Arc B580 could not start the game at all.

	All four share the one vertex shader and the same alpha blend.
*/
Pipelines :: struct {
	sprite:  ^sdl.GPUGraphicsPipeline,
	rect:    ^sdl.GPUGraphicsPipeline,
	outline: ^sdl.GPUGraphicsPipeline,
	font:    ^sdl.GPUGraphicsPipeline,
}

// GPU-side state. Internal plumbing -- games should not need to touch any of
// this, which is why MatchboxInfo keeps it behind `mbi.renderer` instead of
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
	font_sampler:   ^sdl.GPUSampler,
}

// -----------------------------------------------------------------------
// Frame loop
// -----------------------------------------------------------------------

begin_drawing :: proc() {
	ensure(mbi.initialized, "matchbox.init must be called before begin_drawing")

	sdl.GetWindowSize(mbi.window, &mbi.window_width, &mbi.window_height)

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

clear_background :: proc(color: [4]f32 = {0, 0, 0, 1}) {
	r := &mbi.renderer
	if !r.frame_active do return

	if r.pass != nil {
		sdl.EndGPURenderPass(r.pass)
		r.pass = nil
	}

	target := sdl.GPUColorTargetInfo{
		texture     = r.swapchain,
		clear_color = {color[0], color[1], color[2], color[3]},
		load_op     = .CLEAR,
		store_op    = .STORE,
	}
	r.pass = sdl.BeginGPURenderPass(r.cmd, &target, 1, nil)
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
		texture  = r.swapchain,
		load_op  = .LOAD,
		store_op = .STORE,
	}
	r.pass = sdl.BeginGPURenderPass(r.cmd, &target, 1, nil)
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

draw_rect :: proc(rectangle: Rectangle) {
	ensure_pass()

	vert_data := VertData{
		position = screen_pos(rect_center(rectangle)),
		size     = screen_size(rectangle.size),
		screen   = screen_dims(),
		uv_min   = {0, 0},
		uv_max   = {1, 1},
		rotation = rectangle.rotation,
	}

	frag_data := Rect_Frag_Data{color = rectangle.color}

	draw_quad(mbi.renderer.pipelines.rect, &vert_data, &frag_data, size_of(frag_data))
}
