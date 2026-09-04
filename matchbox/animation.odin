package matchbox

import "base:runtime"

import "core:log"
import "core:slice"
import "core:strings"


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

	// looping wraps back to frame_start forever, which is the default -- a
	// walk or an idle has no "finished" to reach. false stops on the clip's
	// last frame and clears playing, which is what a one-shot (an attack, a
	// death) gives a game to watch for.
	looping:       bool,
	playing:       bool,
}

/*
	A sprite that plays frames off a sheet, in one call.

	The sheet is a grid: `cols` by `rows` frames of `frame_w` by `frame_h`, read
	left to right and then down, for `frame_count` frames -- which may be fewer
	than the grid holds, since a sheet's last row is often part empty.

	This is the 2D animation system and is unrelated to `animation3d.odin`,
	which animates a skeleton. Nothing here touches a model.

	`looping = false` makes it a one-shot: it stops on its last frame and
	clears `playing`, which a game checks (`!sprite.playing`) to know it has
	finished.
*/
create_animated_sprite :: proc(bytes: []byte, frame_w: f32, frame_h: f32, cols: i32, rows: i32, frame_count: i32, seconds_per_frame: f32, scale: f32 = 1, looping := true) -> AnimatedSprite {
    sprite: AnimatedSprite
    sprite.clip    = load_animation(bytes, frame_w, frame_h, cols, rows, frame_count, seconds_per_frame)
    sprite.scale   = scale
    sprite.size    = {frame_w * scale, frame_h * scale}
    sprite.pivot   = {0.5, 0.5}
    sprite.tint    = WHITE
    sprite.looping = looping
    seat_first_frame(&sprite)
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

	// Freed here rather than left for the frame's `free_all`, so a game that
	// loads a hundred clips at startup does not hold every decoded frame of all
	// of them at once. An Image carries the allocator its pixels came from, so
	// this gives them back to the temp allocator rather than to the heap.
	defer for &image in images do destroy_image(&image)

	frame_w, frame_h: i32
	for bytes, i in frames {
		image, decoded := load_image(bytes, context.temp_allocator)
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

/*
	A clip from a whole folder of frames, in the order a person would read them.

	`#load_directory` is a compile-time builtin and needs a literal path, so it
	has to be written at the call site -- matchbox cannot call it for you:

		clip, ok := mb.load_animation_directory(#load_directory("art/walk"), 0.1)

	**Two things make the raw builtin's output unusable**, and both are handled
	here. It returns *every* file in the folder, so a stray `notes.txt` or a
	`.psd` fails the load. And it orders lexicographically, which puts `walk_10`
	before `walk_2` -- an animation that plays its frames in the wrong order, out
	of a folder that looks perfectly sensible in a file browser.

	Anything not matching `suffixes` is skipped rather than treated as an error:
	a folder with a readme in it is normal, and refusing to load would be less
	use than ignoring it. The remainder are sorted so that digits inside a name
	compare by value.

	Note that `#load_directory` bakes **every** file in the folder into the
	executable, including the ones skipped here. Keep `.psd` sources and working
	files somewhere else, or they ship too.

	`load_animation_frames` is the explicit form, for frames named individually
	or assembled from more than one place.
*/
load_animation_directory :: proc(
	files:             []runtime.Load_Directory_File,
	seconds_per_frame: f32,
	columns:           i32 = 0,
	suffixes:          []string = {".png", ".jpg", ".jpeg", ".bmp", ".tga"},
) -> (clip: AnimationClip, ok: bool) {
	keep := make([dynamic]runtime.Load_Directory_File, 0, len(files), context.temp_allocator)

	for file in files {
		lower := strings.to_lower(file.name, context.temp_allocator)
		for suffix in suffixes {
			if strings.has_suffix(lower, suffix) {
				append(&keep, file)
				break
			}
		}
	}

	if len(keep) == 0 {
		log.errorf("load_animation_directory: none of the %v file(s) look like images", len(files))
		return {}, false
	}

	slice.sort_by(keep[:], proc(a, b: runtime.Load_Directory_File) -> bool {
		return natural_less(a.name, b.name)
	})

	frames := make([][]byte, len(keep), context.temp_allocator)
	for file, i in keep do frames[i] = file.data

	return load_animation_frames(frames, seconds_per_frame, columns)
}

/*
	Orders names the way a person expects: "walk_2" before "walk_10".

	A plain string compare puts "10" before "2", because it compares '1' against
	'2' and stops. Frames are numbered, so a plain compare is wrong for exactly
	the case this package cares about, and wrong in a way that looks like a
	rigging or export problem rather than a sorting one.

	Runs of digits compare by value, everything else byte by byte. Leading zeros
	are skipped first, so a folder that mixes "07" and "7" still orders sensibly
	rather than by how the artist happened to pad that day.
*/
@(private)
natural_less :: proc(a, b: string) -> bool {
	i, j := 0, 0

	for i < len(a) && j < len(b) {
		digit_a := a[i] >= '0' && a[i] <= '9'
		digit_b := b[j] >= '0' && b[j] <= '9'

		if digit_a && digit_b {
			for i < len(a) - 1 && a[i] == '0' && a[i + 1] >= '0' && a[i + 1] <= '9' do i += 1
			for j < len(b) - 1 && b[j] == '0' && b[j + 1] >= '0' && b[j + 1] <= '9' do j += 1

			start_a, start_b := i, j
			for i < len(a) && a[i] >= '0' && a[i] <= '9' do i += 1
			for j < len(b) && b[j] >= '0' && b[j] <= '9' do j += 1

			// More digits means a bigger number, once leading zeros are gone.
			if (i - start_a) != (j - start_b) do return (i - start_a) < (j - start_b)
			if a[start_a:i] != b[start_b:j]   do return a[start_a:i] < b[start_b:j]
			continue
		}

		if a[i] != b[j] do return a[i] < b[j]

		i += 1
		j += 1
	}

	// Whichever has more left is the longer name, and sorts after.
	return len(a) - i < len(b) - j
}

/*
	A stretch of a sheet as a clip of its own -- walk, idle and jump off one set
	of frames -- given as the first and last frame, inclusive, and clamped to the
	frames the sheet actually has.

		sheet, _ := mb.load_animation_directory(#load_directory("art/hero"), 0.1)
		idle := mb.animation_range(sheet, 67,  74, 0.20)   // 8 frames
		walk := mb.animation_range(sheet, 95, 106, 0.10)   // 12 frames

	**`last` is the final frame, not a count.** This took a `count` first, and
	every call site written against it got the same thing wrong: the numbers a
	game has are the ones printed beside a frame listing, so `(67, 74)` is what
	somebody writes when they mean frames 67 through 74. Reading it as a count
	gave them 74 frames -- most of the sheet -- and the clamp below quietly made
	that legal. Two procedures, one counting and one not, would only have moved
	the coin flip to the call site.

	A view, not a copy: the returned clip points at the same texture, so this
	costs no upload and no VRAM, and a game may make as many as it likes.

	**Destroy the sheet, not the ranges.** They share its texture, so passing
	each to `destroy_animation_clip` would free the same texture several times.
	This is the same rule that already applies to one clip shared between several
	sprites, and the reason `destroy_animation_clip` takes the clip rather than
	the sprite.

	`seconds_per_frame` of 0 keeps the sheet's, which is usually right for ranges
	cut from one animation and usually wrong for ranges that are different moves
	-- a walk and a jump rarely run at the same rate.

	A range is clamped rather than refused, because the common way to get this
	wrong is an off-by-one at the end of a sheet, and a clip one frame short is a
	great deal easier to see than a silent failure. `last` before `first` gives
	the single frame `first`, which is visibly stuck rather than empty.
*/
animation_range :: proc(
	clip:              AnimationClip,
	first:             i32,
	last:              i32,
	seconds_per_frame: f32 = 0,
) -> AnimationClip {
	total := max(clip.cols * clip.rows, 1)

	begin := clamp(first, 0, total - 1)
	end   := clamp(last,  begin, total - 1)

	out := clip
	out.frame_start = begin
	out.frame_count = end - begin + 1

	if seconds_per_frame > 0 do out.seconds_per_frame = seconds_per_frame

	return out
}

/*
	Puts a sprite on the first frame of its clip, uv window included.

	Shared by `animated_sprite_of` and `switch_animation` because they have to
	agree: a sprite whose `current_frame` says one thing and whose uv window
	shows another is wrong on screen and right in the debugger, which is the
	worst pair to chase.

	The first frame is `frame_start`, not 0. For a range cut out of the middle of
	a sheet those differ, and using 0 draws a frame belonging to some other
	animation.

	Also sets `playing` -- seating the first frame is what starting or
	restarting a clip means, so a one-shot that had already finished plays
	again rather than staying stuck on its last frame.
*/
@(private)
seat_first_frame :: proc(sprite: ^AnimatedSprite) {
	clip := sprite.clip
	if clip.cols <= 0 || clip.rows <= 0 do return

	sprite.current_frame = clip.frame_start
	sprite.accumulator   = 0
	sprite.playing       = true

	col := clip.frame_start % clip.cols
	row := clip.frame_start / clip.cols

	sprite.uv_min = {f32(col)     / f32(clip.cols), f32(row)     / f32(clip.rows)}
	sprite.uv_max = {f32(col + 1) / f32(clip.cols), f32(row + 1) / f32(clip.rows)}
}

/*
	A sprite ready to play `clip`, with everything that is not obviously yours
	already set.

	`create_animated_sprite` does this for a sheet, but it loads the sheet too,
	so there was no way to get a seated sprite from a clip you already have --
	and building one by hand walks straight into two fields whose zero value
	means *invisible*. `scale` of 0 gives a sprite sized 0x0, and `tint` of
	`{0,0,0,0}` is transparent black. Either one draws nothing, with no error and
	no log line to say why. That cost somebody an afternoon, which is why this
	exists.

		sprite := mb.animated_sprite_of(clip, scale = 4)
		sprite.position = {100, 100}

	Only `position` is left at zero, because that is a decision rather than an
	oversight. Note that `draw_animated_sprite` adds `pivot * size`, so
	`position` is the top-left corner and a centred pivot draws half a frame
	right and down of it.

	The uv window is seeded to the first frame, so a sprite drawn before its
	first `update_animation` shows frame 0 rather than a zero-width sample of the
	sheet's top-left texel.

	`scale` of 0 or less is treated as 1, as `sprite_of` does -- a caller who
	leaves it out wants a sprite, not an invisible one.

	`looping = false` makes it a one-shot -- see `create_animated_sprite`.
*/
animated_sprite_of :: proc(clip: AnimationClip, scale: f32 = 1, looping := true) -> AnimatedSprite {
	final_scale := scale
	if final_scale <= 0 do final_scale = 1

	sprite: AnimatedSprite
	sprite.clip    = clip
	sprite.scale   = final_scale
	sprite.size    = {clip.frame_w * final_scale, clip.frame_h * final_scale}
	sprite.pivot   = {0.5, 0.5}
	sprite.tint    = WHITE
	sprite.looping = looping

	seat_first_frame(&sprite)

	return sprite
}

// Gives the clip's sheet texture back to the GPU. A clip shared between
// sprites is destroyed once, not once per sprite.
destroy_animation_clip :: proc(clip: ^AnimationClip) {
	destroy_mesh(&clip.mesh)
}

// Puts a different clip on a sprite and restarts it from frame zero.
//
// Asking for the clip already playing does nothing but sync `looping`, which
// is what lets a game call this every frame from a state machine without the
// animation being stuck on its first frame forever -- and without a finished
// one-shot being restarted just because the state machine is still asking for
// it. Ask for a *different* clip to play it again.
switch_animation :: proc(sprite: ^AnimatedSprite, clip: AnimationClip, looping := true) {
    /*
        What makes two clips the same: the sheet *and* the stretch of it being
        played. The texture alone used to decide, which was right while every
        clip owned its own sheet and silently wrong the moment `animation_range`
        existed -- walk and idle cut from one sheet share a texture, so a game
        asking to switch between them got no switch at all and no complaint.

        Speed is deliberately not part of it. A game nudging seconds_per_frame
        to match its own pace wants that to take effect, not to restart the
        animation from its first frame.
    */
    same := sprite.clip.texture     == clip.texture     &&
            sprite.clip.frame_start == clip.frame_start &&
            sprite.clip.frame_count == clip.frame_count

    if same {
        // The clip is the one already playing, but its tuning may have moved.
        sprite.clip.seconds_per_frame = clip.seconds_per_frame
        sprite.looping = looping
        return
    }
    sprite.clip    = clip
    sprite.size    = {clip.frame_w * sprite.scale, clip.frame_h * sprite.scale}
    sprite.looping = looping

    // Not frame 0: a range starting at 4 left on frame 0 is outside its own
    // cycle, and update_animation's wrap arithmetic then lands somewhere that
    // belongs to neither animation. Also reseats `playing`, so switching back
    // to a one-shot plays it again rather than leaving it finished.
    seat_first_frame(sprite)
}

// Advances the sprite's frame and works out its uv window. Call once a frame,
// before drawing.
//
// A non-looping clip stops on its last frame and clears `playing`, which is
// what a game watches (`!sprite.playing`) to know a one-shot has finished --
// the same signal `update_animator`'s `playing` gives for the skeletal system.
// Once stopped, further calls recompute the same uv window and do nothing
// else, so a flip toggled after the fact still takes -- restart with
// `switch_animation` or `animated_sprite_of`.
//
// The 2D one. `update_animator` is the skeletal equivalent.
update_animation :: proc(sprite: ^AnimatedSprite, delta_time: f32) {
    if sprite.playing {
        sprite.accumulator += delta_time
        if sprite.accumulator >= sprite.clip.seconds_per_frame {
            sprite.accumulator -= sprite.clip.seconds_per_frame

            next := sprite.current_frame - sprite.clip.frame_start + 1
            if next >= sprite.clip.frame_count && !sprite.looping {
                sprite.current_frame = sprite.clip.frame_start + sprite.clip.frame_count - 1
                sprite.playing = false
            } else {
                sprite.current_frame = sprite.clip.frame_start + next % sprite.clip.frame_count
            }
        }
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
