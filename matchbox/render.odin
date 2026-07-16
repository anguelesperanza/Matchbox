package matchbox

import "gpu"
import sdl "vendor:sdl3"

// -----------------------------------------------------------------------
// Frame loop
// -----------------------------------------------------------------------

begin_render:: proc(matchbox_info: ^MatchboxInfo) {
	old_window_w := matchbox_info.window_width
	old_window_h := matchbox_info.window_height
	sdl.GetWindowSize(matchbox_info.window, &matchbox_info.window_width, &matchbox_info.window_height)

	if !matchbox_info.fixed_res {
		matchbox_info.width  = matchbox_info.window_width
		matchbox_info.height = matchbox_info.window_height
	}

	if matchbox_info.fixed_res {
		scale_x := f32(matchbox_info.window_width)  / f32(matchbox_info.width)
		scale_y := f32(matchbox_info.window_height) / f32(matchbox_info.height)
		matchbox_info.draw_scale = min(scale_x, scale_y)
		scaled_w := f32(matchbox_info.width)  * matchbox_info.draw_scale
		scaled_h := f32(matchbox_info.height) * matchbox_info.draw_scale
		matchbox_info.draw_offset = {
			(f32(matchbox_info.window_width)  - scaled_w) * 0.5,
			(f32(matchbox_info.window_height) - scaled_h) * 0.5,
		}
	} else {
		matchbox_info.draw_scale  = 1
		matchbox_info.draw_offset = {0, 0}
	}

	if .MINIMIZED in sdl.GetWindowFlags(matchbox_info.window) ||
	   matchbox_info.window_width <= 0 || matchbox_info.window_height <= 0 {
		sdl.Delay(16)
	}

	if matchbox_info.next_frame > 3 {
		gpu.semaphore_wait(matchbox_info.frame_sem, matchbox_info.next_frame - 3)
	}

	if old_window_w != matchbox_info.window_width || old_window_h != matchbox_info.window_height {
		gpu.swapchain_resize({u32(max(0, matchbox_info.window_width)), u32(max(0, matchbox_info.window_height))})
	}

	matchbox_info.swapchain = gpu.swapchain_acquire_next()

	matchbox_info.frame_arena = &matchbox_info.frame_arenas[matchbox_info.next_frame % 3]
	gpu.arena_free_all(matchbox_info.frame_arena)

	matchbox_info.frame_cmd = gpu.commands_begin(.Main)
}

end_render:: proc(matchbox_info: ^MatchboxInfo) {
	
	gpu.wait_idle()
		
	gpu.cmd_end_render_pass(matchbox_info.frame_cmd)
	gpu.cmd_add_signal_semaphore(matchbox_info.frame_cmd, matchbox_info.frame_sem, matchbox_info.next_frame)
	gpu.queue_submit(.Main, {matchbox_info.frame_cmd})
	gpu.swapchain_present(.Main, matchbox_info.frame_sem, matchbox_info.next_frame)
	matchbox_info.next_frame += 1
}

clear_background :: proc(matchbox_info: ^MatchboxInfo, color: [4]f32 = {0, 0, 0, 1}) {
	gpu.cmd_begin_render_pass(matchbox_info.frame_cmd, {
		color_attachments = {{texture = matchbox_info.swapchain, clear_color = color}},
	})
}


// -----------------------------------------------------------------------
// Basic Shapes
// -----------------------------------------------------------------------

draw_rect :: proc(matchbox_info: ^MatchboxInfo, rectangle: Rectangle) {
	gpu.cmd_set_desc_heap(matchbox_info.frame_cmd, matchbox_info.desc_pool)
	gpu.cmd_set_shaders(matchbox_info.frame_cmd, matchbox_info.vertex_shader, matchbox_info.rect_frag_shader)

	verts_data := gpu.arena_alloc(matchbox_info.frame_arena, VertData)
	verts_data.cpu^ = {
		verts    = matchbox_info.rect_verts.gpu.ptr,
		position = screen_pos(matchbox_info, rectangle.position),
		size     = screen_size(matchbox_info, rectangle.size),
		screen   = screen_dims(matchbox_info),
		rotation = rectangle.rotation,
		flip_x   = false,
		flip_y   = false,
	}

	frag_data := gpu.arena_alloc(matchbox_info.frame_arena, Rect_Frag_Data)
	frag_data.cpu.color = rectangle.color

	set_alpha_blend(matchbox_info.frame_cmd)
	gpu.cmd_draw_indexed(matchbox_info.frame_cmd, verts_data, frag_data, matchbox_info.rect_indices)
}
