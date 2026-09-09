package matchbox

/*
	Render targets and post-processing
	----------------------------------
	Drawing into a texture instead of the window, and then drawing that texture
	back with a shader over it.

	This is what an effect is. There is no way to run a filter over a finished
	frame while it is being built -- the pixels underneath a draw are not
	readable from inside it -- so the scene goes into a texture first, and then
	one full-screen quad reads that texture and writes the window.

	**The target is created in the swapchain's format on purpose.** SDL3 bakes
	target formats into a pipeline, so a target in some other format would need
	its own copy of every pipeline that draws into it. Matching the swapchain
	means every pipeline that already exists stays valid inside a target's pass,
	including all the 2D ones -- a game can draw a sprite or a line of text into
	a render target on the way past.

	**No flip.** raylib's `DrawTexturePro` needs a negative source height to put
	a render texture the right way up, because an OpenGL framebuffer is stored
	bottom-up. SDL3_GPU is top-down like the swapchain, so what was rendered is
	what is sampled.
*/

import "core:log"

import sdl "vendor:sdl3"

/*
	A texture the GPU draws into, with its own depth buffer.

	The depth is the target's own rather than the screen's, since the two can be
	different sizes and a depth buffer has to match the colour buffer it is
	attached to.

	It does **not** resize itself with the window. A game that wants that
	destroys and recreates it on a resize -- which is also what the raylib
	version of PsxGame does, and for most games with an effect on top the point
	is a fixed resolution anyway.
*/
Render_Target :: struct {
	texture: ^sdl.GPUTexture,
	depth:   ^sdl.GPUTexture,
	width:   i32,
	height:  i32,
}

/*
	Makes a render target `width` by `height`, or the size of the window when
	either is left at zero.

	The caller owns it: `destroy` when finished.

	This used to log and hand back a zeroed struct, which was the worst of the
	three ways this package reported failure: nothing stopped, nothing was
	returned to check, and the mistake surfaced later as an unrelated-looking
	"render target was never created" from `begin_drawing_target` -- a
	complaint about the wrong thing, in the wrong place, a frame or more after
	the cause.
*/
create_render_target :: proc(width: i32 = 0, height: i32 = 0) -> (Render_Target, Error) {
	r := &mbi.renderer

	w := width  if width  > 0 else mbi.window_width
	h := height if height > 0 else mbi.window_height

	if w <= 0 || h <= 0 do return {}, Argument_Error.Empty_Size

	target: Render_Target
	target.width  = w
	target.height = h

	// SAMPLER as well as COLOR_TARGET: the whole point is to read it back.
	target.texture = sdl.CreateGPUTexture(r.device, {
		type                 = .D2,
		format               = sdl.GetGPUSwapchainTextureFormat(r.device, mbi.window),
		usage                = {.COLOR_TARGET, .SAMPLER},
		width                = u32(w),
		height               = u32(h),
		layer_count_or_depth = 1,
		num_levels           = 1,
	})

	if target.texture == nil {
		log.errorf("could not create a render target: %s", sdl.GetError())
		return {}, Gpu_Error.Texture_Creation_Failed
	}

	if r.depth_format == .INVALID do r.depth_format = pick_depth_format()

	// SAMPLER as well, for the same reason the window's own depth texture
	// carries it since P7b -- 3D drawn into a target still runs SSAO and
	// volumetrics, and both read this frame's depth back. See
	// ensure_depth_texture (render3d.odin).
	target.depth = sdl.CreateGPUTexture(r.device, {
		type                 = .D2,
		format               = r.depth_format,
		usage                = {.DEPTH_STENCIL_TARGET, .SAMPLER},
		width                = u32(w),
		height               = u32(h),
		layer_count_or_depth = 1,
		num_levels           = 1,
	})

	if target.depth == nil {
		log.errorf("could not create a render target's depth: %s", sdl.GetError())
		sdl.ReleaseGPUTexture(r.device, target.texture)
		return {}, Gpu_Error.Texture_Creation_Failed
	}

	return target, nil
}

// Releases the target's colour and depth textures. Not to be called while it
// is bound -- end the target's drawing first.
destroy_render_target :: proc(target: ^Render_Target) {
	device := mbi.renderer.device
	if device == nil do return

	if target.texture != nil do sdl.ReleaseGPUTexture(device, target.texture)
	if target.depth   != nil do sdl.ReleaseGPUTexture(device, target.depth)

	target^ = {}
}

// -----------------------------------------------------------------------
// Drawing into one
// -----------------------------------------------------------------------

