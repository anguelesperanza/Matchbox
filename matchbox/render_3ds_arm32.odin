package matchbox

/*
	Render
	======
	Handles the rendering
*/

import "o3dx/ctru"
import "o3dx/c3d"

// Constants
MAX_BATCH_VERTICES :: 4096 // Total number of vertices that can be drawn at once


Vertex :: struct {
	x, y, z: f32,
	r, g, b, a: f32,
}

render_start :: proc() {
	c3d.FrameBegin(c3d.FRAME_SYNCDRAW)

    c3d.FrameDrawOn(mbi.top_screen) // Will need to decide how to handle drawing on top or bottom
	
}

/*Renders final output -- Present all the gathered data this frame to the screen*/
render_end :: proc() {

	// Not sure if this is a good location to put the DrawArrays call
    // c3d.DrawArrays(.TRIANGLES, 0, 3)
    // c3d.FrameEnd(0)
	
	if mbi.vertex_count > 0 {
		ctru.memcpy(mbi.vbo_data, &mbi.vertices[0], uint(mbi.vertex_count) * size_of(Vertex))
		c3d.DrawArrays(.TRIANGLES, 0, i32(mbi.vertex_count))
		mbi.vertex_count = 0
	}
	c3d.FrameEnd(0)
}

/*Renders a triangle -- specifically adds vertex data to global array that will be rendered
a, b, c are the points that make up the triangle*/
render_triangle_points :: proc(a, b, c:[2]f32, color:[4]f32) {

	if mbi.vertex_count + 3 > MAX_BATCH_VERTICES do return // batch full: drop for now
	z :: 0.5
	mbi.vertices[mbi.vertex_count + 0] = {a.x, a.y, z, color.r, color.g, color.b, color.a}
	mbi.vertices[mbi.vertex_count + 1] = {b.x, b.y, z, color.r, color.g, color.b, color.a}
	mbi.vertices[mbi.vertex_count + 2] = {c.x, c.y, z, color.r, color.g, color.b, color.a}
	mbi.vertex_count += 3

	c3d.FVUnifMtx4x4(.VERTEX_SHADER, mbi.uloc_proj, &mbi.projection)
	
}


render_triangle_shape :: proc(triangle:Triangle) {
	// render_triangle_points(
	// 	a = triangle.position + triangle.points[0],
	// 	b = triangle.position + triangle.points[1],
	// 	c = triangle.position + triangle.points[2],
	// 	color = triangle.color,
	// )
}

/*Renders a triangle*/
render_triangle :: proc {
	render_triangle_points,
	// render_triangle_shape,
}



render_sprite :: proc(sprite:Sprite) {
	// TODO: Implement
}


color_to_u32 :: proc(color:[4]f32) -> u32 {
	
	r := u32(color.r * 255 + 0.5)
	g := u32(color.g * 255 + 0.5)
	b := u32(color.b * 255 + 0.5)
	a := u32(color.a * 255 + 0.5)
	
	return r << 24 | g << 16 | b << 8 | a 
}

clear_background :: proc(color:[4]f32) {

	
	cov_color := color_to_u32(color)

    c3d.RenderTargetClear(mbi.top_screen, c3d.CLEAR_ALL, cov_color, 0)
	
}
