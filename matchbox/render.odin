package matchbox

import "gpu"
import sdl "vendor:sdl3"

// The built-in shader set, compiled from matchbox/shaders and loaded by init.
Shaders :: struct {
	vertex:    gpu.Shader,
	fragment:  gpu.Shader,
	outline:   gpu.Shader,
	font_vert: gpu.Shader,
	font_frag: gpu.Shader,
	rect_frag: gpu.Shader,
}

// GPU-side state. Internal plumbing -- games should not need to touch any of
// this, which is why MatchboxInfo keeps it behind `mbi.renderer` instead of
// promoting the fields.
Renderer :: struct {
	shaders:      Shaders,
	desc_pool:    gpu.Descriptor_Pool,
	frame_cmd:    gpu.Command_Buffer,  // command buffer for the frame in flight
	frame_arenas: [3]gpu.Arena,        // one per frame in flight, cycled by next_frame
	frame_arena:  ^gpu.Arena,          // this frame's arena, points into frame_arenas
	frame_sem:    gpu.Semaphore,
	next_frame:   u64,
	swapchain:    gpu.Texture,
	rect_verts:   gpu.slice_t(Vertex), // shared unit quad, reused by every draw_rect
	rect_indices: gpu.slice_t(u32),
}

// -----------------------------------------------------------------------
// Frame loop
// -----------------------------------------------------------------------

begin_drawing :: proc() {
	ensure(mbi.initialized, "matchbox.init must be called before begin_drawing")

	old_window_w := mbi.window_width
	old_window_h := mbi.window_height
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

	if mbi.renderer.next_frame > 3 {
		gpu.semaphore_wait(mbi.renderer.frame_sem, mbi.renderer.next_frame - 3)
	}

	if old_window_w != mbi.window_width || old_window_h != mbi.window_height {
		gpu.swapchain_resize({u32(max(0, mbi.window_width)), u32(max(0, mbi.window_height))})
	}

	mbi.renderer.swapchain = gpu.swapchain_acquire_next()

	mbi.renderer.frame_arena = &mbi.renderer.frame_arenas[mbi.renderer.next_frame % 3]
	gpu.arena_free_all(mbi.renderer.frame_arena)

	mbi.renderer.frame_cmd = gpu.commands_begin(.Main)
}

end_drawing :: proc() {
	
	gpu.wait_idle()
		
	gpu.cmd_end_render_pass(mbi.renderer.frame_cmd)
	gpu.cmd_add_signal_semaphore(mbi.renderer.frame_cmd, mbi.renderer.frame_sem, mbi.renderer.next_frame)
	gpu.queue_submit(.Main, {mbi.renderer.frame_cmd})
	gpu.swapchain_present(.Main, mbi.renderer.frame_sem, mbi.renderer.next_frame)
	mbi.renderer.next_frame += 1
}

clear_background :: proc(color: [4]f32 = {0, 0, 0, 1}) {
	gpu.cmd_begin_render_pass(mbi.renderer.frame_cmd, {
		color_attachments = {{texture = mbi.renderer.swapchain, clear_color = color}},
	})
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
	gpu.cmd_set_desc_heap(mbi.renderer.frame_cmd, mbi.renderer.desc_pool)
	gpu.cmd_set_shaders(mbi.renderer.frame_cmd, mbi.renderer.shaders.vertex, mbi.renderer.shaders.rect_frag)

	verts_data := gpu.arena_alloc(mbi.renderer.frame_arena, VertData)
	verts_data.cpu^ = {
		verts    = mbi.renderer.rect_verts.gpu.ptr,
		position = screen_pos(rect_center(rectangle)),
		size     = screen_size(rectangle.size),
		screen   = screen_dims(),
		rotation = rectangle.rotation,
		flip_x   = false,
		flip_y   = false,
	}

	frag_data := gpu.arena_alloc(mbi.renderer.frame_arena, Rect_Frag_Data)
	frag_data.cpu.color = rectangle.color

	set_alpha_blend(mbi.renderer.frame_cmd)
	gpu.cmd_draw_indexed(mbi.renderer.frame_cmd, verts_data, frag_data, mbi.renderer.rect_indices)
}
