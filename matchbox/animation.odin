package matchbox

import "gpu"

// -----------------------------------------------------------------------
// Animation
// -----------------------------------------------------------------------

AnimationClip :: struct {
	using mesh:        Mesh,
	cols:              i32,
	rows:              i32,
	frame_start:       i32,
	frame_count:       i32,
	seconds_per_frame: f32,
	frame_w:           f32,
	frame_h:           f32,
	offset:            [2]f32,
}

AnimatedSprite :: struct {
	using body:    Body,
	clip:          AnimationClip,
	current_frame: i32,
	accumulator:   f32,
}

create_animated_sprite :: proc(matchbox_info: ^MatchboxInfo, bytes: []byte, frame_w: f32, frame_h: f32, cols: i32, rows: i32, frame_count: i32, seconds_per_frame: f32, scale: f32 = 1) -> AnimatedSprite {
    sprite: AnimatedSprite
    sprite.clip  = load_animation(matchbox_info, bytes, frame_w, frame_h, cols, rows, frame_count, seconds_per_frame)
    sprite.scale = scale
    sprite.size  = {frame_w * scale, frame_h * scale}
    sprite.pivot = {0.5, 0.5}
    return sprite
}

load_animation :: proc(matchbox_info: ^MatchboxInfo, bytes: []byte, frame_w: f32, frame_h: f32, cols: i32, rows: i32, frame_count: i32, seconds_per_frame: f32) -> AnimationClip {
	return AnimationClip{
		mesh              = create_mesh(matchbox_info, bytes),
		cols              = cols,
		rows              = rows,
		frame_count       = frame_count,
		seconds_per_frame = seconds_per_frame,
		frame_w           = frame_w,
		frame_h           = frame_h,
	}
}

destroy_animation_clip :: proc(matchbox_info: ^MatchboxInfo, clip: ^AnimationClip) {
	destroy_mesh(&clip.mesh)
}

switch_animation :: proc(sprite: ^AnimatedSprite, clip: AnimationClip) {
    if sprite.clip.tex_id == clip.tex_id do return
    sprite.clip          = clip
    sprite.current_frame = 0
    sprite.accumulator   = 0
    sprite.size          = {clip.frame_w * sprite.scale, clip.frame_h * sprite.scale}
}

update_animation :: proc(sprite: ^AnimatedSprite, delta_time: f32) {
    sprite.accumulator += delta_time
    if sprite.accumulator >= sprite.clip.seconds_per_frame {
        sprite.accumulator  -= sprite.clip.seconds_per_frame
        sprite.current_frame = sprite.clip.frame_start + (sprite.current_frame - sprite.clip.frame_start + 1) % sprite.clip.frame_count
    }

    col := sprite.current_frame % sprite.clip.cols
    row := sprite.current_frame / sprite.clip.cols

    uv_left  := cast(f32)col       / cast(f32)sprite.clip.cols
    uv_right := cast(f32)(col + 1) / cast(f32)sprite.clip.cols
    uv_top   := cast(f32)row       / cast(f32)sprite.clip.rows
    uv_bot   := cast(f32)(row + 1) / cast(f32)sprite.clip.rows

    // Flip by swapping uv_min/uv_max within the frame's sub-range.
    // The fragment shader's flip_x does (1 - uv) in full [0,1] space which maps
    // atlas UVs to wrong frames, so the flip is handled here instead.
    if sprite.flip_x {
        sprite.uv_min.x = uv_right
        sprite.uv_max.x = uv_left
    } else {
        sprite.uv_min.x = uv_left
        sprite.uv_max.x = uv_right
    }
    if sprite.flip_y {
        sprite.uv_min.y = uv_bot
        sprite.uv_max.y = uv_top
    } else {
        sprite.uv_min.y = uv_top
        sprite.uv_max.y = uv_bot
    }
}


draw_animated_sprite :: proc(matchbox_info: ^MatchboxInfo, sprite: AnimatedSprite) {
	gpu.cmd_set_desc_heap(matchbox_info.frame_cmd, matchbox_info.desc_pool)
	gpu.cmd_set_shaders(matchbox_info.frame_cmd, matchbox_info.vertex_shader, matchbox_info.fragment_shader)

	draw_center := sprite.position + sprite.pivot * sprite.size + sprite.clip.offset

	verts_data := gpu.arena_alloc(matchbox_info.frame_arena, VertData)
	verts_data.cpu^ = {
		verts    = sprite.clip.verts_local.gpu.ptr,
		position = screen_pos(matchbox_info, draw_center),
		size     = screen_size(matchbox_info, sprite.size),
		screen   = screen_dims(matchbox_info),
		uv_min   = sprite.uv_min,
		uv_max   = sprite.uv_max,
		rotation = sprite.rotation,
		flip_x   = cast(b32)sprite.flip_x,
		flip_y   = cast(b32)sprite.flip_y,
	}

	frag_data := gpu.arena_alloc(matchbox_info.frame_arena, FragData)
	frag_data.cpu.texture_a = sprite.clip.tex_id
	frag_data.cpu.sampler   = sprite.clip.sampler_id
	frag_data.cpu.flip_x    = false
	frag_data.cpu.flip_y    = false

	set_alpha_blend(matchbox_info.frame_cmd)
	gpu.cmd_draw_indexed(matchbox_info.frame_cmd, verts_data, frag_data, sprite.clip.indices_local)
}
