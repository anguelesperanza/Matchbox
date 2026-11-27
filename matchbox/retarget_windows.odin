#+build windows

package matchbox

/*
	Retargeting (PC)
	================
	Plays clips authored for one rig on another: a character modelled one way, a clip library
	made for a differently proportioned skeleton.

		humanoid, _ := mb.map_humanoid_bones(model, mb.UNITY_BONE_NAMES)
		source, ok := mb.load_animation_source("clips.glb", rest_pose_path = "clips_rest.gltf")
		defer mb.destroy_animation_source(source)
		added := mb.retarget_animations(&model, humanoid, source)
		animator := mb.create_animator(model) // the clips are now the model's own: play_animation "Walk"

	The clips are copied onto the model as ordinary Model_Animation data, so the source can be freed
	straight away and an animator plays a retargeted clip exactly as it plays a baked one.

	Windows only. This works at run time on a host with the memory and time for it; a handheld
	plays clips baked into its model file. The maths is in docs/the_game_port_plan.md and vrm.md on `main`.
*/

import "core:log"
import "core:math"
import "core:math/linalg"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strings"

import gltf "./gltf2"

/*
	Clips and the skeleton they were authored against, with no mesh and nothing on the GPU. A whole Model
	was not reused because loading one uploads every part and texture only for a retarget to throw them away
*/
Animation_Source :: struct {
	skeleton:Skeleton,
	animations:[]Model_Animation,
}

/*
	How faithfully a retarget reproduces the source's pose on a rig of different proportions.
	`.PROPORTIONS` is the zero value and so the default: it survives a character holding something in two hands and
	declines to touch a limb that is not holding on to anything
*/
Retarget_Fit :: enum {
	/*
		Joint angles, then a second pass over the arms that restores the gap between the hands where the source holds
		them together. Costs a hierarchy walk per keyframe at retarget time and nothing per frame. Feet are not
		corrected (see HUMANOID_PAIRS)
	*/
	PROPORTIONS,

	/*
		Joint angles alone. One source keyframe becomes one destination keyframe, interpolation intact, and is wrong wherever
		the pose depends on two limbs meeting: narrower shoulders bring both hands in and a grip between them opens up
	*/
	ROTATION_ONLY,
}

/*
	What retarget_animations should do, for a caller who needs to say. Both fields mean something at their zero value,
	so `retarget_animations(&model, humanoid, source)` is the whole call for the common case
*/
Retarget_Options :: struct {
	names:[]Humanoid_Bone_Name, // the source rig's names; empty is UNREAL_BONE_NAMES
	fit:Retarget_Fit,
}

// Tuning of the proportion pass. A constant of struct type rather than loose constants, as BUTTON_STYLE is
@(private)
Retarget_Tuning :: struct {
	contact_near:f32, // gap, in limb lengths, up to which a pair is in contact and corrected fully
	contact_far:f32, // gap, in limb lengths, from which a pair is not in contact and left alone
	shift_rate_limit:f32, // limb lengths per second the correction may change at
}

/*
	Picked from measurements, not tuned. A 0.435m arm: the two-handed pistol hold sits at 0.07m (0.16 limb lengths) and
	corrects fully, the reach for a magazine at 0.38m (0.87) and the idle's hanging arms at 0.45m (1.03) are left alone.
	The rate: the peak the correction was asked to move at was 0.02 to 0.50 on every clip but Pistol_Reload, which asked 5.69 (10.3cm in
	one keyframe). 1.0 has a factor two of headroom over the honest ones and five under the spike
*/
@(private)
RETARGET_TUNING :: Retarget_Tuning{contact_near = 0.30, contact_far = 0.75, shift_rate_limit = 1.0}

// A limb of two bones, named by role so one table serves any rig the humanoid map can describe
@(private)
Retarget_Limb :: struct {
	root:Humanoid_Bone,
	mid:Humanoid_Bone,
	tip:Humanoid_Bone,
}

// Two limbs corrected together, because what needs correcting is the relationship between them
@(private)
Retarget_Pair :: struct {
	left:Retarget_Limb,
	right:Retarget_Limb,
}

// One role resolved on both rigs at once
@(private)
Retarget_Nodes :: struct {
	source:u32,
	destination:u32,
}

/*
	The one pair the correction can name: the arms. **The legs were here and were wrong.** The pass is gated on the gap between the
	*feet*, and measured across the Mesh2Motion export that gap is off by a steady 0.27 to 0.39m, because the scale is the ratio
	of hip heights and where a foot lands is driven by leg length and stance angle. So the pass asked for a stance the angles never
	produced, in every clip: a foot moved up to 16.6cm, 14.9cm between two adjacent keys, a snap in every locomotion clip. Two
	feet hold no constraint with each other; what a foot meets is the ground, a different reference
*/
@(private)
HUMANOID_PAIRS :: []Retarget_Pair {
	{{.LEFT_UPPER_ARM, .LEFT_LOWER_ARM, .LEFT_HAND}, {.RIGHT_UPPER_ARM, .RIGHT_LOWER_ARM, .RIGHT_HAND}},
}

