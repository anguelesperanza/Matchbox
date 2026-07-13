package matchbox

import "gpu"
import "core:math"
import "core:image"
import "core:image/png" // unused directly but needed to register the PNG decoder

import "base:runtime"

// -----------------------------------------------------------------------
// Sprites
// -----------------------------------------------------------------------

Sprite :: struct {
	using mesh: Mesh,
	using body: Body,
	parallax_speed: f32,
}

create_mesh :: proc(matchbox_info: ^MatchboxInfo, bytes: []byte) -> Mesh {
	options := image.Options{.alpha_add_if_missing}
	img, err := image.load_from_bytes(bytes, options)
	ensure(err == nil, "Could not load texture")
	defer image.destroy(img)

	upload_arena := gpu.arena_create()
	defer gpu.arena_destroy(&upload_arena)

	staging := gpu.arena_alloc_raw(&upload_arena, cast(u64)len(img.pixels.buf), 1)
	runtime.mem_copy(staging.cpu, raw_data(img.pixels.buf), len(img.pixels.buf))

	gpu_texture := gpu.texture_alloc_and_create({
		dimensions = {cast(u32)img.width, cast(u32)img.height, 1},
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

	verts_local   := gpu.mem_alloc(Vertex, 4, gpu.Memory.GPU)
	indices_local := gpu.mem_alloc(u32, 6, gpu.Memory.GPU)

	cmd := gpu.commands_begin(.Main)
	gpu.cmd_copy_to_texture(cmd, gpu_texture, staging)
	gpu.cmd_mem_copy(cmd, verts_local, stage_verts)
	gpu.cmd_mem_copy(cmd, indices_local, stage_indices)
	gpu.cmd_barrier(cmd, .Transfer, .All, {})
	gpu.queue_submit(.Main, {cmd})
	gpu.queue_wait_idle(.Main)

	return Mesh{
		gpu_texture   = gpu_texture,
		verts_local   = verts_local,
		indices_local = indices_local,
		tex_id        = gpu.desc_pool_alloc_texture(&matchbox_info.desc_pool, gpu.texture_view_descriptor(gpu_texture, {})),
		sampler_id    = gpu.desc_pool_alloc_sampler(&matchbox_info.desc_pool, gpu.sampler_descriptor({min_filter = .Nearest, mag_filter = .Nearest})),
	}
}

create_sprite :: proc(matchbox_info: ^MatchboxInfo, bytes: []byte, scale: f32 = 1) -> Sprite {
	mesh := create_mesh(matchbox_info, bytes)

	final_scale := scale
	if scale <= 0 {
		final_scale = 1
	}

	width  := cast(f32)mesh.gpu_texture.dimensions[0] * final_scale
	height := cast(f32)mesh.gpu_texture.dimensions[1] * final_scale

	return Sprite{
		mesh = mesh,
		body = Body{
			position = {0, 0},
			size     = {width, height},
			scale    = final_scale,
			pivot    = {0.5, 0.5},
			uv_min   = {0, 0},
			uv_max   = {1, 1},
		},
	}
}

destroy_mesh :: proc(mesh: ^Mesh) {
	gpu.mem_free(mesh.verts_local)
	gpu.mem_free(mesh.indices_local)
	gpu.texture_free_and_destroy(&mesh.gpu_texture)
}

destroy_sprite :: proc(matchbox_info: ^MatchboxInfo, sprite: ^Sprite) {
	destroy_mesh(&sprite.mesh)
}

sprite_center :: proc(sprite: Sprite) -> [2]f32 {
	return {
		sprite.position.x + sprite.size.x / 2,
		sprite.position.y + sprite.size.y / 2,
	}
}

destroy_parallax :: proc(matchbox_info: ^MatchboxInfo, parallax_sprites: ^ParallaxSprites) {
	for &i in parallax_sprites.sprites {
		destroy_sprite(matchbox_info, &i)
	}
}

draw_sprite :: proc(matchbox_info: ^MatchboxInfo, sprite: Sprite) {
	gpu.cmd_set_desc_heap(matchbox_info.frame_cmd, matchbox_info.desc_pool)
	gpu.cmd_set_shaders(matchbox_info.frame_cmd, matchbox_info.vertex_shader, matchbox_info.fragment_shader)

	draw_center := sprite.position + sprite.pivot * sprite.size

	verts_data := gpu.arena_alloc(matchbox_info.frame_arena, VertData)
	verts_data.cpu^ = {
		verts    = sprite.verts_local.gpu.ptr,
		position = screen_pos(matchbox_info, draw_center),
		size     = screen_size(matchbox_info, sprite.size),
		screen   = screen_dims(matchbox_info),
		rotation = sprite.rotation,
		flip_x   = cast(b32)sprite.flip_x,
		flip_y   = cast(b32)sprite.flip_y,
		uv_min   = sprite.uv_min,
		uv_max   = sprite.uv_max,
	}

	frag_data := gpu.arena_alloc(matchbox_info.frame_arena, FragData)
	frag_data.cpu.texture_a = sprite.tex_id
	frag_data.cpu.sampler   = sprite.sampler_id
	frag_data.cpu.flip_x    = cast(b32)sprite.flip_x
	frag_data.cpu.flip_y    = cast(b32)sprite.flip_y

	set_alpha_blend(matchbox_info.frame_cmd)
	gpu.cmd_draw_indexed(matchbox_info.frame_cmd, verts_data, frag_data, sprite.indices_local)
}

sprite_bounds :: proc(body: ^Body) -> [4]f32 {
	p := body.bounding_box_padding
	return {
		body.position.x + p[0],
		body.position.y + p[1],
		body.position.x + body.size.x - p[2],
		body.position.y + body.size.y - p[3],
	}
}

set_alpha_blend :: proc(cmd: gpu.Command_Buffer) {
	gpu.cmd_set_blend_state(cmd, {
		enable           = true,
		color_op         = .Add,
		src_color_factor = .Src_Alpha,
		dst_color_factor = .One_Minus_Src_Alpha,
		alpha_op         = .Add,
		src_alpha_factor = .One,
		dst_alpha_factor = .Zero,
		color_write_mask = {.R, .G, .B, .A},
	})
}

draw_outline :: proc(matchbox_info: ^MatchboxInfo, center: [2]f32, size: [2]f32, color: [4]f32, border: f32, rotation: f32) {
	gpu.cmd_set_desc_heap(matchbox_info.frame_cmd, matchbox_info.desc_pool)
	gpu.cmd_set_shaders(matchbox_info.frame_cmd, matchbox_info.vertex_shader, matchbox_info.outline_shader)

	verts_data := gpu.arena_alloc(matchbox_info.frame_arena, VertData)
	verts_data.cpu^ = {
		verts    = matchbox_info.rect_verts.gpu.ptr,
		position = screen_pos(matchbox_info, center),
		size     = screen_size(matchbox_info, size),
		screen   = screen_dims(matchbox_info),
		uv_min   = {0, 0},
		uv_max   = {1, 1},
		rotation = rotation,
		flip_x = false,
		flip_y = false,
	}

	frag_data := gpu.arena_alloc(matchbox_info.frame_arena, OutlineFragData)
	frag_data.cpu^ = {
		color  = color,
		border = border,
		flip_x = false,
		flip_y = false,
	}

	set_alpha_blend(matchbox_info.frame_cmd)
	gpu.cmd_draw_indexed(matchbox_info.frame_cmd, verts_data, frag_data, matchbox_info.rect_indices)
}

draw_bounding_box_outline :: proc(matchbox_info: ^MatchboxInfo, body: ^Body, color: [4]f32, border: f32) {
	bb     := sprite_bounds(body)
	center := [2]f32{(bb[0] + bb[2]) * 0.5, (bb[1] + bb[3]) * 0.5}
	size   := [2]f32{bb[2] - bb[0], bb[3] - bb[1]}

	draw_outline(matchbox_info, center, size, color, border, body.rotation)
}

draw_rect_outline :: proc(matchbox_info: ^MatchboxInfo, body: ^Body, color: [4]f32, border: f32) {
	center := body.position + body.pivot * body.size
	draw_outline(matchbox_info, center, body.size, color, border, body.rotation)
}


sprite_world_collision :: proc(mbi: MatchboxInfo, sprite: Sprite) -> [2]f32 {
	pos   := sprite.position
	scale := f32(1)
	if mbi.draw_scale > 0 {
		scale = mbi.draw_scale
	}
	left   := -mbi.draw_offset[0] / scale
	right  := (cast(f32)mbi.window_width  - mbi.draw_offset[0]) / scale
	top    := -mbi.draw_offset[1] / scale
	bottom := (cast(f32)mbi.window_height - mbi.draw_offset[1]) / scale
	pos.x   = clamp(pos.x, left, right  - sprite.size[0])
	pos.y   = clamp(pos.y, top,  bottom - sprite.size[1])
	return pos
}

bounding_box_collision_check :: proc(a: [4]f32, b: [4]f32) -> bool {
	return a[0] < b[2] &&
	       a[2] > b[0] &&
	       a[1] < b[3] &&
	       a[3] > b[1]
}
bounding_box_contact_check :: proc(a: [4]f32, b: [4]f32) -> bool {
    return a[0] < b[2] &&
           a[2] > b[0] &&
           a[1] < b[3] &&
           a[3] >= b[1]
}
// Returns the forward direction vector of a sprite based on its current rotation.
// Useful for movement in the direction a sprite is facing (e.g. tanks).
sprite_forward_by_rotation :: proc(sprite: Sprite) -> [2]f32 {
	s, c := math.sincos(sprite.rotation)
	return [2]f32{s, -c}
}


// Selects a single tile from a sprite sheet by its column and row (0-indexed).
// Also corrects sprite.size to one tile so the bounding box is right.
sprite_set_frame :: proc(sprite: ^Sprite, col, row, sheet_cols, sheet_rows: int, tile_w, tile_h: f32) {
    sprite.size  = {tile_w * sprite.scale, tile_h * sprite.scale}
    sprite.uv_min = {f32(col)   / f32(sheet_cols), f32(row)   / f32(sheet_rows)}
    sprite.uv_max = {f32(col+1) / f32(sheet_cols), f32(row+1) / f32(sheet_rows)}
}
