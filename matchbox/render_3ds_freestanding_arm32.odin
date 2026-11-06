#+build freestanding arm32

package matchbox

/*
	Render
	======
	Handles the rendering
*/

import "o3dx/ctru"
import "o3dx/c3d"
import "o3dx/c2d"

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

/*Draws any queued triangles using Matchbox's own GPU state | WIP May need improvement based on performance*/
flush_triangles :: proc() {
	if mbi.vertex_count == 0 do return
	bind_triangle_state()
	ctru.memcpy(mbi.vbo_data, &mbi.vertices[0], uint(mbi.vertex_count) * size_of(Vertex))
	c3d.DrawArrays(.TRIANGLES, 0, i32(mbi.vertex_count))
	mbi.vertex_count = 0
}

/*Renders final output -- Present all the gathered data this frame to the screen*/
render_end :: proc() {
	flush_triangles()
	c3d.FrameEnd(0)
}

bind_triangle_state :: proc() {
	c3d.BindProgram(&mbi.prog)

	attr_info := c3d.GetAttrInfo()
	c3d.AttrInfo_Init(attr_info)
	c3d.AttrInfo_AddLoader(attr_info, 0, .FLOAT, 3) // v0 = position (xyz)
	c3d.AttrInfo_AddLoader(attr_info, 1, .FLOAT, 4) // v1 = colour   (rgba)

	buf_info := c3d.C3D_GetBufInfo()
	c3d.BufInfo_Init(buf_info)
	c3d.BufInfo_Add(buf_info, mbi.vbo_data, size_of(Vertex), 2, 0x10)

	env := c3d.C3D_GetTexEnv(0)
	c3d.TexEnvInit(env)
	c3d.TexEnvSrc(env, c3d.C3D_Both, .PRIMARY_COLOR, .PRIMARY_COLOR, .PRIMARY_COLOR)
	c3d.TexEnvFunc(env, c3d.C3D_Both, .REPLACE)

	c3d.DepthTest(false, .ALWAYS, .ALL)
	c3d.CullFace(.NONE)

	c3d.AlphaBlend(.ADD, .ADD, .SRC_ALPHA, .ONE_MINUS_SRC_ALPHA, .SRC_ALPHA, .ONE_MINUS_SRC_ALPHA)	

	c3d.FVUnifMtx4x4(.VERTEX_SHADER, mbi.uloc_proj, &mbi.projection)
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

	// c3d.FVUnifMtx4x4(.VERTEX_SHADER, mbi.uloc_proj, &mbi.projection)
	
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

render_sprite :: proc(sprite:Sprite, rotation_angle:f32 = 0, scale:f32 = 1, tint:[4]f32 = {1, 1, 1, 1}) {

	flush_triangles()
	c2d.Prepare() // I do not believe this is the best approach as each render is a new render pass instead of batch | Should be reworked
	c2d.SceneBegin(mbi.top_screen)
	
	sprite := sprite
	image := c2d.Image{&sprite.texture, &sprite.sub_texture}
	
	tint:c2d.ImageTint = {
		{{color_to_u32(tint), 0.0},
		{color_to_u32(tint), 0.0},
		{color_to_u32(tint), 0.0},
		{color_to_u32(tint), 0.0}}
	}	
	
	c2d.DrawImageAtRotated(
		img = image,
		x = sprite.x + cast(f32)sprite.width / 2,
		y = sprite.y + cast(f32)sprite.height / 2,
		depth = 0,
		angle = rotation_angle,
		tint = &tint,
		scaleX = scale,
		scaleY = scale,
	)

	c2d.Flush()
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
