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

/*
	A sprite that plays frames off a sheet, in one call.

	The sheet is a grid: `cols` by `rows` frames of `frame_w` by `frame_h`, read
	left to right and then down, for `frame_count` frames -- which may be fewer
	than the grid holds, since a sheet's last row is often part empty.

	This is the 2D animation system and is unrelated to `animation3d.odin`,
	which animates a skeleton. Nothing here touches a model.
*/
create_animated_sprite :: proc(bytes: []byte, frame_w: f32, frame_h: f32, cols: i32, rows: i32, frame_count: i32, seconds_per_frame: f32, scale: f32 = 1) -> AnimatedSprite {
    sprite: AnimatedSprite
    sprite.clip  = load_animation(bytes, frame_w, frame_h, cols, rows, frame_count, seconds_per_frame)
    sprite.scale = scale
    sprite.size  = {frame_w * scale, frame_h * scale}
    sprite.pivot = {0.5, 0.5}
    sprite.tint  = WHITE
    return sprite
}

// The clip on its own, without a sprite wrapped round it. What to use when
// several sprites play the same sheet, or when a sprite switches between clips
// -- see `switch_animation`.
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

// Gives the clip's sheet texture back to the GPU. A clip shared between
// sprites is destroyed once, not once per sprite.
destroy_animation_clip :: proc(clip: ^AnimationClip) {
	destroy_mesh(&clip.mesh)
}

// Puts a different clip on a sprite and restarts it from frame zero.
//
// Asking for the clip already playing does nothing, which is what lets a game
// call this every frame from a state machine without the animation being stuck
// on its first frame forever.
switch_animation :: proc(sprite: ^AnimatedSprite, clip: AnimationClip) {
    // Same sheet means same clip: the texture handle identifies it now that
    // there are no descriptor-pool ids to compare.
    if sprite.clip.texture == clip.texture do return
    sprite.clip          = clip
    sprite.current_frame = 0
    sprite.accumulator   = 0
    sprite.size          = {clip.frame_w * sprite.scale, clip.frame_h * sprite.scale}
}

// Advances the sprite's frame and works out its uv window. Call once a frame,
// before drawing.
//
// The 2D one. `update_animator` is the skeletal equivalent.
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


// Draws the current frame. `update_animation` decides which frame that is, so
// a sprite drawn without being updated shows the same one forever.
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
	// above, which is now what draw_sprite does too, so the only thing left for
	// the fragment stage is the tint.
	frag_data := sprite_frag_data(sprite.body)

	draw_quad(
		mbi.renderer.pipelines.sprite, &vert_data, &frag_data, size_of(frag_data),
		sprite.clip.texture, sprite.clip.sampler,
	)
}