/*
	A clip set and the skeleton it was authored for, from a `.glb`, `.gltf` or `.vrm` at `path` (a real path, not an
	asset name). `ok` is false, with a printed reason, when the file cannot be read or is not glTF

	`rest_pose_path` is for a problem that otherwise ruins a retarget quietly. A retarget transfers a bone's *deviation from
	its rest pose*, which means something only if the two rigs' rest poses depict the same physical pose. A rig exported with its
	animations often stands arms-down with a wide stance where the character it goes onto is a T-pose with its feet under its hips,
	and retargeting across gives a character that walks with its arms out and its legs crossed: correct arithmetic on a false
	premise. Point `rest_pose_path` at the *same rig* in the pose the destination is in and its rest is used instead. Only the rest
	changes; the clips and the node indices their tracks name stay this file's. Matched by node name, and a node the reference
	lacks keeps its own rest
*/
load_animation_source :: proc(path:string, rest_pose_path := "") -> (source:Animation_Source, ok:bool) {
	source.skeleton, source.animations = read_animation_file(path) or_return

	if rest_pose_path != "" {
		reference, reference_animations, reference_ok := read_animation_file(rest_pose_path)
		if reference_ok == false {
			destroy_animation_source(source)
			return {}, false
		}
		defer destroy_animation_source(Animation_Source{reference, reference_animations})

		adopt_rest_pose(&source.skeleton, reference)
	}
	return source, true
}

/*Gives a source's skeleton and clips back. Not in `destroy`: that group is compiled for every target and this is PC only*/
destroy_animation_source :: proc(source:Animation_Source) {
	destroy_skeleton(source.skeleton)
	destroy_model_animations(source.animations)
}

// What load_animation_source reads, twice when given a separate rest pose
@(private)
read_animation_file :: proc(path:string) -> (skeleton:Skeleton, animations:[]Model_Animation, ok:bool) {
	bytes, read_error := os.read_entire_file(path, context.allocator)
	if read_error != nil {
		print("No such animation file:", path)
		return {}, nil, false
	}
	defer delete(bytes)

	extension := filepath.ext(path)
	is_glb := strings.equal_fold(extension, ".glb") || strings.equal_fold(extension, ".vrm")

	file, parse_error := gltf.parse(bytes, {is_glb = is_glb, gltf_dir = filepath.dir(path)})
	if parse_error != nil {
		print("Not a glTF file:", path, parse_error)
		return {}, nil, false
	}
	defer gltf.unload(file)

	return build_gltf_node_skeleton(file), build_gltf_animations(file), true
}

/*
	The node hierarchy and rest pose of a file, with or without a skin. build_gltf_skeleton returns nothing for a file with no
	skins, which is right for a model (a crate has no bones) and wrong here: a rest pose file is a skeleton alone
	and a clip file may have dropped its mesh. Has no skins to give, and needs none: a source is read, not skinned
*/
@(private)
build_gltf_node_skeleton :: proc(file:^gltf.Data) -> Skeleton {
	node_count := len(file.nodes)
	if node_count == 0 do return {}

	skeleton := Skeleton {
		parents = make([]i32, node_count),
		rest = make([]Transform, node_count),
		names = make([]string, node_count),
	}
	for &parent in skeleton.parents do parent = -1

	for node, index in file.nodes {
		for child in node.children {
			if int(child) < node_count do skeleton.parents[child] = i32(index)
		}
		skeleton.names[index] = strings.clone(node.name.? or_else "")
		skeleton.rest[index] = calculate_gltf_node_transform(node)
	}
	skeleton.order = calculate_skeleton_order(skeleton.parents)
	return skeleton
}

/*
	`skeleton`'s rest transforms replaced by those of the same-named nodes of `reference`. Everything else (indices, parents, order)
	stays, so the tracks that name those indices stay valid. A node the reference lacks keeps the rest it had: the reference is
	usually a skeleton-only export and a node with no counterpart is better as authored than zeroed
*/
@(private)
adopt_rest_pose :: proc(skeleton:^Skeleton, reference:Skeleton) {
	if len(reference.rest) == 0 {
		log.error("the rest pose file has no skeleton; keeping the clip file's own rest")
		return
	}

	// By name through a map: eighty nodes against eighty is six thousand string compares done the direct way
	by_name := make(map[string]int, len(reference.names), context.temp_allocator)
	for name, index in reference.names {
		if name == "" do continue
		if _, taken := by_name[name]; taken do continue // first wins, as get_node_index does
		by_name[name] = index
	}

	replaced := 0
	for name, index in skeleton.names {
		if name == "" do continue
		if other, found := by_name[name]; found {
			skeleton.rest[index] = reference.rest[other]
			replaced += 1
		}
	}
	log.infof("adopted a rest pose for %v of %v nodes", replaced, len(skeleton.names))
}

