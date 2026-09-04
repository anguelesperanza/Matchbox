package matchbox

import "core:log"
import "core:slice"


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

/*
	A clip from frames that arrived as separate image files.

	`load_animation` wants one sheet. Art does not always come that way -- an
	exporter that writes `run_00.png` through `run_07.png` is as common as one
	that writes a strip -- so this packs them into a sheet at load time and hands
	back an ordinary `AnimationClip`. Everything downstream is unchanged:
	`switch_animation`, `update_animation` and `destroy_animation_clip` do not
	know the difference.

	Frames are encoded bytes, not paths, for the same reason `create_sprite`
	takes them: `#load` puts the art inside the executable, which is what makes
	it work unchanged inside an Android apk.

		clip, ok := mb.load_animation_frames({
			#load("art/run_0.png"), #load("art/run_1.png"), #load("art/run_2.png"),
		}, 0.1)

	**Packing rather than a texture per frame** costs one upload at load and
	saves a bind per draw. `draw_animated_sprite` binds the clip's texture on
	every call, so a screen of twenty characters is twenty binds either way with
	a sheet, and twenty binds *plus* a texture switch per frame without one.

	`columns` lays the grid out; 0 picks a roughly square one. A single row is
	the obvious choice and the wrong one at scale: a row of a hundred 256-pixel
	frames is 25,600 pixels wide, past the 16,384 limit common hardware imposes,
	and the upload fails for reasons that have nothing to do with the art.

	Frames of different sizes are **padded to the largest, not stretched**, so a
	frame the artist drew smaller stays where they put it. The cell size is the
	largest frame in the set, which is also what the sprite's `size` becomes.

	Returns `ok = false` if the set is empty or a frame fails to decode, rather
	than taking the process down the way `create_sprite` does. Frames are asset
	data and a game may reasonably want to carry on without one.
*/
load_animation_frames :: proc(
	frames:            [][]byte,
	seconds_per_frame: f32,
	columns:           i32 = 0,
) -> (clip: AnimationClip, ok: bool) {
	if len(frames) == 0 {
		log.error("load_animation_frames: no frames")
		return {}, false
	}

	images := make([]Image, len(frames), context.temp_allocator)

	// Decoded through the context allocator and freed here, not through the temp
	// one: `load_image` takes an allocator but `destroy_image` does not, so it
	// always frees with `context.allocator`. Handing it temp-allocated pixels is
	// a bad free that the default allocators shrug off and a tracking allocator
	// reports -- in a game that did nothing wrong.
	defer for &image in images do destroy_image(&image)

	frame_w, frame_h: i32
	for bytes, i in frames {
		image, decoded := load_image(bytes)
		if !decoded {
			log.errorf("load_animation_frames: frame %v did not decode", i)
			return {}, false
		}

		images[i] = image
		frame_w = max(frame_w, image.width)
		frame_h = max(frame_h, image.height)
	}

	count := i32(len(frames))

	cols := columns
	if cols <= 0 {
		// Roughly square, so the sheet grows in both directions rather than off
		// the end of what the hardware will take.
		cols = 1
		for cols * cols < count do cols += 1
	}
	cols = min(cols, count)
	rows := (count + cols - 1) / cols

	// Zeroed, so the padding around a frame smaller than the cell is
	// transparent rather than whatever the allocator last held.
	sheet := make([][4]u8, int(frame_w) * int(cols) * int(frame_h) * int(rows),
		context.temp_allocator)

	sheet_w := frame_w * cols
	for image, i in images {
		ox := (i32(i) % cols) * frame_w
		oy := (i32(i) / cols) * frame_h

		for y in 0 ..< image.height {
			copy(sheet[(oy + y) * sheet_w + ox:][:image.width],
			     image.pixels[y * image.width:][:image.width])
		}
	}

	return AnimationClip{
		mesh              = create_mesh_from_pixels(slice.to_bytes(sheet), sheet_w, frame_h * rows),
		cols              = cols,
		rows              = rows,
		frame_count       = count,
		seconds_per_frame = seconds_per_frame,
		frame_w           = f32(frame_w),
		frame_h           = f32(frame_h),
	}, true
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
