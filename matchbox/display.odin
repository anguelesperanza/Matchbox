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
	window_width:  i32,      // real window size, in pixels -- not points, see begin_drawing
	window_height: i32,

	// Window pixels per window point. 1 on an unscaled display, 1.25 or 1.5 or 2
	// on a scaled one. The window is created with .HIGH_PIXEL_DENSITY, so its
	// pixel size is its point size times this -- and SDL reports mouse positions
	// in points, which is the one place the two have to be reconciled.
	pixel_density: f32,
	width:         i32,      // logical render size, what games draw against
	height:        i32,
	fixed_res:     bool,     // true = letterbox the logical size into the window
	draw_scale:    f32,      // logical -> window multiplier
	draw_offset:   [2]f32,   // letterbox margin, in window pixels
}

// -----------------------------------------------------------------------
// Logical resolution / screen helpers
// -----------------------------------------------------------------------

// Pins the resolution games draw against. From here on the logical image is
// scaled to fit the window and centered, so a resize letterboxes rather than
// changing how much of the world is on screen.
//
// Off by default -- without this, width/height follow the window size.
set_logical_size :: proc(width: i32, height: i32) {
    mbi.width     = width
    mbi.height    = height
    mbi.fixed_res = true
}

// A world position as the shader wants it, with the camera and the letterbox
// applied. What every 2D draw runs its position through.
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

// The camera zoom has to be applied here as well as in screen_pos. Every draw
// call pairs the two, so scaling only the position pulled things closer
// together while leaving them full size -- zoom out far enough and neighbours
// that are laid out apart start to overlap.
screen_size :: proc(size: [2]f32) -> [2]f32 {
	if mbi.camera.active {
		zoom: f32 = 1
		if mbi.camera.zoom > 0 {
			zoom = mbi.camera.zoom
		}
		return size * zoom * mbi.draw_scale
	}
	return size * mbi.draw_scale
}

// The size everything 2D is measured against this frame.
screen_dims :: proc() -> [2]f32 {
	// The render target when one is bound, so that 2D drawn into a texture of
	// a different size than the window lands inside it rather than off the
	// edge. The window otherwise, which is every frame that has no target.
	return current_target_size()
}