/*
	Every node's rest pose as a global matrix. A retarget compares a source bone's rest orientation with a destination's *in the
	file's own space*, not relative to each one's parent, since two bones with unrelated parent chains only agree on anything once
	both are expressed the same way
*/
@(private)
calculate_skeleton_rest_globals :: proc(skeleton:Skeleton, allocator := context.allocator) -> []matrix[4, 4]f32 {
	globals := make([]matrix[4, 4]f32, len(skeleton.rest), allocator)
	calculate_pose_globals(skeleton, skeleton.rest, globals)
	return globals
}

/*
	Local transforms to global matrices, into a buffer the caller reuses: the proportion pass runs this once per keyframe per clip,
	where allocating per call would be the expensive part of the whole pass
*/
@(private)
calculate_pose_globals :: proc(skeleton:Skeleton, locals:[]Transform, into:[]matrix[4, 4]f32) {
	for node in skeleton.order {
		local := calculate_transform_matrix(locals[node])
		parent := skeleton.parents[node]
		into[node] = local if parent < 0 else into[parent] * local
	}
}

// A global matrix's rotation with its scale divided out, so a rig with a scaled armature still has the rotation it looks like
@(private)
calculate_matrix_rotation :: proc(m:matrix[4, 4]f32) -> quaternion128 {
	column_x := [3]f32{m[0, 0], m[1, 0], m[2, 0]}
	column_y := [3]f32{m[0, 1], m[1, 1], m[2, 1]}
	column_z := [3]f32{m[0, 2], m[1, 2], m[2, 2]}
	scale := [3]f32{linalg.length(column_x), linalg.length(column_y), linalg.length(column_z)}
	if scale.x <= 0 || scale.y <= 0 || scale.z <= 0 do return linalg.QUATERNIONF32_IDENTITY

	rotation := matrix[3, 3]f32 {
		m[0, 0] / scale.x, m[0, 1] / scale.y, m[0, 2] / scale.z,
		m[1, 0] / scale.x, m[1, 1] / scale.y, m[1, 2] / scale.z,
		m[2, 0] / scale.x, m[2, 1] / scale.y, m[2, 2] / scale.z,
	}
	return linalg.quaternion_normalize(linalg.quaternion_from_matrix3(rotation))
}

@(private)
calculate_matrix_position :: proc(m:matrix[4, 4]f32) -> [3]f32 {
	return {m[0, 3], m[1, 3], m[2, 3]}
}

