#+build windows

package matchbox

/*
	Animation
	=========
	Plays frames of a sprite sheet, in order, on a `Sprite`.

	A sheet is a Texture with a .meta file (made by tools/sheetpack), so frames
	are numbered 0, 1, 2 ... left to right, then down. A *clip* is a stretch of
	those frames plus how fast to play them:

		sheet := mb.create_animation_clip(sheet_texture, 0.1) // every frame, 0.1s each
		walk  := mb.animation_range(sheet, 95, 106)           // frames 95 to 106, inclusive
		idle  := mb.animation_range(sheet, 67, 74, 0.2)       // a different speed

		player := mb.create_animated_sprite_from_clip(idle, 2)
		...
		mb.switch_animation(&player, walk)   // safe to call every frame
		mb.update_animation(&player, delta_time)
		mb.render_animated_sprite(player)

	The current frame lives in `sprite.frame`, the same field a plain Sprite
	uses, so there is nothing to keep in step.
*/

import "core:log"

/*
	How many clips can be lined up behind the one playing.

	An array size, which is the exception CLAUDE.md allows -- Odin needs a
	compile time constant for a fixed bound, and a fixed bound keeps the queue
	out of the allocator. Four covers a jump's begin, rise and loop with one spare.
*/
MAX_ANIMATION_QUEUE :: 4

/*A stretch of a sheet. `frame_start` and `frame_count` are frame numbers, not pixels*/
Animation_Clip :: struct {
	texture:Texture, // the sheet
	frame_start:int, // first frame of the clip
	frame_count:int, // how many frames, at least 1
	seconds_per_frame:f32, // 0 = frozen on the first frame

	// Moves the drawing, not the sprite: image pixels, +x right and +y up, in the
	// sheet's own pixels, so it scales with the sprite. For art that is drawn off
	// its anchor -- a crouch attack whose frames sit 33 pixels left of the crouch
	// it returns to would jump back when it ends. Mirrored with `flip_x`
	offset:[2]f32,
}

// A clip waiting its turn, with the `looping` it should start under. They travel
// together because a queued clip is nearly always a one-shot while the last
// clip of a chain nearly always loops.
Queued_Animation :: struct {
	clip:Animation_Clip,
	looping:bool,
}

Animated_Sprite :: struct {
	using sprite:Sprite, // `sprite.frame` is the frame showing now. flip_x, position etc live here
	clip:Animation_Clip,
	accumulator:f32, // seconds not yet turned into a frame

	// looping wraps back to the first frame forever, which is the default -- a
	// walk or an idle has no "finished". false stops on the last frame and
	// sets `playing` to false: what a one-shot (an attack) gives a game to watch for.
	looping:bool,
	playing:bool,

	queue:[MAX_ANIMATION_QUEUE]Queued_Animation,
	queue_len:int,
}

/*A clip of the whole sheet, every frame. Cut pieces from it with `animation_range`*/
create_animation_clip :: proc(texture:Texture, seconds_per_frame:f32) -> Animation_Clip {
	return Animation_Clip {
		texture = texture,
		frame_start = 0,
		frame_count = max(int(texture.frame_count), 1),
		seconds_per_frame = seconds_per_frame,
	}
}

/*
	A piece of a clip, from frame `first` to frame `last`, both included.
	Frame numbers are the sheet's, so `(sheet, 67, 74)` is the eight frames 67 to 74.

	A range is clamped rather than refused, because the usual mistake is one
	off at the end of a sheet, and a clip one frame short is much easier to see
	than a silent failure. `last` before `first` gives the single frame `first`.
	`seconds_per_frame` of 0 keeps the speed the clip already has.
*/
animation_range :: proc(clip:Animation_Clip, first, last:int, seconds_per_frame:f32 = 0) -> Animation_Clip {
	total := max(int(clip.texture.frame_count), 1)

	begin := clamp(first, 0, total - 1)
	end := clamp(last, begin, total - 1)

	out := clip
	out.frame_start = begin
	out.frame_count = end - begin + 1
	if seconds_per_frame > 0 do out.seconds_per_frame = seconds_per_frame
	return out
}

/*
	A sprite ready to play `clip`. `scale` multiplies the world size (1 = frame
	size / pixels per unit) and `pixels_per_unit` of 0 uses the sheet's own.
	`looping = false` makes it a one-shot.
*/
create_animated_sprite_from_clip :: proc(clip:Animation_Clip, scale:f32 = 1, looping := true, pixels_per_unit:f32 = 0) -> Animated_Sprite {
	sprite:Animated_Sprite
	sprite.sprite = create_sprite(clip.texture, {}, pixels_per_unit)
	sprite.scale = {scale, scale} if scale > 0 else {1, 1}
	sprite.clip = clip
	sprite.looping = looping

	seat_first_frame(&sprite)
	return sprite
}

/*Gives the sheet back to the GPU. Clips are only numbers, so a sheet shared by
many clips and sprites is destroyed once*/
destroy_animation_clip :: proc(clip:Animation_Clip) {
	destroy_texture(clip.texture)
}

// Puts the sprite on the first frame of its clip and starts it. A one-shot that
// had finished plays again. The first frame is `frame_start`, not 0 -- a range
// cut from the middle of a sheet would otherwise start on someone else's frame.
@(private="file")
seat_first_frame :: proc(sprite:^Animated_Sprite) {
	sprite.texture = sprite.clip.texture
	sprite.frame = sprite.clip.frame_start
	sprite.accumulator = 0
	sprite.playing = true
}

