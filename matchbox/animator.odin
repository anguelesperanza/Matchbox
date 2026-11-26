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

	Layers play a second clip over some joints of the base, an arm waving over a walk:

		upper := mb.calculate_animation_mask_below(hero, spine)
		mb.play_animation_layer(&animator, hero, 0, "Wave", upper)
		if !animator.layers[0].playing { /* a one-shot finished: asked, not told */ }

	(docs/g6_skinned_animation_plan.md, the layer addendum)
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
	The most layers an animator holds: an array size, which Odin needs as a constant, so a layer is a fixed slot and an animator has no list to
	grow or free. What a target really works is `mbi.skin_settings.layer_limit`, and this is only the largest of those
*/
MAX_ANIMATION_LAYERS :: 4

/*How a layer's pose meets the pose under it*/
Animation_Layer_Mode :: enum {
	REPLACE, // the layer's pose takes over its masked joints, mixed by strength: an upper-body clip over a walk
	ADDITIVE, // the layer's pose, less its clip's own first frame, is added on top: a flinch, a head turn, breathing
}

/*
	A layer's fade in on `play_animation_layer` and out on `stop_animation_layer` or when a one-shot ends. `duration` is the game's (0 snaps);
	`level` and `direction` are state. The layer's strength is `weight` times the level eased (smoothstep, as the base clip's fade is)
*/
Animation_Layer_Fade :: struct {
	duration:f32,
	level:f32, // 0..1, where the fade is now
	direction:int, // +1 in, -1 out, 0 steady
}

/*
	One clip played over part of the base. The playback is `using`, so `animator.layers[1].playing` is how a game sees a one-shot finish.
	`mask` has a weight 0..1 for every skeleton node, copied in by play_animation_layer; 0 leaves a node to the base. A node in the
	mask takes its whole pose from the layer's clip (rest, where the clip has no track for it), so a mask should cover the joints the clip
	is meant to drive. `active` is true from play until the fade-out ends: a game asks `playing` whether the clip is still running and
	`active` whether the layer is in the pose at all
*/
Animation_Layer :: struct {
	using playback:Animation_Playback,
	mode:Animation_Layer_Mode,
	mask:[]f32,
	weight:f32, // 0..1, the game's strength; a game may animate it itself
	fade:Animation_Layer_Fade,
	active:bool,
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
	layer_locals:[MAX_ANIMATION_LAYERS][]Transform, // what each layer's clip says, before it is mixed into `locals`
	layer_first:[MAX_ANIMATION_LAYERS][]Transform, // each layer's clip at its first frame, which an additive layer measures its change from
}

/*
	One character's playback. The playback is `using`, so `animator.playing` and `animator.time` need no
	second name: a game asks whether the animator is playing, not whether its playback is
*/
Animator :: struct {
	using playback:Animation_Playback,
	blend:Animation_Blend,
	pose:Animation_Pose,
	layers:[MAX_ANIMATION_LAYERS]Animation_Layer,
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

	layer_count := clamp(mbi.skin_settings.layer_limit, 0, MAX_ANIMATION_LAYERS)

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

	// A layer is made now, not when it is first played: nothing is allocated mid-frame on a console. Slots past the target's
	// limit get nothing and refuse a play
	for &layer, index in animator.layers {
		layer.playback = idle
		layer.weight = 1
		layer.fade.duration = 0.2
		if index >= layer_count do continue
		layer.mask = make([]f32, node_count)
		animator.pose.layer_locals[index] = make([]Transform, node_count)
		animator.pose.layer_first[index] = make([]Transform, node_count)
	}

	// The bind pose, so a character drawn before its first update is a character rather than a heap of triangles
	copy(animator.pose.locals, model.skeleton.rest)
	resolve_skeleton_pose(model, animator.pose.locals, animator.pose.globals, animator.pose.palettes)
	return animator
}

/*Frees an animator's working arrays. The Model is untouched; several animators share one*/
destroy_animator :: proc(animator:^Animator) {
	for &layer, index in animator.layers {
		delete(layer.mask)
		delete(animator.pose.layer_locals[index])
		delete(animator.pose.layer_first[index])
	}
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

	// Layers on top of the settled base, lowest first, so a higher one wins where two touch the same joint
	for index in 0 ..< len(animator.layers) {
		if animator.layers[index].active do update_animation_layer(animator, model, index, delta_time)
	}

	resolve_skeleton_pose(model, animator.pose.locals, animator.pose.globals, animator.pose.palettes)
}

