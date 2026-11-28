package msaa_check

/*
	Does the real window smooth its edges? Run from the repository root: `odin run examples/msaa-check`. Draws a slanted 3D line to the window
	and to a render target, with and without multisampling, reads each picture back and prints how many pixels an edge only half
	covers: none when it is off, many when it is on. It quits by itself.
*/

import "core:fmt"

import mb "../../matchbox"

count_blended :: proc(pixels:[]u8) -> int {
	count := 0
	for index := 0; index < len(pixels); index += 4 {
		if pixels[index] != 0 && pixels[index] != 255 do count += 1
	}
	return count
}

draw_line :: proc(camera:mb.Camera) {
	mb.camera_start(camera)
	mb.render_line_3d({-3, 0, -1}, {3, 0.4, 2}, mb.WHITE)
	mb.camera_end()
}

main :: proc() {
	mb.init("msaa check", 640, 400)
	camera := mb.create_camera_3d({0, 6, 0.01}, {0, 0, 0}, 50)

	for samples in ([2]i32{1, 4}) {
		got := mb.set_window_samples(samples)
		target := mb.create_render_target({width = 256, height = 256, samples = samples})

		window_blended := 0
		for frame in 0 ..< 3 {
			mb.poll_events()
			mb.render_start()
			mb.render_target_start(&target, [4]f32{0, 0, 0, 1})
			draw_line(camera)
			mb.render_target_end()
			mb.clear_background({0, 0, 0, 1})
			draw_line(camera)
			if frame == 2 {
				pixels, _ := mb.read_window_pixels(context.temp_allocator)
				window_blended = count_blended(pixels)
			}
			mb.render_end()
		}
		target_blended := count_blended(mb.read_render_target_pixels(target, context.temp_allocator))
		fmt.printfln("asked %d, window got %d, target got %d: half-covered pixels in the window %d, in the target %d", samples, got, target.samples, window_blended, target_blended)
		mb.destroy_render_target(&target)
		free_all(context.temp_allocator)
	}
}