/*
	Sends everything drawn from here until `end_drawing_target` into `target`
	rather than the window.

	Everything works inside as it does outside: `clear_background`,
	`begin_drawing_3d`, sprites, text. What changes is where the pixels land and
	what `get_screen_dims` reports, so a 2D layout laid out as a fraction of the
	screen fills the target instead.

	Nested targets are not supported -- one at a time, and `end_drawing_target`
	goes back to the window.
*/
begin_drawing_target :: proc(target: ^Render_Target) {
	r := &mbi.renderer
	if !r.frame_active do return

	ensure(r.target == nil, "render targets do not nest")
	ensure(target.texture != nil, "render target was never created")

	// Whatever pass is open belongs to the old destination.
	if r.pass != nil {
		sdl.EndGPURenderPass(r.pass)
		r.pass = nil
	}
	r.mode_3d = false

	r.target = target
}

// Back to the window. The target's texture is complete and can be drawn.
end_drawing_target :: proc() {
	r := &mbi.renderer
	if r.target == nil do return

	if r.pass != nil {
		sdl.EndGPURenderPass(r.pass)
		r.pass = nil
	}

	r.mode_3d = false
	r.target  = nil
}

// What a pass should attach, which is the target's when one is bound and the
// window's otherwise. The three of these are why the rest of the renderer needs
// no knowledge of render targets at all.
@(private)
current_color_texture :: proc() -> ^sdl.GPUTexture {
	r := &mbi.renderer
	return r.target.texture if r.target != nil else r.swapchain
}

@(private)
current_depth_texture :: proc() -> ^sdl.GPUTexture {
	r := &mbi.renderer
	if r.target != nil do return r.target.depth

	if !ensure_depth_texture() do return nil
	return r.depth_texture
}

@(private)
get_current_target_size :: proc() -> [2]f32 {
	r := &mbi.renderer

	if r.target != nil do return {f32(r.target.width), f32(r.target.height)}
	return {f32(mbi.window_width), f32(mbi.window_height)}
}

// -----------------------------------------------------------------------
// Post-processing
// -----------------------------------------------------------------------

/*
	The effects Matchbox ships.

	They are shaders compiled into the framework rather than something a game
	supplies. A game that wants a look not in this list asks
	for it to be added; everything goes through `create_pipeline`, so the door
	is open, but a general shader API is not what this is.
*/
Post_Effect :: enum {
	NONE, // the target drawn as it is, which is still a pass and still useful
	PSX,  // coarse pixels, ordered dither, 15-bit colour, scanlines
	VHS,  // tape wobble, chroma smear, tracking band, grain
}

/*
	Draws a render target over the whole window, through `effect`.

	One quad. The vertex shader every 2D draw already uses can put a rectangle
	anywhere at any size, so a full-screen pass is that rectangle at the size of
	the window -- which is why an effect costs a fragment shader and nothing
	else.

	`grid` is the PSX effect's coarse pixel size and is ignored by the others.
	320x240 is a PlayStation; larger is a cleaner picture.

	Call it after `end_drawing_target`, with the window as the destination.
*/
draw_post :: proc(target: Render_Target, effect: Post_Effect = .NONE, grid: [2]f32 = {320, 240}) {
	r := &mbi.renderer
	if !r.frame_active || target.texture == nil do return

	ensure(r.target == nil, "draw_post draws a target, so it cannot be called inside one")

	pipeline: ^sdl.GPUGraphicsPipeline
	sampler:  ^sdl.GPUSampler

	switch effect {
	case .PSX:
		// Nearest, so that snapping a uv to the middle of a coarse cell picks
		// one texel rather than a blend of four. Smoothing here would undo the
		// entire effect.
		pipeline, sampler = r.pipelines.psx, r.sprite_sampler
	case .VHS:
		// Linear, because this one samples at arbitrary offsets -- the barrel
		// curve, the chroma taps, the ghost -- and nearest makes all of them
		// stair-step.
		pipeline, sampler = r.pipelines.vhs, r.font_sampler
	case .NONE:
		fallthrough
	case:
		pipeline, sampler = r.pipelines.post, r.font_sampler
	}

	if !bind_quad_state(pipeline, target.texture, sampler) do return

	size := get_current_target_size()

	// Window pixels, not logical ones: this is the finished frame going to the
	// screen, so `set_logical_size`'s letterbox has already been accounted for
	// by whatever drew into the target.
	vert_data := Vert_Data{
		position = size * 0.5,
		size     = size,
		screen   = size,
		uv_min   = {0, 0},
		uv_max   = {1, 1},
	}

	frag_data := Post_Frag_Data{
		resolution = {f32(target.width), f32(target.height)},
		grid       = grid,
		time       = f32(get_time()),
	}

	push_quad(&vert_data, &frag_data, size_of(frag_data))
}
