package matchbox


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

create_animated_sprite :: proc(bytes: []byte, frame_w: f32, frame_h: f32, cols: i32, rows: i32, frame_count: i32, seconds_per_frame: f32, scale: f32 = 1) -> AnimatedSprite {
    sprite: AnimatedSprite
    sprite.clip  = load_animation(bytes, frame_w, frame_h, cols, rows, frame_count, seconds_per_frame)
    sprite.scale = scale
    sprite.size  = {frame_w * scale, frame_h * scale}
    sprite.pivot = {0.5, 0.5}
    return sprite
}

load_animation :: proc(bytes: []byte, frame_w: f32, frame_h: f32, cols: i32, rows: i32, frame_count: i32, seconds_per_frame: f32) -> AnimationClip {
	return AnimationClip{
		mesh              = create_mesh(bytes),
		cols              = cols,
		rows              = rows,
		frame_count       = frame_count,
		seconds_per_frame = seconds_per_frame,
		frame_w           = frame_w,
		frame_h           = frame_h,
	}
}

destroy_animation_clip :: proc(clip: ^AnimationClip) {
	destroy_mesh(&clip.mesh)
}

switch_animation :: proc(sprite: ^AnimatedSprite, clip: AnimationClip) {
    // Same sheet means same clip: the texture handle identifies it now that
    // there are no descriptor-pool ids to compare.
    if sprite.clip.texture == clip.texture do return
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


draw_animated_sprite :: proc(sprite: AnimatedSprite) {
	draw_center := sprite.position + sprite.pivot * sprite.size + sprite.clip.offset

	vert_data := VertData{
		position = screen_pos(draw_center),
		size     = screen_size(sprite.size),
		screen   = screen_dims(),
		uv_min   = sprite.uv_min,
		uv_max   = sprite.uv_max,
		rotation = sprite.rotation,
	}

	// Flipping is already folded into uv_min/uv_max by the frame selection
	// above, so the shader is told not to do it a second time.
	frag_data := FragData{flip_x = false, flip_y = false}

	draw_quad(
		mbi.renderer.pipelines.sprite, &vert_data, &frag_data, size_of(frag_data),
		sprite.clip.texture, sprite.clip.sampler,
	)
}