/*
	Copies every clip of `source` onto `model`, rewriting each track to drive the node that plays the same humanoid role,
	and answers how many clips landed at least one track. `humanoid` is the destination's roles (map_humanoid_bones).
	The model keeps the clips it had; a retargeted clip of an existing name is added beside it, not over it

	**Why a track cannot be pointed at another node.** A pose takes a track's value outright, so a rotation track copied
	verbatim would force the destination bone into the *source rig's* rest orientation instead of reproducing its motion. What
	two rigs share is the motion relative to each one's own rest:

		L_d(t) = [ G_d_parent_rest^-1 * G_s_parent_rest ] * L_s(t) * [ G_s_rest^-1 * G_d_rest ]

	Both brackets are constants (rest poses, not clips): worked out once per mapped bone, then applied to every keyframe of every
	clip. A keyframe goes in, one comes out at the same time with the same interpolation

	**Hips translation is its own case**, since position is not rotation-invariant. Every translation track in a Mesh2Motion export is
	on the pelvis, so that node is handled: the pelvis's own `pre` rotation carries the delta from the source's rest position into
	the destination's frame and the ratio of the two hip rest heights absorbs how tall each character is. No hips mapped on either side
	skips it

	**What is dropped.** A destination bone with no source keeps its rest (visible and still, not wrong). A source bone with no
	destination loses its track. A scale track is dropped on every bone, and a translation track on any node but the hips. Counted and
	logged once per call: Quaternius's rig carries both on nearly every bone of every clip

	**Angles are not the whole of a pose.** `options.fit`, `.PROPORTIONS` by default, adds a second pass; see correct_paired_limbs
*/
retarget_animations :: proc(model:^Model, humanoid:Humanoid_Map, source:Animation_Source, options:Retarget_Options = {}) -> (added:int) {
	if is_model_skinned(model^) == false || len(source.skeleton.rest) == 0 do return 0

	// Chosen here rather than as the field's default: a struct's zero value is what `{fit = .ROTATION_ONLY}` leaves in `names`
	names := options.names if len(options.names) > 0 else UNREAL_BONE_NAMES

	destination_globals := calculate_skeleton_rest_globals(model.skeleton, context.temp_allocator)
	source_globals := calculate_skeleton_rest_globals(source.skeleton, context.temp_allocator)
	source_model := Model{skeleton = source.skeleton, animations = source.animations} // for get_node_index and sampling: it reads only these

	source_to_destination := make(map[u32]u32, len(names), context.temp_allocator)
	pre := make(map[u32]quaternion128, len(names), context.temp_allocator)
	post := make(map[u32]quaternion128, len(names), context.temp_allocator)

	// Role to nodes on each side: the proportion pass asks "which node is the left elbow", and this answers directly
	roles := make(map[Humanoid_Bone]Retarget_Nodes, len(names), context.temp_allocator)

	hips_source_node:u32
	has_hips := false
	hips_scale:f32 = 1

	for entry in names {
		source_node, found_source := get_node_index(source_model, entry.name)
		if found_source == false do continue
		destination_node, found_destination := get_humanoid_node(humanoid, entry.bone)
		if found_destination == false || int(destination_node) >= len(model.skeleton.rest) do continue

		source_to_destination[source_node] = destination_node
		roles[entry.bone] = Retarget_Nodes{source = source_node, destination = destination_node}

		source_parent_rotation := linalg.QUATERNIONF32_IDENTITY
		if parent := source.skeleton.parents[source_node]; parent >= 0 {
			source_parent_rotation = calculate_matrix_rotation(source_globals[parent])
		}
		destination_parent_rotation := linalg.QUATERNIONF32_IDENTITY
		if parent := model.skeleton.parents[destination_node]; parent >= 0 {
			destination_parent_rotation = calculate_matrix_rotation(destination_globals[parent])
		}
		source_rest_rotation := calculate_matrix_rotation(source_globals[source_node])
		destination_rest_rotation := calculate_matrix_rotation(destination_globals[destination_node])

		pre[source_node] = linalg.quaternion_inverse(destination_parent_rotation) * source_parent_rotation
		post[source_node] = linalg.quaternion_inverse(source_rest_rotation) * destination_rest_rotation

		if entry.bone == .HIPS {
			hips_source_node = source_node
			has_hips = true
			source_height := source_globals[source_node][1, 3]
			destination_height := destination_globals[destination_node][1, 3]
			if source_height != 0 do hips_scale = destination_height / source_height
		}
	}

	result := make([dynamic]Model_Animation, 0, len(model.animations) + len(source.animations))
	for clip in model.animations do append(&result, clip)

	dropped_translation := 0
	dropped_scale := 0

	for clip in source.animations {
		tracks := make([dynamic]Animation_Track, 0, len(clip.tracks))

		for track in clip.tracks {
			destination_node, mapped := source_to_destination[track.node]
			if mapped == false do continue

			switch track.path {
			case .ROTATION:
				quats := make([]quaternion128, len(track.quats))
				for quat, index in track.quats {
					quats[index] = linalg.quaternion_normalize(pre[track.node] * quat * post[track.node])
				}
				append(&tracks, Animation_Track{node = destination_node, path = .ROTATION, interpolation = track.interpolation, times = slice.clone(track.times), quats = quats})

			case .TRANSLATION:
				if has_hips == false || track.node != hips_source_node {
					dropped_translation += 1
					continue
				}
				source_rest_position := source.skeleton.rest[track.node].position
				destination_rest_position := model.skeleton.rest[destination_node].position

				vectors := make([][3]f32, len(track.vectors))
				for vector, index in track.vectors {
					delta := linalg.quaternion_mul_vector3(pre[track.node], vector - source_rest_position)
					vectors[index] = destination_rest_position + delta * hips_scale
				}
				append(&tracks, Animation_Track{node = destination_node, path = .TRANSLATION, interpolation = track.interpolation, times = slice.clone(track.times), vectors = vectors})

			case .SCALE:
				dropped_scale += 1
			}
		}

		if len(tracks) == 0 {
			delete(tracks)
			continue
		}

		if options.fit == .PROPORTIONS do correct_paired_limbs(model^, source_model, clip, &tracks, roles, hips_scale)

		duration:f32 = 0
		for track in tracks do duration = max(duration, track.times[len(track.times) - 1])
		append(&result, Model_Animation{name = strings.clone(clip.name), duration = duration, tracks = tracks[:]})
		added += 1
	}

	if dropped_translation > 0 {
		log.warnf("retarget_animations: dropped %v translation track(s) on a node other than the mapped hips; only hips translation is retargeted", dropped_translation)
	}
	if dropped_scale > 0 {
		log.warnf("retarget_animations: dropped %v scale track(s); scale retargeting is not supported", dropped_scale)
	}

	// The old slice only; its clips were copied into `result` by value and are the model's still
	delete(model.animations)
	model.animations = result[:]
	return added
}

