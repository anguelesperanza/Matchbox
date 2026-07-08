package matchbox

/*
	Render
	------
	Contains information related to rendering
*/

import "gpu"
import sdl "vendor:sdl3"

// Add time here
begin_render :: proc(matchbox_info:^MatchboxInfo, color: [4]f32 = BLACK) {

	old_window_width:i32 = matchbox_info.window_width
	old_window_height:i32 = matchbox_info.window_height
	
	sdl.GetWindowSize(matchbox_info.window, &matchbox_info.window_width, &matchbox_info.window_height)

	if .MINIMIZED in sdl.GetWindowFlags(matchbox_info.window) ||
	   matchbox_info.window_width <= 0 || matchbox_info.window_height <= 0 {
		sdl.Delay(16)
	}
	
    if matchbox_info.next_frame > len(matchbox_info.frame_arenas){
        gpu.semaphore_wait(matchbox_info.frame_semaphore, matchbox_info.next_frame - len(matchbox_info.frame_arenas))
    }

    if old_window_width != matchbox_info.window_width || old_window_height != matchbox_info.window_height {
        gpu.swapchain_resize({ u32(max(0, matchbox_info.window_width)), u32(max(0, matchbox_info.window_height)) })
    }


	swapchain := gpu.swapchain_acquire_next()

    last_ts := matchbox_info.now_ts
    matchbox_info.now_ts = sdl.GetPerformanceCounter()
    delta_time := min(matchbox_info.max_delta_time, f32(f64((matchbox_info.now_ts - last_ts)*1000) / f64(matchbox_info.ts_freq)) / 1000.0)

    matchbox_info.frame_arena = &matchbox_info.frame_arenas[matchbox_info.next_frame % len(matchbox_info.frame_arenas)]
    gpu.arena_free_all(matchbox_info.frame_arena)


	matchbox_info.frame_command = gpu.commands_begin(.Main)
	
	gpu.cmd_begin_render_pass(matchbox_info.frame_command, {
		color_attachments = {
			{texture = swapchain, clear_color = color}
		}
	})
}

end_render :: proc(matchbox_info:^MatchboxInfo) {
    gpu.cmd_end_render_pass(matchbox_info.frame_command)
    gpu.cmd_add_signal_semaphore(matchbox_info.frame_command, matchbox_info.frame_semaphore, matchbox_info.next_frame)

    gpu.queue_submit(.Main, { matchbox_info.frame_command })
    gpu.swapchain_present(.Main, matchbox_info.frame_semaphore, matchbox_info.next_frame)

    matchbox_info.next_frame += 1
}


render_shape :: proc(matchbox_info:^MatchboxInfo, shape:Shape) {

	if shape.shape == 2 {
		gpu.cmd_set_shaders(matchbox_info.frame_command, matchbox_info.circle_vertex_shader, matchbox_info.circle_frag_shader)
	} else {
		
		gpu.cmd_set_shaders(matchbox_info.frame_command, matchbox_info.shape_vertex_shader, matchbox_info.shape_frag_shader)
	}
	
	verts_data := gpu.arena_alloc(matchbox_info.frame_arena, VertData)
	verts_data.cpu^ = {
		verts = shape.verts_local.gpu.ptr,
	}
	gpu.cmd_draw_indexed(matchbox_info.frame_command, verts_data, {}, shape.indices_local)
}

// Make procedure group for different render shape procs
// render_triangle :: proc(matchbox_info:^MatchboxInfo, triangle:Triangle) {

// 	gpu.cmd_set_shaders(matchbox_info.frame_command, matchbox_info.triangle_vertex_shader, matchbox_info.triangle_frag_shader)
// 	verts_data := gpu.arena_alloc(matchbox_info.frame_arena, VertData)
// 	verts_data.cpu^ = {
// 		verts = triangle.verts_local.gpu.ptr,
// 	}
// 	gpu.cmd_draw_indexed(matchbox_info.frame_command, verts_data, {}, triangle.indices_local)
// }

// render_rectangle :: proc(matchbox_info:^MatchboxInfo, rectangle:Rectangle) {

// 	gpu.cmd_set_shaders(matchbox_info.frame_command, matchbox_info.rectangle_vertex_shader, matchbox_info.rectangle_frag_shader)
// 	verts_data := gpu.arena_alloc(matchbox_info.frame_arena, VertData)
// 	verts_data.cpu^ = {
// 		verts = rectangle.verts_local.gpu.ptr,
// 	}
// 	gpu.cmd_draw_indexed(matchbox_info.frame_command, verts_data, {}, rectangle.indices_local)
// }

// render_circle :: proc(matchbox_info:^MatchboxInfo, circle:Circle) {

// 	gpu.cmd_set_shaders(matchbox_info.frame_command, matchbox_info.circle_vertex_shader, matchbox_info.circle_frag_shader)
// 	verts_data := gpu.arena_alloc(matchbox_info.frame_arena, VertData)
// 	verts_data.cpu^ = {
// 		verts = circle.verts_local.gpu.ptr,
// 	}
// 	gpu.cmd_draw_indexed(matchbox_info.frame_command, verts_data, {}, circle.indices_local)
// }

// render_shape :: proc {
// 	render_triangle,
// 	render_rectangle,
// 	render_circle,
// }

