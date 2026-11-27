#+build windows

package matchbox

import "core:math"
import "core:math/linalg"
import "core:os"
import "core:path/filepath"
import "core:testing"

/*
	Retargeting, against numbers that did not come from this code. Two kinds:

	- A pair of rigs built by hand, small enough to check on paper, with expected values from numpy using rotation *matrices*
	  where retarget_windows.odin uses quaternions (the snippet is in the comment on `retarget_a_hand_built_pair`).
	- The game's own files (psx_humanoid_male.glb, retargeted_animations.glb and the rest pose), with expected world positions from
	  tools/verify_retarget.py, which parses the glTF itself. Those files are not in this repository, so the test runs only
	  when MATCHBOX_THE_GAME_CHARACTERS names the folder holding them and otherwise says so and passes

	None of it touches the GPU: a Model is built by hand from the loaded data, which is all an animator reads
*/

@(private = "file")
make_skeleton :: proc(names:[]string, parents:[]i32, rest:[]Transform) -> Skeleton {
	skeleton := Skeleton {
		parents = parents,
		rest = rest,
		names = names,
		skins = make([]Model_Skin, 1, context.temp_allocator), // is_model_skinned wants a skin; nothing here reads it
	}
	skeleton.order = calculate_skeleton_order(parents, context.temp_allocator)
	return skeleton
}

@(private = "file")
axis_rotation :: proc(axis:[3]f32, degrees:f32) -> quaternion128 {
	return linalg.quaternion_angle_axis_f32(math.to_radians(degrees), linalg.normalize(axis))
}

// Quaternions are the same rotation either way round, so compare them with the sign of w fixed
@(private = "file")
expect_rotation :: proc(t:^testing.T, label:string, got:quaternion128, want:[4]f32) {
	g := [4]f32{imag(got), jmag(got), kmag(got), real(got)}
	if g.w < 0 do g = -g
	for i in 0 ..< 4 {
		testing.expectf(t, abs(g[i] - want[i]) < 1e-5, "%s: got %v, numpy says %v", label, g, want)
		if abs(g[i] - want[i]) >= 1e-5 do break
	}
}

/*
	Source: root (yaw 90 degrees) > pelvis at (0, 1, 0) > thigh_l at (0.1, 0, 0) rolled 20 about X.
	Destination: Hips at (0, 1.2, 0) > LeftUpperLeg at (0.12, 0, 0) turned 10 about Y.
	Clip: pelvis rotated 30 about X, thigh_l 40 about Y, pelvis moved to (0, 1.1, 0.2), two keys each (t = 0 and 1).

	numpy, with L_d = inverse(Rp_d) Rp_s L_s inverse(R_s) R_d on 3x3 rotation matrices:
		hips  -> (0, 0, -0.258819, 0.965926)        thigh -> (0.044943, 0.416198, 0.167731, 0.892539)
		hips position -> (0.24, 1.32, 0): dst rest + (Rp_s (v - rest)) * 1.2, and 1.2 is 1.2 / 1.0, the hip heights
*/
@(test)
retarget_a_hand_built_pair :: proc(t:^testing.T) {
	context.allocator = context.temp_allocator
	source_names := []string{"root", "pelvis", "thigh_l"}
	source_rest := []Transform {
		{rotation = axis_rotation({0, 1, 0}, 90), scale = 1},
		{position = {0, 1, 0}, rotation = linalg.QUATERNIONF32_IDENTITY, scale = 1},
		{position = {0.1, 0, 0}, rotation = axis_rotation({1, 0, 0}, 20), scale = 1},
	}
	times := []f32{0, 1}
	clip := Model_Animation {
		name = "Bend",
		duration = 1,
		tracks = {
			{node = 1, path = .ROTATION, interpolation = .LINEAR, times = times, quats = {axis_rotation({1, 0, 0}, 30), axis_rotation({1, 0, 0}, 30)}},
			{node = 2, path = .ROTATION, interpolation = .LINEAR, times = times, quats = {axis_rotation({0, 1, 0}, 40), axis_rotation({0, 1, 0}, 40)}},
			{node = 1, path = .TRANSLATION, interpolation = .LINEAR, times = times, vectors = {{0, 1.1, 0.2}, {0, 1.1, 0.2}}},
			{node = 1, path = .SCALE, interpolation = .LINEAR, times = times, vectors = {{1, 1, 1}, {1, 1, 1}}}, // dropped
			{node = 0, path = .ROTATION, interpolation = .LINEAR, times = times, quats = {linalg.QUATERNIONF32_IDENTITY, linalg.QUATERNIONF32_IDENTITY}}, // the root is no humanoid role: dropped
		},
	}
	source := Animation_Source {
		skeleton = make_skeleton(source_names, {-1, 0, 1}, source_rest),
		animations = {clip},
	}

	model := Model {
		skeleton = make_skeleton(
			{"Hips", "LeftUpperLeg"},
			{-1, 0},
			{{position = {0, 1.2, 0}, rotation = linalg.QUATERNIONF32_IDENTITY, scale = 1}, {position = {0.12, 0, 0}, rotation = axis_rotation({0, 1, 0}, 10), scale = 1}},
		),
	}
	humanoid, mapped := map_humanoid_bones(model, UNITY_BONE_NAMES)
	testing.expect_value(t, mapped, 2)

	added := retarget_animations(&model, humanoid, source, Retarget_Options{fit = .ROTATION_ONLY})
	testing.expect_value(t, added, 1)
	if testing.expect_value(t, len(model.animations), 1) == false do return
	testing.expect_value(t, model.animations[0].name, "Bend")
	testing.expect_value(t, model.animations[0].duration, 1)
	testing.expect_value(t, len(model.animations[0].tracks), 3) // two rotations and the hips translation

	locals := make([]Transform, 2)
	sample_skeleton_pose(model, 0, 0.5, locals)
	expect_rotation(t, "hips", locals[0].rotation, {0, 0, -0.258819, 0.965926})
	expect_rotation(t, "left thigh", locals[1].rotation, {0.044943, 0.416198, 0.167731, 0.892539})
	expected_position := [3]f32{0.24, 1.32, 0}
	for got, axis in locals[0].position {
		want := expected_position[axis]
		testing.expectf(t, abs(got - want) < 1e-5, "hips position axis %d is %v, numpy says %v", axis, got, want)
	}
}

