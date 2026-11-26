package matchbox

/*
	Animator
	========
	One character's skeletal playback: which clip, how far into it, the fade from the clip before, and the
	matrices that come out. The data it plays is the Model's (skeleton.odin).

		hero := mb.load_model("models/hero.glb")
		animator := mb.create_animator(hero)
		mb.play_animation(&animator, hero, "Walk")
		...
		mb.update_animator(&animator, hero, mb.get_delta_time())
		mb.render_model(hero, animator, mb.create_transform(position))

	A clip that is not looping stops on its last pose and sets `animator.playing` to false: the game
	polls it, as it polls `sprite.playing`. There are no callbacks.

	Left out of G6, on purpose: animation layers (two clips at once on different parts of the body).
	`Animator` is shaped so they are a later addition, one field and one loop in `update_animator`
	(docs/g6_skinned_animation_plan.md, "What leaving layers out costs")
*/

import "core:log"
import "core:math/linalg"

/*One clip being played and how far into it. `clip` indexes `model.animations`, -1 for nothing to play*/
Animation_Playback :: struct {
	clip:int,
	time:f32,
	speed:f32,
	looping:bool,
	playing:bool,
}

/*
	How a change of clip is smoothed over. Without it `play_animation` snaps: the character is mid-stride in
	a walk on one frame and standing in an idle's first on the next. With it the two poses are mixed over
	`duration`. `enabled` and `duration` are the game's to set; from `active` down is state the blend keeps.

	The outgoing clip keeps playing while it fades, so the legs being left behind are still moving when
	they are handed over. A blend interrupted by another has no third pose to keep, so the mix at that
	instant is frozen and faded from, and `from.clip` is -1 to say so
*/
Animation_Blend :: struct {
	enabled:bool,
	duration:f32, // seconds; long enough to see, short enough that the character is not visibly in two poses
	active:bool,
	elapsed:f32,
	from:Animation_Playback,
}

/*
	One character's working space, sized once and rewritten every frame. `locals` is this frame's pose
	before the hierarchy, `globals` after; `from` is the pose being faded out. `joint_data` is every skinned
	part's palette back to back, and `palettes[i]` is a slice into it for `model.parts[i]`, so freeing the
	animator deletes it once. Nothing here is a GPU object: render_model copies the palette into the
	frame's joint arena, so an animator can be made at any moment on any target
*/
Animation_Pose :: struct {
	locals:[]Transform,
	from:[]Transform,
	globals:[]matrix[4, 4]f32,
	palettes:[][]matrix[4, 4]f32,
	joint_data:[]matrix[4, 4]f32,
}

/*
	One character's playback. The playback is `using`, so `animator.playing` and `animator.time` need no
	second name: a game asks whether the animator is playing, not whether its playback is
*/
Animator :: struct {
	using playback:Animation_Playback,
	blend:Animation_Blend,
	pose:Animation_Pose,
}

/*
	An animator for `model`, standing in its bind pose until the first update. Allocates, so it pairs with
	destroy_animator, and it is per character: one Model, an Animator for each thing wearing it. A model
	with no skeleton gets an inert animator, so this is safe on whatever load_model returned
*/
create_animator :: proc(model:Model, blend := Animation_Blend{enabled = true, duration = 0.2}) -> Animator {
	idle := Animation_Playback{clip = -1, speed = 1, looping = true}

	if is_model_skinned(model) == false {
		return Animator{playback = idle, blend = blend}
	}

	node_count := len(model.skeleton.rest)
	animator := Animator {
		playback = idle,
		blend = blend,
		pose = Animation_Pose {
			locals = make([]Transform, node_count),
			from = make([]Transform, node_count),
			globals = make([]matrix[4, 4]f32, node_count),
			palettes = make([][]matrix[4, 4]f32, len(model.parts)),
		},
	}
	// The state half of the blend is this animator's, whatever was passed in
	animator.blend.active = false
	animator.blend.elapsed = 0
	animator.blend.from = Animation_Playback{clip = -1}

	total := 0
	for part in model.parts do if part.mesh.skinned do total += len(part.joint_map)
	if total > 0 do animator.pose.joint_data = make([]matrix[4, 4]f32, total)

	used := 0
	for part, index in model.parts {
		if part.mesh.skinned == false do continue
		count := len(part.joint_map)
		animator.pose.palettes[index] = animator.pose.joint_data[used:][:count]
		used += count
	}

	// The bind pose, so a character drawn before its first update is a character rather than a heap of triangles
	copy(animator.pose.locals, model.skeleton.rest)
	resolve_skeleton_pose(model, animator.pose.locals, animator.pose.globals, animator.pose.palettes)
	return animator
}

/*Frees an animator's working arrays. The Model is untouched; several animators share one*/
destroy_animator :: proc(animator:^Animator) {
	delete(animator.pose.joint_data)
	delete(animator.pose.palettes)
	delete(animator.pose.globals)
	delete(animator.pose.from)
	delete(animator.pose.locals)
	animator^ = Animator{playback = {clip = -1, speed = 1, looping = true}}
}

/*The index of a clip by name, for a game that would rather write "Walk" than remember a number*/
get_animation_index :: proc(model:Model, name:string) -> (index:int, found:bool) {
	for clip, i in model.animations {
		if clip.name == name do return i, true
	}
	return -1, false
}

/*
	The clips' names in the order play_animation_index numbers them. The slice is temp-allocated and lasts
	until the temp allocator is freed (the end of the frame); the strings are the model's own
*/
get_animation_names :: proc(model:Model, allocator := context.temp_allocator) -> []string {
	names := make([]string, len(model.animations), allocator)
	for clip, i in model.animations do names[i] = clip.name
	return names
}

