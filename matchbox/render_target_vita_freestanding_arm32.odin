#+build freestanding arm32

package matchbox

/*
	Render targets (Vita)
	=====================
	A target is vito's `gfx.Target`: a linear 32-bit texture, a depth surface and a GXM render target, not
	multisampled. `gfx.begin_target` opens a scene on it and `gfx.end_frame` closes it. GXM cannot nest or
	interleave scenes, which is why every target is drawn before the screen's scene opens
	(render_vita_freestanding_arm32.odin: ensure_screen_scene).

	The target is on the heap, like a loaded texture, so every copy of its Texture names the same colour.
	Its rows are top first with no canvas and no flip, as a loaded image's are (the viewport flips y the same
	way for the screen and for a target).

	Matchbox's fragment programs are made for the screen, which is not multisampled either, so the same programs
	draw into a target (vito's note: a target's programs must be made with `target_multisample = .NONE`).
*/

import "vito/gfx"
import "vito/sce"

when VITA {

	@(private)
	allocate_render_target :: proc(target:^Render_Target, filter:Filter_Mode) {
		target.gfx_target = new(gfx.Target)
		ok:bool
		target.gfx_target^, ok = gfx.create_target(int(target.width), int(target.height))
		ensure(ok, "Out of video memory for a render target")
		target.texture.texture = &target.gfx_target.color
		// gfx.create_target makes a linear-filtered texture: the game's filter goes on top
		gxm_filter := calculate_gxm_filter(filter)
		sce.sceGxmTextureSetMinFilter(&target.gfx_target.color.texture, gxm_filter)
		sce.sceGxmTextureSetMagFilter(&target.gfx_target.color.texture, gxm_filter)
	}

	@(private)
	free_render_target :: proc(target:^Render_Target) {
		// The GPU may still be reading it for a frame it has not finished
		gfx.finish()
		gfx.destroy_target(target.gfx_target)
		free(target.gfx_target)
	}

	@(private)
	bind_render_target :: proc(target:^Render_Target, clear_color:Maybe([4]f32)) {
		ensure(mbi.screen_scene_open == false, "Draw every render target before the screen: the screen's scene is already open")
		gfx.begin_target(target.gfx_target)
		if color, ok := clear_color.?; ok do gfx.clear(color)
	}

	@(private)
	unbind_render_target :: proc(target:^Render_Target) {
		gfx.end_frame()
	}

	/*The target's picture as RGBA rows, top first, which the caller deletes. Waits for the GPU first*/
	read_render_target_pixels :: proc(target:Render_Target, allocator := context.allocator) -> []u8 {
		gfx.finish()
		texture := target.texture.texture
		pixels := make([]u8, target.width * target.height * 4, allocator)
		for y in 0 ..< int(target.height) {
			for x in 0 ..< int(target.width) {
				texel := texture.pixels[y * texture.stride + x] // 0xAABBGGRR
				to := (y * int(target.width) + x) * 4
				pixels[to + 0] = u8(texel)
				pixels[to + 1] = u8(texel >> 8)
				pixels[to + 2] = u8(texel >> 16)
				pixels[to + 3] = u8(texel >> 24)
			}
		}
		return pixels
	}
}