/*
	One active layer, after the base and its fade have settled into `pose.locals`. A layer with no strength (weight 0, or not yet faded
	in) neither advances its clock nor samples, so a layer a game has switched off costs nothing. The clip is sampled for the masked nodes
	only, and only those are mixed: the cost is the masked joints, not the rig
*/
@(private = "file")
update_animation_layer :: proc(animator:^Animator, model:Model, index:int, delta_time:f32) {
	layer := &animator.layers[index]
	locals := animator.pose.locals
	scratch := animator.pose.layer_locals[index]
	if len(scratch) != len(locals) do return
	if layer.weight <= 0 do return

	fade := &layer.fade
	if fade.direction != 0 {
		if fade.duration <= 0 {
			fade.level = 1 if fade.direction > 0 else 0
		} else {
			fade.level += f32(fade.direction) * delta_time / fade.duration
		}
		if fade.level >= 1 {
			fade.level = 1
			fade.direction = 0
		} else if fade.level <= 0 {
			// Retired after the mix of the last frame it was heard, as the base's fade is: here it has already reached nothing
			layer.active = false
			layer.playing = false
			fade.level = 0
			fade.direction = 0
			return
		}
	}

	level := clamp(fade.level, 0, 1)
	strength := clamp(layer.weight, 0, 1) * level * level * (3 - 2 * level)
	if strength <= 0 do return

	if layer.clip >= 0 && layer.clip < len(model.animations) {
		advance_playback_time(&layer.playback, model.animations[layer.clip].duration, delta_time)
	}
	// A one-shot that has run out leaves the pose over a fade rather than vanishing from it
	if layer.playing == false && fade.direction >= 0 {
		if fade.duration > 0 {
			fade.direction = -1
		} else {
			fade.direction = 0
			layer.active = false
		}
	}

	sample_skeleton_pose_masked(model, layer.clip, layer.time, layer.mask, scratch)
	first := animator.pose.layer_first[index]
	for node in 0 ..< len(locals) {
		weight := layer.mask[node]
		if weight <= 0 do continue
		switch layer.mode {
		case .REPLACE:
			locals[node] = calculate_transform_mix(locals[node], scratch[node], strength * weight)
		case .ADDITIVE:
			locals[node] = calculate_transform_additive(locals[node], scratch[node], first[node], strength * weight)
		}
	}
}

/*
	Plays the clip called `name` on layer `layer` (0 up to the target's `layer_limit`; a higher layer is mixed over a lower one).
	False, with the animator left alone, for a layer out of range, a clip that does not exist or a `mask` of the wrong length. `mask`
	is one weight 0..1 per skeleton node, copied in (build one with calculate_animation_mask_below or _named; a temp one is fine);
	nil means every node for a layer that was not playing, and leaves what a playing layer has. Asking for the clip already playing
	changes only `looping`, `mode` and the mask, so a state machine may call this every frame; a different clip on a playing layer
	snaps to it and keeps the layer's fade. The layer fades in over `layers[layer].fade.duration`
*/
play_animation_layer :: proc(animator:^Animator, model:Model, layer:int, name:string, mask:[]f32 = nil, mode := Animation_Layer_Mode.REPLACE, looping := true) -> bool {
	index, found := get_animation_index(model, name)
	if found == false {
		log.errorf("model has no animation named %q", name)
		return false
	}
	return play_animation_layer_index(animator, model, layer, index, mask, mode, looping)
}

