package matchbox

import "gpu"
import "core:strconv"
import "base:runtime"

import "base:intrinsics"

import stbtt "vendor:stb/truetype"

// -----------------------------------------------------------------------
// Font
// -----------------------------------------------------------------------

Font :: struct {
	using mesh:  Mesh,
	baked_chars: [96]stbtt.bakedchar,
	atlas_size:  i32,

	size:        f32, // pixel size the glyphs were baked at
	ascent:      f32, // baseline up to the tallest glyph
	descent:     f32, // baseline down to the lowest glyph
}

load_font :: proc(bytes: []byte, font_size: f32) -> Font {
	font: Font
	font.atlas_size = FONT_ATLAS_SIZE

	// Bake all printable ASCII glyphs into a grayscale bitmap
	bitmap := make([]u8, FONT_ATLAS_SIZE * FONT_ATLAS_SIZE)
	defer delete(bitmap)
	stbtt.BakeFontBitmap(raw_data(bytes), 0, font_size, raw_data(bitmap), FONT_ATLAS_SIZE, FONT_ATLAS_SIZE, 32, 96, raw_data(font.baked_chars[:]))

	// draw_text takes a baseline for its y, so anything positioning text against
	// the top of a box needs the ascent to shift by. Measured off the glyphs that
	// were actually baked -- yoff is the baseline-to-glyph-top offset, negative up.
	font.size = font_size
	for c in font.baked_chars {
		font.ascent  = max(font.ascent,  -c.yoff)
		font.descent = max(font.descent, c.yoff + (f32(c.y1) - f32(c.y0)))
	}

	// Expand grayscale to RGBA — white RGB, font mask as alpha
	rgba := make([]u8, FONT_ATLAS_SIZE * FONT_ATLAS_SIZE * 4)
	defer delete(rgba)
	for i in 0..<FONT_ATLAS_SIZE * FONT_ATLAS_SIZE {
		rgba[i*4 + 0] = 255
		rgba[i*4 + 1] = 255
		rgba[i*4 + 2] = 255
		rgba[i*4 + 3] = bitmap[i]
	}

	upload_arena := gpu.arena_create()
	defer gpu.arena_destroy(&upload_arena)

	staging := gpu.arena_alloc_raw(&upload_arena, cast(u64)len(rgba), 1)
	runtime.mem_copy(staging.cpu, raw_data(rgba), len(rgba))

	font.gpu_texture = gpu.texture_alloc_and_create({
		dimensions = {cast(u32)FONT_ATLAS_SIZE, cast(u32)FONT_ATLAS_SIZE, 1},
		format     = .RGBA8_Unorm,
		usage      = {.Sampled},
	})

	stage_verts := gpu.arena_alloc(&upload_arena, Vertex, 4)
	stage_verts.cpu[0] = {pos = {-0.5,  0.5, 0}, uv = {0, 1}}
	stage_verts.cpu[1] = {pos = { 0.5, -0.5, 0}, uv = {1, 0}}
	stage_verts.cpu[2] = {pos = { 0.5,  0.5, 0}, uv = {1, 1}}
	stage_verts.cpu[3] = {pos = {-0.5, -0.5, 0}, uv = {0, 0}}

	stage_indices := gpu.arena_alloc(&upload_arena, u32, 6)
	stage_indices.cpu[0] = 0; stage_indices.cpu[1] = 2; stage_indices.cpu[2] = 1
	stage_indices.cpu[3] = 0; stage_indices.cpu[4] = 1; stage_indices.cpu[5] = 3

	font.verts_local   = gpu.mem_alloc(Vertex, 4, gpu.Memory.GPU)
	font.indices_local = gpu.mem_alloc(u32, 6, gpu.Memory.GPU)

	cmd := gpu.commands_begin(.Main)
	gpu.cmd_copy_to_texture(cmd, font.gpu_texture, staging)
	gpu.cmd_mem_copy(cmd, font.verts_local, stage_verts)
	gpu.cmd_mem_copy(cmd, font.indices_local, stage_indices)
	gpu.cmd_barrier(cmd, .Transfer, .All, {})
	gpu.queue_submit(.Main, {cmd})
	gpu.queue_wait_idle(.Main)

	font.tex_id     = gpu.desc_pool_alloc_texture(&mbi.renderer.desc_pool, gpu.texture_view_descriptor(font.gpu_texture, {}))
	font.sampler_id = gpu.desc_pool_alloc_sampler(&mbi.renderer.desc_pool, gpu.sampler_descriptor({min_filter = .Linear, mag_filter = .Linear}))

	return font
}

destroy_font :: proc(font: ^Font) {
	destroy_mesh(&font.mesh)
}

draw_text_i64 :: proc(font: ^Font, integer: i64, x: f32, y: f32, color: [4]f32) {
    buf: [256]u8
    result := strconv.write_int(buf[:], integer, 10)
    draw_text_string(font, result[:], x, y, color)
}


draw_text_float :: proc(font: ^Font, float: $T, x: f32, y: f32, color: [4]f32) where intrinsics.type_is_float(T) {
    buf: [256]u8
    result := strconv.write_float(buf[:], cast(f64)float, 'f', 2, 64)
    draw_text_string(font, result[1:], x, y, color)
}


