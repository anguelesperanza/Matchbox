package matchbox

/*
	Skeleton
	========
	What a skinned model carries besides its meshes, and the maths that turns a pose into the
	matrices a skinning vertex shader needs. Shared by every target and free of any GPU object, so
	the tests check the numbers on a machine with no graphics. Ported from main's animation3d.odin
	(G6); the playback that drives it is animator.odin.

	The split is the one the cameras use. A `Model` holds what came out of the file and never
	changes: the skeleton's rest pose, its hierarchy and the clips. An `Animator` holds one
	character's playback. Two goblins share one Model and have an Animator each.

	The 2D sprite animation owns the plain names (`Animation_Clip`, `update_animation`), so the
	skeletal ones are `Model_Animation` and `update_animator`.
*/

import "core:math"
import "core:math/linalg"

/*Which part of a joint's transform a track drives. glTF's fourth path, `weights`, drives morph targets, which Matchbox skips*/
Animation_Path :: enum {
	TRANSLATION,
	ROTATION,
	SCALE,
}

/*
	How a track gets from one keyframe to the next. All three of glTF's, because a file picks per
	sampler and mixes them freely: the VRoid and Mesh2Motion exports this was written against are
	STEP channels from end to end
*/
Animation_Interpolation :: enum {
	LINEAR,
	STEP,
	CUBIC,
}

/*
	One node's worth of one channel: the times and the values at them. Rotations live in `quats` and
	everything else in `vectors`, because a rotation is slerped and a translation lerped and the
	two were never going to share code. Under `.CUBIC` there are three values per keyframe
	(in-tangent, value, out-tangent), so the arrays are three times as long as `times`
*/
Animation_Track :: struct {
	node:u32,
	path:Animation_Path,
	interpolation:Animation_Interpolation,
	times:[]f32,
	vectors:[][3]f32,
	quats:[]quaternion128,
}

/*One clip: everything that moves, and how long it runs*/
Model_Animation :: struct {
	name:string,
	duration:f32,
	tracks:[]Animation_Track,
}

/*
	One skin: which nodes are its joints, and the matrix that takes each joint back to the pose the
	mesh was modelled in. `joints` is an index into the skeleton's nodes, and the position in this
	array is what a vertex's JOINTS_0 refers to. The two are different numbers, and confusing them is
	the classic skinning bug: a character folded inside out
*/
Model_Skin :: struct {
	joints:[]u32,
	inverse_bind:[]matrix[4, 4]f32,
}

/*
	The node hierarchy a model's animation moves. `rest` is the transform each node has in the file
	before any clip touches it, and is what a pose starts from every frame: a clip that drives only
	the arms leaves the legs at rest rather than at the origin. `order` is the nodes sorted so a
	parent comes before its children; glTF does not promise that and a global transform needs it.
	`names` is indexed like `parents`, "" for a node the file left unnamed
*/
Skeleton :: struct {
	parents:[]i32, // -1 for a root
	rest:[]Transform,
	order:[]u32,
	names:[]string,
	skins:[]Model_Skin,
}

/*Whether a model has a skeleton at all. A cube does not*/
is_model_skinned :: proc(model:Model) -> bool {
	return len(model.skeleton.rest) > 0 && len(model.skeleton.skins) > 0
}

/*Frees what a loader made for the skeleton and the clips*/
destroy_skeleton :: proc(skeleton:Skeleton) {
	delete(skeleton.parents)
	delete(skeleton.rest)
	delete(skeleton.order)
	for name in skeleton.names do delete(name)
	delete(skeleton.names)
	for skin in skeleton.skins {
		delete(skin.joints)
		delete(skin.inverse_bind)
	}
	delete(skeleton.skins)
}

destroy_model_animations :: proc(animations:[]Model_Animation) {
	for clip in animations {
		delete(clip.name)
		for track in clip.tracks {
			delete(track.times)
			delete(track.vectors)
			delete(track.quats)
		}
		delete(clip.tracks)
	}
	delete(animations)
}

/*Parents before children: the order a global transform needs. A cycle (a broken file) leaves the nodes in it out*/
calculate_skeleton_order :: proc(parents:[]i32, allocator := context.allocator) -> []u32 {
	order := make([dynamic]u32, 0, len(parents), allocator)
	placed := make([]bool, len(parents), context.temp_allocator)

	// Repeated sweeps rather than a recursion: a deep rig costs a few passes and cannot overflow the stack
	progress := true
	for progress {
		progress = false
		for node in 0 ..< len(parents) {
			if placed[node] do continue
			parent := parents[node]
			if parent < 0 || (int(parent) < len(parents) && placed[parent]) {
				placed[node] = true
				append(&order, u32(node))
				progress = true
			}
		}
	}
	return order[:]
}

/*
	Writes one playback's pose into `into`, from the rest pose every time rather than from what was
	there before: a clip drives some joints and not others, and the ones it leaves alone belong where
	the file put them. Accumulating instead would let them drift
*/
sample_skeleton_pose :: proc(model:Model, clip:int, time:f32, into:[]Transform) {
	copy(into, model.skeleton.rest)
	if clip < 0 || clip >= len(model.animations) do return

	for track in model.animations[clip].tracks {
		if int(track.node) >= len(into) do continue
		sample_track(track, time, &into[track.node])
	}
}

/*One transform part-way between two others: slerp for rotation (a component-wise mix takes the chord and shortens a limb), lerp for the rest*/
calculate_transform_mix :: proc(a, b:Transform, t:f32) -> Transform {
	return Transform {
		position = linalg.lerp(a.position, b.position, t),
		rotation = linalg.quaternion_slerp_f32(a.rotation, b.rotation, t),
		scale = linalg.lerp(a.scale, b.scale, t),
	}
}

