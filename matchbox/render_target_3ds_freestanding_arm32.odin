#+build freestanding arm32

package matchbox

/*
	Render targets (3DS)
	====================
	A target is a texture in VRAM that citro3d draws into (`C3D_RenderTargetCreateFromTex`). Drawing to it is
	a `C3D_FrameDrawOn` inside the one frame, so there is no second frame begin.

	**The texture is a power-of-two canvas (8 to 1024 a side) like every 3DS texture, and the picture is the
	viewport's rectangle in its corner.** The size the game asked for is `width` x `height`; the GPU sees the
	canvas. The viewport covers the picture only, so nothing is drawn in the padding.

	**The picture lies in the canvas the way a loaded image does** (first row on top), found by reading a drawn
	scene back in Azahar: a first guess that the GPU wrote it bottom-up came out upside down. So every sprite,
	model and mesh path reads a target through calculate_canvas_uv_rectangle unchanged.
*/

import "o3dx/c3d"

when !VITA {

	@(private)
	allocate_render_target :: proc(target:^Render_Target, filter:Filter_Mode) {
		canvas := calculate_texture_canvas_size(target.width, target.height)
		ensure(canvas.x <= 1024 && canvas.y <= 1024, "The 3DS takes render targets up to 1024 pixels a side")

		target.texture.texture = new(c3d.C3D_Tex)
		ensure(c3d.C3D_TexInitVRAM(target.texture.texture, u16(canvas.x), u16(canvas.y), .RGBA8), "Out of VRAM for a render target")

		depth_type := c3d.DEPTHTYPE_DEPTH24_STENCIL8 if target.has_depth else c3d.C3D_DEPTHTYPE_NO_DEPTH
		target.citro_target = c3d.C3D_RenderTargetCreateFromTex(target.texture.texture, .TEXFACE_2D, 0, depth_type)
		ensure(target.citro_target != nil, "Out of VRAM for a render target's depth buffer")

		set_texture_sampling(&target.texture, filter)
	}

	@(private)
	free_render_target :: proc(target:^Render_Target) {
		if target.citro_target != nil do c3d.C3D_RenderTargetDelete(target.citro_target)
		destroy_texture(target.texture)
	}

	/*
		Points the frame at the target, puts the viewport on the picture in the canvas's corner, and clears unless
		`clear_color` is nil.

		**The viewport's y is the canvas's height minus the picture's, not 0.** The GPU counts y up from the bottom
		of the buffer but stores the buffer top row first, so a viewport at y 0 puts the picture in the LAST rows
		of the canvas and the padding in the first ones. Sampling (calculate_canvas_uv_rectangle) and the readback
		both expect the picture in the first rows, like a loaded image. A canvas with no padding (16 x 16, 64 x 64)
		hides the mistake, because there both placements are the same; a 267 x 161 picture in a 512 x 256 canvas shows
		the padding's clear colour over the top 37% of the screen. Found by sampling a 20 x 12 picture
		(render-target-check)
	*/
	@(private)
	bind_render_target :: proc(target:^Render_Target, clear_color:Maybe([4]f32)) {
		canvas := calculate_texture_canvas_size(target.width, target.height)
		c3d.C3D_FrameDrawOn(target.citro_target)
		c3d.C3D_SetViewport(0, u32(canvas.y - target.height), u32(target.width), u32(target.height))
		if color, ok := clear_color.?; ok {
			c3d.C3D_RenderTargetClear(target.citro_target, c3d.C3D_CLEAR_ALL, calculate_color_u32(color), 0)
		}
	}

	@(private)
	unbind_render_target :: proc(target:^Render_Target) {
		c3d.C3D_FrameDrawOn(mbi.top_screen)
	}

	/*
		The target's picture as RGBA rows, top first, which the caller deletes. Read from VRAM, so call it after the
		frame that drew it has finished (the next render_start waits for that)
	*/
	read_render_target_pixels :: proc(target:Render_Target, allocator := context.allocator) -> []u8 {
		canvas := calculate_texture_canvas_size(target.width, target.height)
		source := ([^]u8)(c3d.C3D_Tex2DGetImagePtr(target.texture.texture))
		pixels := make([]u8, target.width * target.height * 4, allocator)
		for y in 0 ..< target.height {
			row := y
			for x in 0 ..< target.width {
				from := calculate_texel_offset(x, row, canvas.x)
				to := (y * target.width + x) * 4
				pixels[to + 0] = source[from + 3]
				pixels[to + 1] = source[from + 2]
				pixels[to + 2] = source[from + 1]
				pixels[to + 3] = source[from + 0]
			}
		}
		return pixels
	}
}
