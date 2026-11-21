#+build freestanding arm32

package matchbox

/*
	Render -- 3DS
	======
	Handles the rendering

	Everything drawn is 3D; 2D is an orthographic camera. The 3D path
	is added in Phase C (see render_plan.md).
*/

import "o3dx/c3d"

render_start :: proc() {
	c3d.FrameBegin(c3d.FRAME_SYNCDRAW)
	c3d.FrameDrawOn(mbi.top_screen) // Will need to decide how to handle drawing on top or bottom
}

/*Renders final output -- Present all the gathered data this frame to the screen*/
render_end :: proc() {
	c3d.FrameEnd(0)
}

/*Packs a 0..1 RGBA colour into 0xRRGGBBAA*/
calculate_color_u32 :: proc(color:[4]f32) -> u32 {

	r := u32(color.r * 255 + 0.5)
	g := u32(color.g * 255 + 0.5)
	b := u32(color.b * 255 + 0.5)
	a := u32(color.a * 255 + 0.5)

	return r << 24 | g << 16 | b << 8 | a
}

clear_background :: proc(color:[4]f32) {
	cov_color := calculate_color_u32(color)
	c3d.RenderTargetClear(mbi.top_screen, c3d.CLEAR_ALL, cov_color, 0)
}