draw_text_string :: proc(font: ^Font, text: string, x: f32, y: f32, color: [4]f32) {
	gpu.cmd_set_desc_heap(mbi.renderer.frame_cmd, mbi.renderer.desc_pool)
	gpu.cmd_set_shaders(mbi.renderer.frame_cmd, mbi.renderer.shaders.font_vert, mbi.renderer.shaders.font_frag)
	set_alpha_blend(mbi.renderer.frame_cmd)

	cursor_x := x
	cursor_y := y

	for ch in text {
		if ch < 32 || ch >= 128 {
			continue
		}

		q: stbtt.aligned_quad
		stbtt.GetBakedQuad(raw_data(font.baked_chars[:]), font.atlas_size, font.atlas_size, cast(i32)ch - 32, &cursor_x, &cursor_y, &q, true)

		pos  := [2]f32{(q.x0 + q.x1) * 0.5, (q.y0 + q.y1) * 0.5}
		size := [2]f32{q.x1 - q.x0, q.y1 - q.y0}

		verts_data := gpu.arena_alloc(mbi.renderer.frame_arena, FontVertData)
		verts_data.cpu^ = {
			verts    = font.verts_local.gpu.ptr,
			position = screen_pos(pos),
			size     = screen_size(size),
			screen   = screen_dims(),
			rotation = 0,
			flip_x   = false,
			flip_y   = false,
			uv_min   = {q.s0, q.t0},
			uv_max   = {q.s1, q.t1},
		}

		frag_data := gpu.arena_alloc(mbi.renderer.frame_arena, FontFragData)
		frag_data.cpu^ = {
			texture_a = font.tex_id,
			sampler   = font.sampler_id,
			color     = color,
		}

		gpu.cmd_draw_indexed(mbi.renderer.frame_cmd, verts_data, frag_data, font.indices_local)
	}
}

draw_text :: proc {
	draw_text_string,
	draw_text_i64,
	draw_text_float
}

// How much room `text` takes up when drawn with draw_text.
//
// The height is the font's ascent plus descent rather than the extent of these
// particular glyphs, so "Play" and "Play Card" measure the same height and a
// line of text does not shift about vertically as its content changes.
measure_text :: proc(font: ^Font, text: string) -> [2]f32 {
	width: f32
	for ch in text {
		if ch < 32 || ch >= 128 {
			continue
		}
		width += font.baked_chars[cast(int)ch - 32].xadvance
	}
	return {width, font.ascent + font.descent}
}

// Screen-space text — coordinates and glyph size are in actual window pixels,
// draw_scale is NOT applied.  Use this for HUD / UI text when set_logical_size
// is active, so the font renders at its native baked size instead of being
// upscaled by the logical-resolution multiplier.
draw_text_ui_string :: proc(font: ^Font, text: string, x: f32, y: f32, color: [4]f32) {
	gpu.cmd_set_desc_heap(mbi.renderer.frame_cmd, mbi.renderer.desc_pool)
	gpu.cmd_set_shaders(mbi.renderer.frame_cmd, mbi.renderer.shaders.font_vert, mbi.renderer.shaders.font_frag)
	set_alpha_blend(mbi.renderer.frame_cmd)

	cursor_x := x
	cursor_y := y

	for ch in text {
		if ch < 32 || ch >= 128 {
			continue
		}

		q: stbtt.aligned_quad
		stbtt.GetBakedQuad(raw_data(font.baked_chars[:]), font.atlas_size, font.atlas_size, cast(i32)ch - 32, &cursor_x, &cursor_y, &q, true)

		pos  := [2]f32{(q.x0 + q.x1) * 0.5, (q.y0 + q.y1) * 0.5}
		size := [2]f32{q.x1 - q.x0, q.y1 - q.y0}

		verts_data := gpu.arena_alloc(mbi.renderer.frame_arena, FontVertData)
		verts_data.cpu^ = {
			verts    = font.verts_local.gpu.ptr,
			position = pos,
			size     = size,
			screen   = screen_dims(),
			rotation = 0,
			flip_x   = false,
			flip_y   = false,
			uv_min   = {q.s0, q.t0},
			uv_max   = {q.s1, q.t1},
		}

		frag_data := gpu.arena_alloc(mbi.renderer.frame_arena, FontFragData)
		frag_data.cpu^ = {
			texture_a = font.tex_id,
			sampler   = font.sampler_id,
			color     = color,
		}

		gpu.cmd_draw_indexed(mbi.renderer.frame_cmd, verts_data, frag_data, font.indices_local)
	}
}

draw_text_ui_int :: proc(font: ^Font, integer: i64, x: f32, y: f32, color: [4]f32) {
    buf: [256]u8
    result := strconv.write_int(buf[:], integer, 10)
    draw_text_ui_string(font, result[:], x, y, color)
}

draw_text_ui_f32 :: proc(font: ^Font, float: f32, x: f32, y: f32, color: [4]f32) {
    buf: [256]u8
    result := strconv.write_float(buf[:], cast(f64)float, 'f', 2, 64)
    draw_text_ui_string(font, result[1:], x, y, color)
}

draw_text_ui :: proc {
    draw_text_ui_string,
    draw_text_ui_int,
    draw_text_ui_f32,
}