@(test)
a_rig_with_none_of_the_names_maps_nothing_and_retargets_nothing :: proc(t:^testing.T) {
	context.allocator = context.temp_allocator
	model := Model{skeleton = make_skeleton({"a", "b"}, {-1, 0}, {{scale = 1, rotation = linalg.QUATERNIONF32_IDENTITY}, {scale = 1, rotation = linalg.QUATERNIONF32_IDENTITY}})}
	humanoid, mapped := map_humanoid_bones(model, UNITY_BONE_NAMES)
	testing.expect_value(t, mapped, 0)

	source := Animation_Source{skeleton = make_skeleton({"pelvis"}, {-1}, {{scale = 1, rotation = linalg.QUATERNIONF32_IDENTITY}}), animations = {{name = "Idle", tracks = {}}}}
	testing.expect_value(t, retarget_animations(&model, humanoid, source), 0)
	testing.expect_value(t, len(model.animations), 0)

	_, found := get_humanoid_node(humanoid, .HIPS)
	testing.expect(t, found == false, "an unmapped role is not node 0")
}

@(test)
a_rest_pose_file_replaces_the_rest_of_the_same_named_nodes_only :: proc(t:^testing.T) {
	context.allocator = context.temp_allocator
	identity := linalg.QUATERNIONF32_IDENTITY
	skeleton := make_skeleton({"a", "b", "only_here"}, {-1, 0, 0}, {{position = {1, 0, 0}, rotation = identity, scale = 1}, {position = {2, 0, 0}, rotation = identity, scale = 1}, {position = {3, 0, 0}, rotation = identity, scale = 1}})
	reference := make_skeleton({"b", "a"}, {-1, 0}, {{position = {20, 0, 0}, rotation = identity, scale = 1}, {position = {10, 0, 0}, rotation = identity, scale = 1}})

	adopt_rest_pose(&skeleton, reference)
	testing.expect_value(t, skeleton.rest[0].position, [3]f32{10, 0, 0}) // by name, not by index
	testing.expect_value(t, skeleton.rest[1].position, [3]f32{20, 0, 0})
	testing.expect_value(t, skeleton.rest[2].position, [3]f32{3, 0, 0}) // no counterpart: as authored
}