/*The same by clip index*/
play_animation_layer_index :: proc(animator:^Animator, model:Model, layer:int, index:int, mask:[]f32 = nil, mode := Animation_Layer_Mode.REPLACE, looping := true) -> bool {
	if layer < 0 || layer >= len(animator.layers) || len(animator.layers[layer].mask) == 0 {
		log.errorf("no animation layer %d on this animator (limit %d, and a model with no skeleton has none)", layer, mbi.skin_settings.layer_limit)
		return false
	}
	if index < 0 || index >= len(model.animations) do return false

	slot := &animator.layers[layer]
	if mask != nil && len(mask) != len(slot.mask) {
		log.errorf("an animation mask has %d weights, the skeleton has %d nodes", len(mask), len(slot.mask))
		return false
	}

	was_active := slot.active
	if mask != nil {
		copy(slot.mask, mask)
	} else if was_active == false {
		for &weight in slot.mask do weight = 1
	}
	slot.mode = mode
	slot.looping = looping

	fade := &slot.fade
	if was_active && slot.clip == index {
		if fade.direction < 0 do fade.direction = 1 // asked for again while fading out: back in
		return true
	}

	slot.clip = index
	slot.time = 0
	slot.playing = true
	sample_skeleton_pose(model, index, 0, animator.pose.layer_first[layer])

	if was_active {
		if fade.direction < 0 do fade.direction = 1
		return true
	}
	slot.active = true
	if fade.duration > 0 {
		fade.level = 0
		fade.direction = 1
	} else {
		fade.level = 1
		fade.direction = 0
	}
	return true
}

/*Fades a layer out over its `fade.duration`, then it is no longer `active`; with a duration of 0 it is gone at once and the joints go back to the base*/
stop_animation_layer :: proc(animator:^Animator, layer:int) {
	if layer < 0 || layer >= len(animator.layers) do return
	slot := &animator.layers[layer]
	if slot.active == false do return

	if slot.fade.duration > 0 {
		slot.fade.direction = -1
	} else {
		slot.active = false
		slot.playing = false
		slot.fade.level = 0
		slot.fade.direction = 0
	}
}

/*The layer's strength, clamped to 0..1. Its fade is on top of this, so a game ramping the weight and a layer fading in do not fight*/
set_animation_layer_weight :: proc(animator:^Animator, layer:int, weight:f32) {
	if layer < 0 || layer >= len(animator.layers) do return
	animator.layers[layer].weight = clamp(weight, 0, 1)
}

/*Replaces a layer's mask without touching its clip. False for a layer out of range or a mask of the wrong length*/
set_animation_layer_mask :: proc(animator:^Animator, layer:int, mask:[]f32) -> bool {
	if layer < 0 || layer >= len(animator.layers) do return false
	slot := &animator.layers[layer]
	if len(mask) != len(slot.mask) || len(mask) == 0 do return false
	copy(slot.mask, mask)
	return true
}

/*
	A mask for the node `root` (a node index, from get_node_index) and everything under it at weight 1, everything else 0. `falloff` gives
	that many of its ancestors a ramp towards the root, so the seam where the layer meets the base is soft: 3 gives the parent 0.75, its parent
	0.5 and the next 0.25. Worked out from the skeleton on each call and returned from `allocator`, temp by default: play_animation_layer copies
	a mask in, so a game never frees one
*/
calculate_animation_mask_below :: proc(model:Model, root:u32, falloff := 0, allocator := context.temp_allocator) -> []f32 {
	parents := model.skeleton.parents
	mask := make([]f32, len(parents), allocator)
	if int(root) >= len(parents) do return mask

	for node in 0 ..< len(parents) {
		// Up the parents; the count stops a cycle in a broken file
		current := i32(node)
		for _ in 0 ..< len(parents) {
			if current == i32(root) {
				mask[node] = 1
				break
			}
			if current < 0 || int(current) >= len(parents) do break
			current = parents[current]
		}
	}

	ancestor := parents[root]
	for step in 1 ..= falloff {
		if ancestor < 0 || int(ancestor) >= len(parents) do break
		mask[ancestor] = 1 - f32(step) / f32(falloff + 1)
		ancestor = parents[ancestor]
	}
	return mask
}

/*A mask of exactly the named nodes at weight 1. A name the skeleton does not have is logged and left out, like play_animation's*/
calculate_animation_mask_named :: proc(model:Model, names:[]string, allocator := context.temp_allocator) -> []f32 {
	mask := make([]f32, len(model.skeleton.parents), allocator)
	for name in names {
		node, found := get_node_index(model, name)
		if found == false {
			log.errorf("model has no node named %q", name)
			continue
		}
		mask[node] = 1
	}
	return mask
}