/*
	Plays a different clip from its first frame.

	Asking for the clip already playing does nothing except update its speed and
	`looping`. That is what lets a game call this every frame from a state machine
	without the animation being stuck on its first frame, and without a finished
	one-shot restarting just because the state machine still wants it. Ask for a
	*different* clip to play something again.

	Two clips are the same when they have the same sheet and the same frames.
	Speed is not part of it: a game that nudges `seconds_per_frame` wants that to
	take effect, not a restart.
*/
switch_animation :: proc(sprite:^Animated_Sprite, clip:Animation_Clip, looping := true) {
	same := sprite.clip.texture == clip.texture &&
		sprite.clip.frame_start == clip.frame_start &&
		sprite.clip.frame_count == clip.frame_count

	if same == true {
		sprite.clip.seconds_per_frame = clip.seconds_per_frame
		sprite.clip.offset = clip.offset
		sprite.looping = looping
		return
	}

	// A real switch drops whatever was lined up behind the old clip. A character
	// hit mid-jump should not go on to finish the jump
	sprite.queue_len = 0

	sprite.clip = clip
	sprite.looping = looping
	seat_first_frame(sprite)
}

/*
	Lines a clip up to play when the current one finishes:

		mb.switch_animation(&player, jump_begin, looping = false)
		mb.queue_animation(&player, jump_up, false)
		mb.queue_animation(&player, jump_rise, true)

	`looping` has no default on purpose: a queued clip is usually a one-shot
	handing on to the next, and a wrong default fails silently.

	Only a clip that finishes pulls the next one, so queueing behind a looping
	clip lines up something that is never reached. Queueing onto a clip that has
	already finished does nothing either; use `switch_animation` to start from a
	standstill. A full queue drops the new clip and logs an error.
*/
queue_animation :: proc(sprite:^Animated_Sprite, clip:Animation_Clip, looping:bool) {
	if sprite.queue_len >= MAX_ANIMATION_QUEUE {
		log.errorf("animation queue is full at %v; dropped the clip being queued", MAX_ANIMATION_QUEUE)
		return
	}

	sprite.queue[sprite.queue_len] = Queued_Animation{clip = clip, looping = looping}
	sprite.queue_len += 1
}

// Moves the front of the queue onto the sprite and starts it
@(private="file")
pop_queued_animation :: proc(sprite:^Animated_Sprite) {
	next := sprite.queue[0]

	for i in 1 ..< sprite.queue_len {
		sprite.queue[i - 1] = sprite.queue[i]
	}
	sprite.queue_len -= 1

	sprite.clip = next.clip
	sprite.looping = next.looping
	seat_first_frame(sprite)
}

/*
	Moves the animation forward by `delta_time` seconds. Call once a frame.

	A one-shot stops on its last frame and sets `playing` to false. With
	something queued behind it, it hands over to that clip instead.

	A clip with `seconds_per_frame` of 0 stays on its first frame rather than
	moving once per call, which would make it run at whatever rate the game
	renders at.
*/
update_animation :: proc(sprite:^Animated_Sprite, delta_time:f32) {
	clip := sprite.clip

	if sprite.playing == true && clip.frame_count > 0 && clip.seconds_per_frame > 0 {
		sprite.accumulator += delta_time

		// Every whole frame owed, in one division. A clip authored faster than the
		// game renders still plays at its own speed, and a huge delta_time cannot hang
		steps := int(sprite.accumulator / clip.seconds_per_frame)

		if steps > 0 {
			sprite.accumulator -= f32(steps) * clip.seconds_per_frame

			relative := sprite.frame - clip.frame_start

			if sprite.looping == false && relative + steps >= clip.frame_count {
				sprite.frame = clip.frame_start + clip.frame_count - 1
				sprite.playing = false
				sprite.accumulator = 0

				// The clip ran out, so what was queued behind it takes over. Only here,
				// not wherever `playing` happens to be false: pausing a sprite must not skip
				// to the next clip
				if sprite.queue_len > 0 do pop_queued_animation(sprite)
			} else {
				sprite.frame = clip.frame_start + (relative + steps) % clip.frame_count
			}
		}
	}
}

/*Which frame of the clip is showing, counting from 0. Relative to the clip, not the
sheet: "frame 3 of this attack" is the fourth frame of the attack*/
calculate_animation_frame :: proc(sprite:Animated_Sprite) -> int {
	if sprite.clip.frame_count <= 0 do return 0
	return sprite.frame - sprite.clip.frame_start
}

/*
	Whether playback is somewhere in `first ..= last`, counting from 0 in the clip.

	Inclusive at both ends, like `animation_range`. This is what a cancel window
	wants: "am I still in the stretch where the input is allowed".
	`last` before `first` is an empty window and is never inside.
*/
is_animation_in_window :: proc(sprite:Animated_Sprite, first, last:int) -> bool {
	if sprite.clip.frame_count <= 0 do return false

	frame := calculate_animation_frame(sprite)
	return frame >= first && frame <= last
}

/*How far the clip's `offset` moves the drawing, in world units. The offset is in
image pixels, so it scales with `scale`; a mirrored sprite is moved the other way,
because the art it describes is mirrored too*/
calculate_animation_render_offset :: proc(sprite:Animated_Sprite) -> [2]f32 {
	if sprite.pixels_per_unit <= 0 do return {}

	shift := sprite.clip.offset / sprite.pixels_per_unit * sprite.scale
	if sprite.flip_x == true do shift.x = -shift.x
	if sprite.flip_y == true do shift.y = -shift.y
	return shift
}

/*Draws an animated sprite. Same as render_sprite; the flip is read at draw time, so
it takes effect on the very next draw. The clip's `offset` is applied here*/
render_animated_sprite :: proc(sprite:Animated_Sprite, mode:Sprite_Mode = .CUTOUT) {
	shifted := sprite.sprite
	shift := calculate_animation_render_offset(sprite)
	shifted.position.x += shift.x
	shifted.position.y += shift.y
	render_sprite(shifted, mode)
}