/*
	The index of a skeleton node by name: the bone to hang a weapon off. **A node index, not a joint
	index**, and the two are different numbers: a node index addresses `skeleton.parents`, `rest` and an
	animator's `pose.globals`; a joint index addresses `skin.joints` and a palette. Feeding one to the other
	is in range, silent, and attaches the pistol to a fingertip, which is why this returns a `u32` named
	`node`. Exact match only: `hand` matches `handIK.R` in some rigs and half the guesses would be an IK
	target. Resolve at load and check `found` there; first wins if a file names two nodes alike
*/
get_node_index :: proc(model:Model, name:string) -> (node:u32, found:bool) {
	if name == "" do return 0, false
	for candidate, i in model.skeleton.names {
		if candidate == name do return u32(i), true
	}
	return 0, false
}

/*
	Where a skeleton node has been posed, in the model's own space (the one a Transform is applied to and
	bounds_min / bounds_max are measured in). The mesh node's own transform is divided out, as the palette
	does: glTF says a skinned mesh ignores the transform of the node it hangs off. The identity for a node
	out of range, which puts the object at the model's origin: wrong, visible and diagnosable
*/
calculate_node_matrix :: proc(model:Model, animator:Animator, node:u32) -> matrix[4, 4]f32 {
	if int(node) >= len(animator.pose.globals) do return linalg.MATRIX4F32_IDENTITY

	for part in model.parts {
		if part.mesh.skinned == false do continue
		if part.mesh_node < 0 || part.mesh_node >= len(animator.pose.globals) do break
		return linalg.inverse(animator.pose.globals[part.mesh_node]) * animator.pose.globals[node]
	}
	return animator.pose.globals[node]
}

/*
	Where a node is in the world, for a model drawn with `transform`: the matrix to hang a weapon off. Pass the
	transform the model was drawn with; anything else puts the attachment somewhere the model is not
*/
calculate_node_world_matrix :: proc(model:Model, animator:Animator, node:u32, transform:Transform) -> matrix[4, 4]f32 {
	return calculate_transform_matrix(transform) * calculate_node_matrix(model, animator, node)
}

/*
	Plays the clip called `name`. False, with the animator left alone, when the model has no such clip: a typo
	or a re-export rather than something to stop the game for. Asking for the clip already playing changes
	only `looping`, so a state machine may call this every frame without freezing the character on its first
	frame. Ask for a different clip to fade to it
*/
play_animation :: proc(animator:^Animator, model:Model, name:string, looping := true) -> bool {
	index, found := get_animation_index(model, name)
	if found == false {
		log.errorf("model has no animation named %q", name)
		return false
	}
	play_animation_index(animator, model, index, looping)
	return true
}

/*The same by index, for a game that resolved the name once and kept it*/
play_animation_index :: proc(animator:^Animator, model:Model, index:int, looping := true) {
	if index < 0 || index >= len(model.animations) do return

	if animator.clip == index {
		animator.looping = looping
		return
	}

	// A fade, unless there is nothing to fade from or the game asked for none. The same-clip case never reaches here
	if animator.blend.enabled && animator.blend.duration > 0 && animator.playing && animator.clip >= 0 {
		if animator.blend.active {
			// Already fading: no third pose to keep and no sensible way to fade from two clips at once, so the
			// mix as it stands this instant is frozen and faded from
			copy(animator.pose.from, animator.pose.locals)
			animator.blend.from = Animation_Playback{clip = -1}
		} else {
			animator.blend.from = animator.playback
		}
		animator.blend.active = true
		animator.blend.elapsed = 0
	}

	animator.clip = index
	animator.time = 0
	animator.looping = looping
	animator.playing = true
}

/*Stops where it is. The pose stays put, which is what a paused character should look like*/
stop_animation :: proc(animator:^Animator) {
	animator.playing = false
}

/*
	Moves the animation on by `delta_time` seconds and works the pose out. Call once a frame. The fade is
	eased (smoothstep) because a straight ramp leaves the pose moving at full blend speed up to the last
	frame and stopping dead, a velocity step that reads as a flinch
*/
update_animator :: proc(animator:^Animator, model:Model, delta_time:f32) {
	if is_model_skinned(model) == false do return
	if len(animator.pose.locals) != len(model.skeleton.rest) do return

	if animator.blend.active {
		animator.blend.elapsed += delta_time
		// The outgoing clip keeps running while it goes. A from.clip of -1 is a frozen pose already in pose.from
		if animator.blend.from.clip >= 0 && animator.blend.elapsed < animator.blend.duration {
			advance_playback_time(&animator.blend.from, model.animations[animator.blend.from.clip].duration, delta_time)
			sample_skeleton_pose(model, animator.blend.from.clip, animator.blend.from.time, animator.pose.from)
		}
	}

	if animator.clip >= 0 && animator.clip < len(model.animations) {
		advance_playback_time(&animator.playback, model.animations[animator.clip].duration, delta_time)
	}
	sample_skeleton_pose(model, animator.clip, animator.time, animator.pose.locals)

	if animator.blend.active {
		t:f32 = 1
		if animator.blend.duration > 0 do t = clamp(animator.blend.elapsed / animator.blend.duration, 0, 1)
		t = t * t * (3 - 2 * t)

		for i in 0 ..< len(animator.pose.locals) {
			animator.pose.locals[i] = calculate_transform_mix(animator.pose.from[i], animator.pose.locals[i], t)
		}

		// Retired after the mix, not before: dropping out on the frame the clock runs over would skip the last
		// step of the fade and land on the destination in one go, the exact snap this exists to remove
		if t >= 1 do animator.blend.active = false
	}

	resolve_skeleton_pose(model, animator.pose.locals, animator.pose.globals, animator.pose.palettes)
}
