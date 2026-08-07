package matchbox

/*
	Display
	-------
	The window and everything about mapping logical (game) coordinates onto it.

	Matchbox draws in a *logical* resolution (`width` x `height`). When
	`fixed_res` is on, that logical image is scaled up to fit the real window
	and centered, which is what `draw_scale` and `draw_offset` describe. Every
	draw call runs its coordinates through screen_pos/screen_size so games can
	work in logical space and ignore the actual window size.
*/

import sdl "vendor:sdl3"

Display :: struct {
	window:        ^sdl.Window,
	title:         string,
	flags:         sdl.WindowFlags,
	window_width:  i32,      // real window size, in pixels
	window_height: i32,
	width:         i32,      // logical render size, what games draw against
	height:        i32,
	fixed_res:     bool,     // true = letterbox the logical size into the window
	draw_scale:    f32,      // logical -> window multiplier
	draw_offset:   [2]f32,   // letterbox margin, in window pixels
}

// -----------------------------------------------------------------------
// Logical resolution / screen helpers
// -----------------------------------------------------------------------

set_logical_size :: proc(width: i32, height: i32) {
    mbi.width     = width
    mbi.height    = height
    mbi.fixed_res = true
}

screen_pos :: proc(pos: [2]f32) -> [2]f32 {
	if mbi.camera.active {
		screen_center := [2]f32{cast(f32)mbi.width * 0.5, cast(f32)mbi.height * 0.5}
		zoom: f32 = 1
		if mbi.camera.zoom > 0 {
			zoom = mbi.camera.zoom
		}
		logical := (pos - mbi.camera.position) * zoom + screen_center
		return logical * mbi.draw_scale + mbi.draw_offset
	}
	return pos * mbi.draw_scale + mbi.draw_offset
}

screen_size :: proc(size: [2]f32) -> [2]f32 {
	return size * mbi.draw_scale
}

screen_dims :: proc() -> [2]f32 {
	return {cast(f32)mbi.window_width, cast(f32)mbi.window_height}
}