/*
	Rewrites one retargeted clip's arm tracks so that where the source holds the hands together (two hands on a
	weapon, hands clasped) the destination holds them the same way at its own scale. The count of pairs rewritten

	**Why the conjugation is not enough.** A rotation track carries a joint angle and each limb comes out right relative to its own
	root. No angle carries where the two roots sit relative to each other: with shoulders 9cm narrower, both hands come in with their
	shoulder and the gap between them, which is what a two-handed grip *is*, comes out 5.6cm wrong on the wrong side.

	**So only the gap is corrected.** Each tip moves half the error and both limbs are re-solved onto the result:

		error = scale * (tip_left_source - tip_right_source) - (tip_left_destination - tip_right_destination)

	This is written in world space with no basis change because the conjugation already gave both rigs the same world orientation (`post` and
	its inverse cancel). `scale` is the whole rig's, the ratio of hip heights: a gap is across the body, not along a limb.

	**Two designs measured a tip's offset from a point on the body (the chest, then the midpoint of the two roots) and scaled it.** Both put the
	hand exactly where told and both were wrong on a running character: a rig's placement of a bone inside a torso is the
	rigger's arbitrary choice (the rigs disagree by 6cm), and the source's longer clavicle makes a hanging arm reach back, bent, for the
	distance the shoulder did not travel. A relationship between limbs asks nothing of either limb's own shape.

	A pair the clip does not animate on both sides, or with the hands apart, is left alone (calculate_contact_weight)
*/
@(private)
correct_paired_limbs :: proc(destination:Model, source:Model, source_clip:Model_Animation, tracks:^[dynamic]Animation_Track, roles:map[Humanoid_Bone]Retarget_Nodes, scale:f32, tuning := RETARGET_TUNING) -> (corrected:int) {
	is_limb_mapped :: proc(roles:map[Humanoid_Bone]Retarget_Nodes, limb:Retarget_Limb) -> bool {
		return limb.root in roles && limb.mid in roles && limb.tip in roles
	}

	// A limb the clip never animates is left alone rather than corrected into the source's rest. A clip that drives nothing below the chest still
	// drives nothing below it, so layering it over a walk with calculate_animation_mask_below gets the tracks it always did.
	// Both limbs of a pair, not either: moving the one the clip leaves alone is the same broken promise
	is_limb_animated :: proc(roles:map[Humanoid_Bone]Retarget_Nodes, clip:Model_Animation, limb:Retarget_Limb) -> bool {
		root := roles[limb.root]
		mid := roles[limb.mid]
		for track in clip.tracks {
			if track.path != .ROTATION do continue
			if track.node == root.source || track.node == mid.source do return true
		}
		return false
	}

	pairs := make([dynamic]Retarget_Pair, 0, len(HUMANOID_PAIRS), context.temp_allocator)
	for pair in HUMANOID_PAIRS {
		if is_limb_mapped(roles, pair.left) == false || is_limb_mapped(roles, pair.right) == false do continue
		if is_limb_animated(roles, source_clip, pair.left) == false || is_limb_animated(roles, source_clip, pair.right) == false do continue
		append(&pairs, pair)
	}
	if len(pairs) == 0 do return 0

	limbs := make([dynamic]Retarget_Limb, 0, 2 * len(pairs), context.temp_allocator)
	for pair in pairs {
		append(&limbs, pair.left)
		append(&limbs, pair.right)
	}

	times := calculate_union_times(tracks[:], context.temp_allocator)
	if len(times) == 0 do return 0

	destination_locals := make([]Transform, len(destination.skeleton.rest), context.temp_allocator)
	source_locals := make([]Transform, len(source.skeleton.rest), context.temp_allocator)
	destination_globals := make([]matrix[4, 4]f32, len(destination.skeleton.rest), context.temp_allocator)
	source_globals := make([]matrix[4, 4]f32, len(source.skeleton.rest), context.temp_allocator)

	// The destination's tracks so far, as a one-clip model, so a part-built clip samples through the same code a playing one does
	partial := [1]Model_Animation{{tracks = tracks[:]}}
	destination_partial := Model{skeleton = destination.skeleton, animations = partial[:]}
	source_clips := [1]Model_Animation{source_clip}
	source_single := Model{skeleton = source.skeleton, animations = source_clips[:]}

	// Root and mid keys per limb, one per sample time. Filled in the time loop and written after it, since a track cannot be
	// rewritten while the pose it is being read from is still being sampled
	root_keys := make([][]quaternion128, len(limbs), context.temp_allocator)
	mid_keys := make([][]quaternion128, len(limbs), context.temp_allocator)
	for index in 0 ..< len(limbs) {
		root_keys[index] = make([]quaternion128, len(times))
		mid_keys[index] = make([]quaternion128, len(times))
	}

	// Last keyframe's shift per pair, for calculate_limited_shift. Per pair, not per limb: both are moved by one vector with opposite
	// signs, and clamping each side separately could let them disagree about how much of the gap was closed
	previous_shift := make([][3]f32, len(pairs), context.temp_allocator)

	// Last keyframe's bend plane per limb, carried forward so a limb passing through straight keeps its joint on its side
	planes := make([][3]f32, len(limbs), context.temp_allocator)

	// A clip whose hands are never near each other leaves with the tracks it arrived with, not a re-baked copy on a denser time line
	touched := make([]bool, len(pairs), context.temp_allocator)

	for time, key in times {
		sample_skeleton_pose(source_single, 0, time, source_locals)
		sample_skeleton_pose(destination_partial, 0, time, destination_locals)
		calculate_pose_globals(source.skeleton, source_locals, source_globals)
		calculate_pose_globals(destination.skeleton, destination_locals, destination_globals)

		for pair, p in pairs {
			left_tip := roles[pair.left.tip]
			right_tip := roles[pair.right.tip]

			// Half the error each, faded out as the tips separate: neither limb is singled out as the one that was wrong
			want := scale * (calculate_matrix_position(source_globals[left_tip.source]) - calculate_matrix_position(source_globals[right_tip.source]))
			have := calculate_matrix_position(destination_globals[left_tip.destination]) - calculate_matrix_position(destination_globals[right_tip.destination])

			reach := calculate_limb_reach(destination_globals, roles, pair.left)
			shift := 0.5 * calculate_contact_weight(linalg.length(want), reach, tuning) * (want - have)
			if key > 0 do shift = calculate_limited_shift(previous_shift[p], shift, time - times[key - 1], reach, tuning)
			previous_shift[p] = shift

			for limb, side in ([]Retarget_Limb{pair.left, pair.right}) {
				index := 2 * p + side
				root := roles[limb.root]
				mid := roles[limb.mid]
				tip := roles[limb.tip]

				root_position := calculate_matrix_position(destination_globals[root.destination])
				mid_position := calculate_matrix_position(destination_globals[mid.destination])
				tip_position := calculate_matrix_position(destination_globals[tip.destination])

				// Nothing to correct here: keep what the angles said, to the bit. Re-solving a chain onto where it already is
				// is not free: a straight limb has no plane to read, so the solve puts its joint in whatever plane the fallback picked
				if linalg.length(shift) <= 1e-7 {
					root_keys[index][key] = destination_locals[root.destination].rotation
					mid_keys[index][key] = destination_locals[mid.destination].rotation

					// The hint keeps up all the same. A stale plane from before the limb moved, handed to the solve when the pair
					// comes back into contact with the chain straight, puts the joint on the wrong side: the knee-swing this pass
					// fixed once and which came back through the door marked "nothing to do here"
					planes[index] = calculate_bend_plane(root_position, mid_position, tip_position, planes[index])
					continue
				}
				touched[p] = true

				target := tip_position + (shift if side == 0 else -shift)
				root_turn, mid_turn, plane := calculate_two_bone_turns(root_position, mid_position, tip_position, target, planes[index])
				planes[index] = plane

				root_world := root_turn * calculate_matrix_rotation(destination_globals[root.destination])
				mid_world := mid_turn * calculate_matrix_rotation(destination_globals[mid.destination])

				// Back to locals. The mid bone's is taken against the root's *new* world rotation: turning the root already carried the mid bone with
				// it, so measuring against the old parent applies the root's correction twice. Off by exactly that much is not obviously
				// wrong on screen, which is how it survives: the limb reaches roughly where it should and misses by centimetres
				parent_rotation := linalg.QUATERNIONF32_IDENTITY
				if parent := destination.skeleton.parents[root.destination]; parent >= 0 {
					parent_rotation = calculate_matrix_rotation(destination_globals[parent])
				}
				root_keys[index][key] = linalg.quaternion_inverse(parent_rotation) * root_world
				mid_keys[index][key] = linalg.quaternion_inverse(root_world) * mid_world
			}
		}
	}

	for pair, p in pairs {
		if touched[p] {
			for limb, side in ([]Retarget_Limb{pair.left, pair.right}) {
				index := 2 * p + side
				set_rotation_track(tracks, roles[limb.root].destination, times, root_keys[index])
				set_rotation_track(tracks, roles[limb.mid].destination, times, mid_keys[index])
			}
			corrected += 1
		} else {
			for side in 0 ..< 2 {
				delete(root_keys[2 * p + side])
				delete(mid_keys[2 * p + side])
			}
		}
	}
	return corrected
}