/*
	Local transforms to global matrices, then to each part's palette. A palette entry is
	`inverse(mesh node's global) * joint's global * joint's inverse bind`, glTF's formula in full. The
	first factor is the identity in most files and not in all. `palettes[i]` belongs to
	`model.parts[i]`, in the order of that part's `joint_map`; a slot that cannot be resolved stays the
	identity, which leaves its vertices where they are (a zero matrix would collapse them)
*/
resolve_skeleton_pose :: proc(model:Model, locals:[]Transform, globals:[]matrix[4, 4]f32, palettes:[][]matrix[4, 4]f32) {
	skeleton := model.skeleton

	for node in skeleton.order {
		local := calculate_transform_matrix(locals[node])
		parent := skeleton.parents[node]
		if parent < 0 {
			globals[node] = local
		} else {
			globals[node] = globals[parent] * local
		}
	}

	for part, index in model.parts {
		if part.mesh.skinned == false || part.skin < 0 || part.skin >= len(skeleton.skins) do continue
		if len(palettes[index]) == 0 do continue

		skin := skeleton.skins[part.skin]
		mesh_inverse := linalg.MATRIX4F32_IDENTITY
		if part.mesh_node >= 0 && part.mesh_node < len(globals) {
			mesh_inverse = linalg.inverse(globals[part.mesh_node])
		}

		for slot in 0 ..< len(palettes[index]) do palettes[index][slot] = linalg.MATRIX4F32_IDENTITY

		// Indexed by the part's compact slot, not the skin's joint number: `joint_map` turns one into the other
		for joint, slot in part.joint_map {
			if int(joint) >= len(skin.joints) do continue
			node := skin.joints[joint]
			if int(node) >= len(globals) do continue
			palettes[index][slot] = mesh_inverse * globals[node] * skin.inverse_bind[joint]
		}
	}
}

/*
	The keyframe at or before `time` and how far past it: the left key's index and a 0..1 blend to the
	next. Before the first key or after the last it clamps, as glTF asks. Bisects: a linear search
	for sixty-six tracks a frame is a millisecond nobody asked for
*/
calculate_track_frame :: proc(times:[]f32, time:f32) -> (index:int, blend:f32) {
	if len(times) <= 1 do return 0, 0
	if time <= times[0] do return 0, 0
	if time >= times[len(times) - 1] do return len(times) - 1, 0

	low, high := 0, len(times) - 1
	for high - low > 1 {
		mid := (low + high) / 2
		if times[mid] <= time {
			low = mid
		} else {
			high = mid
		}
	}

	span := times[high] - times[low]
	if span <= 0 do return low, 0
	return low, (time - times[low]) / span
}

// Hermite, which is what glTF's CUBICSPLINE is. `span` scales the tangents because they are given per second
@(private = "file")
hermite :: proc(v0, out_tangent, v1, in_tangent:[3]f32, t, span:f32) -> [3]f32 {
	t2 := t * t
	t3 := t2 * t
	return (2 * t3 - 3 * t2 + 1) * v0 + (t3 - 2 * t2 + t) * span * out_tangent + (-2 * t3 + 3 * t2) * v1 + (t3 - t2) * span * in_tangent
}

@(private = "file")
sample_track :: proc(track:Animation_Track, time:f32, into:^Transform) {
	if len(track.times) == 0 do return

	index, blend := calculate_track_frame(track.times, time)
	next := min(index + 1, len(track.times) - 1)

	switch track.path {
	case .ROTATION:
		if len(track.quats) == 0 do return

		switch track.interpolation {
		case .STEP:
			into.rotation = track.quats[index]
		case .CUBIC:
			// The value elements either side, slerped. The tangents are dropped: a cubic spline through
			// quaternions is not the shape of one through their components, and no exporter tested writes it
			into.rotation = linalg.quaternion_slerp_f32(track.quats[index * 3 + 1], track.quats[next * 3 + 1], blend)
		case .LINEAR:
			into.rotation = linalg.quaternion_slerp_f32(track.quats[index], track.quats[next], blend)
		}

	case .TRANSLATION, .SCALE:
		if len(track.vectors) == 0 do return

		value:[3]f32
		switch track.interpolation {
		case .STEP:
			value = track.vectors[index]
		case .CUBIC:
			span := track.times[next] - track.times[index]
			value = hermite(track.vectors[index * 3 + 1], track.vectors[index * 3 + 2], track.vectors[next * 3 + 1], track.vectors[next * 3 + 0], blend, span)
		case .LINEAR:
			value = linalg.lerp(track.vectors[index], track.vectors[next], blend)
		}

		if track.path == .TRANSLATION {
			into.position = value
		} else {
			into.scale = value
		}
	}
}

/*
	A clip's time moved on by `delta_time * speed`, wrapped when it loops. `mod` rather than a subtract,
	so a long stall or a big speed does not leave the time several clips past the end. A one-shot stops
	on its last pose with `playing` false
*/
advance_playback_time :: proc(playback:^Animation_Playback, duration:f32, delta_time:f32) {
	if playback.playing == false do return

	playback.time += delta_time * playback.speed

	if playback.looping {
		if duration > 0 {
			playback.time = math.mod(playback.time, duration)
			if playback.time < 0 do playback.time += duration
		}
	} else if playback.time >= duration {
		playback.time = duration
		playback.playing = false
	} else if playback.time < 0 {
		playback.time = 0
		playback.playing = false
	}
}