/*The elbow solve is checked geometrically, which is independent of how it is built: placing the bones with the returned turns must put the wrist on the target, with both bone lengths kept*/
@(test)
the_two_bone_solve_puts_the_tip_on_the_target_and_keeps_the_bones_their_length :: proc(t:^testing.T) {
	root := [3]f32{0, 0, 0}
	mid := [3]f32{0.3, -0.1, 0.05}
	tip := [3]f32{0.55, 0.1, 0.1}
	for target in ([][3]f32{{0.4, 0.2, 0.2}, {0.2, -0.3, 0.1}, {-0.3, 0.1, 0.3}}) {
		root_turn, mid_turn, normal := calculate_two_bone_turns(root, mid, tip, target)
		testing.expect(t, linalg.length(normal) > 0, "a bent chain has a plane")

		new_mid := root + linalg.quaternion_mul_vector3(root_turn, mid - root)
		new_tip := new_mid + linalg.quaternion_mul_vector3(mid_turn, tip - mid)
		testing.expectf(t, linalg.length(new_tip - target) < 1e-4, "tip is %v from the target %v", linalg.length(new_tip - target), target)
		testing.expectf(t, abs(linalg.length(new_mid - root) - linalg.length(mid - root)) < 1e-5, "upper bone changed length")
		testing.expectf(t, abs(linalg.length(new_tip - new_mid) - linalg.length(tip - mid)) < 1e-5, "lower bone changed length")
	}

	// Out of reach: the nearest pose the chain can hold, which is straight at the target
	root_turn, mid_turn, _ := calculate_two_bone_turns(root, mid, tip, {5, 0, 0})
	new_mid := root + linalg.quaternion_mul_vector3(root_turn, mid - root)
	new_tip := new_mid + linalg.quaternion_mul_vector3(mid_turn, tip - mid)
	testing.expectf(t, abs(linalg.length(new_tip - root) - (linalg.length(mid - root) + linalg.length(tip - mid))) < 1e-3, "an unreachable target gives a straight limb")
	testing.expect(t, linalg.normalize(new_tip).x > 0.9999, "pointing at the target")
}

@(test)
the_contact_weight_is_one_when_close_zero_when_apart_and_smooth_between :: proc(t:^testing.T) {
	// 0.435m limb: near is 0.1305m, far 0.32625m (0.30 and 0.75 limb lengths)
	testing.expect_value(t, calculate_contact_weight(0.07, 0.435), 1)
	testing.expect_value(t, calculate_contact_weight(0.38, 0.435), 0)
	testing.expect_value(t, calculate_contact_weight(0.45, 0.435), 0)
	middle := calculate_contact_weight((0.1305 + 0.32625) / 2, 0.435)
	testing.expectf(t, abs(middle - 0.5) < 1e-5, "the middle of the fade is %v, not 0.5", middle)

	// The rate limit holds a sudden change back and leaves a slow one alone
	testing.expect_value(t, calculate_limited_shift({0, 0, 0}, {0.01, 0, 0}, 0.1, 0.435), [3]f32{0.01, 0, 0})
	held := calculate_limited_shift({0, 0, 0}, {0.2, 0, 0}, 0.1, 0.435) // may move 1 limb length a second: 0.0435 in 0.1s
	testing.expectf(t, abs(held.x - 0.0435) < 1e-5 && held.y == 0, "held back to %v", held)
}

@(private = "file")
Character_Test :: struct {
	data:Model_Data,
	model:Model,
	source:Animation_Source,
	baked_clips:int,
}

// A Model that borrows the loaded data's skeleton, as the skeleton tests do. The animations are the model's own after a retarget
@(private = "file")
load_character :: proc(t:^testing.T, folder:string, fit:Retarget_Fit) -> (character:Character_Test, ok:bool) {
	character.data, ok = read_gltf_model(path_join(folder, "psx_humanoid_male.glb"), 256)
	if testing.expect(t, ok, "the character did not read") == false do return
	parts := make([]Model_Part, len(character.data.parts))
	for part, index in character.data.parts {
		parts[index] = Model_Part{mesh = Mesh{skinned = len(part.skinned_vertices) > 0}, skin = part.skin, mesh_node = part.mesh_node, joint_map = part.joint_map}
	}
	character.model = Model{parts = parts, skeleton = character.data.skeleton, animations = character.data.animations}
	character.baked_clips = len(character.data.animations)

	humanoid, mapped := map_humanoid_bones(character.model, UNITY_BONE_NAMES)
	testing.expect_value(t, mapped, 22)

	character.source, ok = load_animation_source(path_join(folder, "retargeted_animations.glb"), path_join(folder, "retargeted_animations_rest.gltf"))
	if testing.expect(t, ok, "the clips did not read") == false do return

	added := retarget_animations(&character.model, humanoid, character.source, Retarget_Options{fit = fit})
	testing.expect_value(t, added, len(character.source.animations)) // every clip drives at least a mapped bone
	return character, true
}