/*
	World-space turns for a two-bone chain that put `tip` on `target`, keeping the plane the chain is bent in. The second
	turn includes the first, so each is applied to its bone's own world rotation and the caller need not know the order

	**Built by placing the joints and reading the rotations back off**, not by accumulating law-of-cosines deltas: the delta form
	needs a signed bend axis from a cross product of the current pose, which flips between a left limb and a right one, or when a limb passes
	through straight. Placing two points has no sign to get wrong. On Pistol_Reload it is 0.00cm from the target on every frame where the delta form
	sat 3.25cm out on average. Only swings are produced, so the twist the conjugation put in the forearm survives
*/
@(private)
calculate_two_bone_turns :: proc(root, mid, tip, target:[3]f32, hint:[3]f32 = {}) -> (root_turn, mid_turn:quaternion128, normal:[3]f32) {
	identity := linalg.QUATERNIONF32_IDENTITY
	upper := linalg.length(mid - root)
	lower := linalg.length(tip - mid)
	if upper <= 0 || lower <= 0 do return identity, identity, hint

	reach := linalg.length(target - root)
	if reach <= 1e-6 do return identity, identity, hint

	// Further than both bones end to end is out of reach, nearer than their difference is inside the fold: clamp to the nearest pose it can hold
	span := clamp(reach, abs(upper - lower) + 1e-6, upper + lower - 1e-6)
	direction := (target - root) / reach

	normal = calculate_bend_plane(root, mid, tip, hint)
	if linalg.length(normal) <= 0 do return identity, identity, hint

	// In the bend plane, square to the target direction, pointing the way the joint already sticks out
	pole := linalg.cross(direction, normal)
	if linalg.length(pole) < 1e-6 do return identity, identity, normal
	pole = linalg.normalize(pole)

	cosine := clamp((upper * upper + span * span - lower * lower) / (2 * upper * span), -1, 1)
	sine := math.sqrt(max(0, 1 - cosine * cosine))

	new_mid := root + upper * (cosine * direction + sine * pole)
	new_tip := root + span * direction

	root_turn = calculate_rotation_between(mid - root, new_mid - root)
	mid_turn = calculate_rotation_between(linalg.quaternion_mul_vector3(root_turn, tip - mid), new_tip - new_mid) * root_turn
	return root_turn, mid_turn, normal
}

/*
	How much of a pair's gap error to correct, given how far apart the source holds the tips and how long the limb is. **The difference
	between fixing a grip and wrecking an idle.** What a rotation retarget gets wrong is the relationship of a pair, and that only
	matters where the relationship is contact. Corrected everywhere, the arm is made to travel distance the shoulder should have:
	on this VRM's idle that reaches the arm 10cm backwards, bent, and reads as "the right hand is behind the character"

	Contact is not recorded in a glTF, so it is inferred from the one signal there is: how close the source holds the tips, in limb
	lengths, so it means the same on a child and an ogre. Smooth rather than a threshold, as it is evaluated per keyframe and a
	step in it is a step in the pose; smoothstep's flat ends keep a pose hovering at the boundary from shimmering
*/
@(private)
calculate_contact_weight :: proc(gap, limb_length:f32, tuning := RETARGET_TUNING) -> f32 {
	if limb_length <= 0 do return 1

	near := tuning.contact_near * limb_length
	far := tuning.contact_far * limb_length
	if gap <= near do return 1
	if gap >= far do return 0

	t := (gap - near) / (far - near)
	return 1 - t * t * (3 - 2 * t)
}

/*
	`wanted`, held back to a speed a limb could plausibly move at. It clamps the *change*, so a correction already large and steady (a
	grip held for a whole clip) is untouched and only the moment it appears or vanishes is spread out; direction is kept and only its length
	cut. Trailing by design: after a fast separation it corrects a few keyframes longer than the weight alone would, and a grip
	that releases late reads as a hand lingering where one that releases instantly reads as a snap
*/
@(private)
calculate_limited_shift :: proc(previous, wanted:[3]f32, delta_time, limb_length:f32, tuning := RETARGET_TUNING) -> [3]f32 {
	if delta_time <= 0 || limb_length <= 0 do return wanted

	step := wanted - previous
	distance := linalg.length(step)
	limit := tuning.shift_rate_limit * limb_length * delta_time
	if distance <= limit do return wanted
	return previous + step * (limit / distance)
}