@(private = "file")
destroy_character :: proc(character:Character_Test) {
	// The retargeted clips are after the baked ones, which the file's own data still owns
	destroy_model_animations(character.model.animations[character.baked_clips:])
	delete(character.model.parts)
	destroy_animation_source(character.source)
	destroy_model_data(character.data)
}

@(private = "file")
path_join :: proc(folder, file:string) -> string {
	joined, _ := filepath.join([]string{folder, file}, context.temp_allocator)
	return joined
}

/*
	The game's clips on the game's character, played by an Animator, against tools/verify_retarget.py: the world position of six
	nodes at the time of the clip's sixth key. Rotation only first, which is what numpy reproduces exactly, then the
	proportion pass, which must leave all four alone: in none of them are the hands held together, so a correction that
	moved them would be the exact harm the contact weight exists to prevent
*/
@(test)
the_games_clips_play_on_the_games_character_where_numpy_puts_it :: proc(t:^testing.T) {
	folder := os.get_env("MATCHBOX_THE_GAME_CHARACTERS", context.temp_allocator)
	if folder == "" {
		testing.expect(t, true, "MATCHBOX_THE_GAME_CHARACTERS is not set: skipping the real-asset check")
		return
	}

	Expected :: struct {
		clip:string,
		time:f32,
		hips, head, left_hand, right_hand, left_foot, right_foot:[3]f32,
	}
	expected := []Expected {
		{"Idle_Subtle", 0.25, {-0.00957, 0.98496, 0.01872}, {0.00209, 1.62847, 0.03230}, {0.27430, 1.05934, 0.08154}, {-0.24481, 1.05148, -0.00930}, {0.20033, 0.13523, 0.03723}, {-0.13383, 0.12995, 0.04373}},
		{"Walk", 0.208333, {0.00780, 0.97875, 0.01467}, {0.03459, 1.61392, 0.09448}, {0.24177, 1.02437, 0.00921}, {-0.21461, 1.10137, 0.25026}, {0.09010, 0.14009, 0.19056}, {-0.09224, 0.23769, -0.32249}},
		{"Walk_Backwards", 0.25, {0.00008, 0.98167, -0.03777}, {0.00008, 1.62395, -0.01353}, {0.25052, 1.07930, 0.04057}, {-0.25035, 1.07930, 0.04057}, {0.13177, 0.28124, 0.05577}, {-0.11940, 0.12952, -0.02626}},
		{"Run_Female", 0.25, {-0.00436, 0.96908, 0.03315}, {-0.01412, 1.58291, 0.19658}, {0.20152, 1.23194, 0.10329}, {-0.11460, 1.21847, 0.25246}, {0.04922, 0.47959, 0.17394}, {-0.03982, 0.30336, -0.45297}},
	}

	for fit in Retarget_Fit {
		character, ok := load_character(t, folder, fit)
		if ok == false do return
		defer destroy_character(character)

		animator := create_animator(character.model)
		defer destroy_animator(&animator)

		for want in expected {
			label := want.clip
			if testing.expectf(t, play_animation(&animator, character.model, want.clip), "%s was not retargeted onto the character", label) == false do continue
			// A clip is sampled at its time; no step, so the time is exactly the key's. The animator is what the game would be using
			animator.time = want.time
			animator.blend.active = false
			update_animator(&animator, character.model, 0)

			nodes := [6]string{"Hips", "Head", "LeftHand", "RightHand", "LeftFoot", "RightFoot"}
			positions := [6][3]f32{want.hips, want.head, want.left_hand, want.right_hand, want.left_foot, want.right_foot}
			for name, i in nodes {
				node, found := get_node_index(character.model, name)
				if testing.expectf(t, found, "no node %s", name) == false do continue
				got := [3]f32{animator.pose.globals[node][0, 3], animator.pose.globals[node][1, 3], animator.pose.globals[node][2, 3]}
				error := linalg.length(got - positions[i])
				testing.expectf(t, error < 5e-4, "%v %s: %s is %v, numpy says %v (%v apart)", fit, label, name, got, positions[i], error)
			}
		}
	}
}