// A limb's length in the pose it is in, root to mid to tip: the yardstick a gap is measured against
@(private)
calculate_limb_reach :: proc(globals:[]matrix[4, 4]f32, roles:map[Humanoid_Bone]Retarget_Nodes, limb:Retarget_Limb) -> f32 {
	root := calculate_matrix_position(globals[roles[limb.root].destination])
	mid := calculate_matrix_position(globals[roles[limb.mid].destination])
	tip := calculate_matrix_position(globals[roles[limb.tip].destination])
	return linalg.length(mid - root) + linalg.length(tip - mid)
}

/*
	The plane a two-bone chain is bent in, as its normal: which way the elbow or knee points, the one thing about the pose a position
	target does not determine. **Taken from the chain's own geometry, not from its offset perpendicular to the target**: that form
	collapses whenever the target lines up with the upper bone, which happens mid-stride with the knee still bent, and what is left is noise with a
	direction. The knee swung around the leg: 10.6cm between two keys on Walk_Formal where the source moved 3.9cm.

	`cross(upper, root_to_tip)` only collapses when the chain really is straight, and a straight chain has no plane, so the previous keyframe's
	answer (`hint`) is carried forward: the joint stays where it was through straightness rather than picking a new side on the way out
*/
@(private)
calculate_bend_plane :: proc(root, mid, tip:[3]f32, hint:[3]f32) -> [3]f32 {
	upper := mid - root
	span := tip - root
	normal := linalg.cross(upper, span)

	// The sine of the angle at the joint: "how straight", not "how long", or a small limb would be called straight and a large one bent at the same angle
	scale := linalg.length(upper) * linalg.length(span)
	if scale > 0 && linalg.length(normal) / scale > 0.02 do return linalg.normalize(normal)

	if linalg.length(hint) > 0 do return hint

	// Nothing to go on: the first key of a clip that opens with a straight limb. Any plane containing it will do
	fallback := linalg.cross(span, [3]f32{0, 0, 1})
	if linalg.length(fallback) < 1e-6 do fallback = linalg.cross(span, [3]f32{0, 1, 0})
	if linalg.length(fallback) < 1e-6 do return {}
	return linalg.normalize(fallback)
}

// The shortest turn taking `from`'s direction onto `to`'s. The antiparallel case is why it is written out: the cross product vanishes there, so the axis is picked
@(private)
calculate_rotation_between :: proc(from, to:[3]f32) -> quaternion128 {
	a := linalg.normalize0(from)
	b := linalg.normalize0(to)
	if linalg.length(a) <= 0 || linalg.length(b) <= 0 do return linalg.QUATERNIONF32_IDENTITY

	cosine := clamp(linalg.dot(a, b), -1, 1)
	if cosine > 0.999999 do return linalg.QUATERNIONF32_IDENTITY

	if cosine < -0.999999 {
		axis := linalg.cross(a, [3]f32{1, 0, 0})
		if linalg.length(axis) < 1e-6 do axis = linalg.cross(a, [3]f32{0, 1, 0})
		return linalg.quaternion_angle_axis_f32(math.PI, linalg.normalize(axis))
	}
	return linalg.quaternion_angle_axis_f32(math.acos(cosine), linalg.normalize(linalg.cross(a, b)))
}

/*
	Every distinct time any of `tracks` has a key at, in order: the proportion pass needs a whole limb at one instant, so one time line
	rather than each track's own. Free on the Mesh2Motion export, where a clip has at most two distinct time arrays (a dense one and
	a two-key one) so the union is the dense array and its endpoints; a fixed-rate resample would have thrown away fidelity it did not need to lose
*/
@(private)
calculate_union_times :: proc(tracks:[]Animation_Track, allocator := context.allocator) -> []f32 {
	gathered := make([dynamic]f32, context.temp_allocator)
	for track in tracks do append(&gathered, ..track.times)
	slice.sort(gathered[:])

	out := make([dynamic]f32, 0, len(gathered), allocator)
	for time in gathered {
		if len(out) > 0 && out[len(out) - 1] == time do continue
		append(&out, time)
	}
	return out[:]
}

// Puts `quats` on the track driving `node`'s rotation, replacing what was there: two rotation tracks on one node are not a blend, the second silently wins
@(private)
set_rotation_track :: proc(tracks:^[dynamic]Animation_Track, node:u32, times:[]f32, quats:[]quaternion128) {
	for &track in tracks {
		if track.node != node || track.path != .ROTATION do continue

		delete(track.times)
		delete(track.quats)
		track.times = slice.clone(times)
		track.quats = quats
		track.interpolation = .LINEAR
		return
	}
	append(tracks, Animation_Track{node = node, path = .ROTATION, interpolation = .LINEAR, times = slice.clone(times), quats = quats})
}
