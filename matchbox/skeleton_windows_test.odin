#+build windows

package matchbox

import "core:math"
import "core:math/linalg"
import "core:sync"
import "core:testing"

/*
	Skinned animation, against numbers that did not come from this code. tools/make_test_skinned_model.py writes
	tools/testdata/models/test_arm.glb and test_rope.glb and works out, with numpy and the glTF spec's own formulas,
	what each joint's palette must be; the numbers below are its output (`python tools/make_test_skinned_model.py`
	prints them). The arm is three joints in a chain along +X under a non-joint "armature" node at (0, 1, 0), a
	two-second clip "Wave" (rotation LINEAR, translation STEP, scale CUBICSPLINE) and a one-second "Bend".
	None of this touches the GPU: a Model is built by hand from the loaded data, which is all the animator reads
*/

@(private = "file")
Test_Arm :: struct {
	data:Model_Data,
	model:Model,
}

/*A Model that borrows the loaded data's skeleton, clips and joint maps. The test frees the data, not the model*/
@(private = "file")
load_test_model :: proc(t:^testing.T, path:string, joint_limit:int) -> (arm:Test_Arm, ok:bool) {
	arm.data, ok = read_gltf_model(path, joint_limit)
	if testing.expectf(t, ok, "%s did not read", path) == false do return
	parts := make([]Model_Part, len(arm.data.parts), context.temp_allocator)
	for part, index in arm.data.parts {
		parts[index] = Model_Part{mesh = Mesh{skinned = len(part.skinned_vertices) > 0}, skin = part.skin, mesh_node = part.mesh_node, joint_map = part.joint_map}
	}
	arm.model = Model{parts = parts, skeleton = arm.data.skeleton, animations = arm.data.animations}
	return
}

@(private = "file")
expect_palette :: proc(t:^testing.T, label:string, palette:matrix[4, 4]f32, rows:[12]f32) {
	for row in 0 ..< 3 {
		for column in 0 ..< 4 {
			got := palette[row, column]
			want := rows[row * 4 + column]
			testing.expectf(t, abs(got - want) < 1e-4, "%s: element [%d, %d] is %v, numpy says %v", label, row, column, got, want)
		}
	}
}

@(test)
a_skinned_file_reads_as_its_skeleton_clips_and_weights :: proc(t:^testing.T) {
	arm, ok := load_test_model(t, "tools/testdata/models/test_arm.glb", 256)
	if ok == false do return
	defer destroy_model_data(arm.data)

	testing.expect_value(t, len(arm.data.skeleton.names), 5)
	testing.expect_value(t, arm.data.skeleton.names[1], "armature")
	testing.expect_value(t, arm.data.skeleton.parents[2], 1) // J0 under the armature, which is not a joint
	testing.expect_value(t, arm.data.skeleton.parents[4], 3)
	if testing.expect_value(t, len(arm.data.skeleton.skins), 1) {
		testing.expect_value(t, arm.data.skeleton.skins[0].joints[0], 2) // the first joint is node 2: a joint index is not a node index
		testing.expect_value(t, len(arm.data.skeleton.skins[0].joints), 3)
	}
	if testing.expect_value(t, len(arm.data.animations), 2) {
		testing.expect_value(t, arm.data.animations[0].name, "Wave")
		testing.expect_value(t, arm.data.animations[0].duration, 2)
		testing.expect_value(t, len(arm.data.animations[0].tracks), 3)
		testing.expect_value(t, arm.data.animations[1].name, "Bend")
		testing.expect_value(t, arm.data.animations[1].duration, 1)
	}

	// One part of six vertices that uses all three joints, whole, in file order
	if testing.expect_value(t, len(arm.data.parts), 1) == false do return
	part := arm.data.parts[0]
	testing.expect_value(t, len(part.skinned_vertices), 6)
	testing.expect_value(t, len(part.vertices), 0)
	testing.expect_value(t, part.mesh_node, 0)
	if testing.expect_value(t, len(part.joint_map), 3) do testing.expect_value(t, [3]u32{part.joint_map[0], part.joint_map[1], part.joint_map[2]}, [3]u32{0, 1, 2})

	// The vertices are in the order the triangles first use them, so each is found by where it is. The mesh node's
	// transform is not baked into a skinned mesh's vertices: they stay in the mesh's own space
	find_vertex :: proc(part:Model_Data_Part, position:[3]f32) -> (vertex:Skinned_Vertex, found:bool) {
		for candidate in part.skinned_vertices {
			if candidate.position == position do return candidate, true
		}
		return {}, false
	}
	near_end, has_near_end := find_vertex(part, {2, 0.85, 0})
	middle, has_middle := find_vertex(part, {1, 0.85, 0})
	root, has_root := find_vertex(part, {0, 0.85, 0})
	if testing.expect(t, has_near_end && has_middle && has_root) == false do return

	// Weights are bytes that sum to 255: the middle vertex is half J0 and half J1, 128 each would be 256, so the first
	// of the equal pair gives one back
	for vertex, index in part.skinned_vertices {
		total := int(vertex.weights[0]) + int(vertex.weights[1]) + int(vertex.weights[2]) + int(vertex.weights[3])
		testing.expectf(t, total == 255, "vertex %d's weights sum to %d", index, total)
	}
	testing.expect_value(t, root.weights, [4]u8{255, 0, 0, 0})
	testing.expect_value(t, [2]u8{near_end.joints[0], near_end.joints[1]}, [2]u8{1, 2})
	testing.expect_value(t, [2]u8{near_end.weights[0], near_end.weights[1]}, [2]u8{64, 191})
	testing.expect_value(t, [2]u8{middle.weights[0], middle.weights[1]}, [2]u8{127, 128})
}

@(test)
a_model_with_no_clip_playing_stands_in_its_bind_pose :: proc(t:^testing.T) {
	arm, ok := load_test_model(t, "tools/testdata/models/test_arm.glb", 256)
	if ok == false do return
	defer destroy_model_data(arm.data)
	animator := create_animator(arm.model)
	defer destroy_animator(&animator)

	// The palette is `joint's global * inverse bind`, and in the bind pose that is the identity, armature and all
	identity := [12]f32{1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0}
	if testing.expect_value(t, len(animator.pose.palettes[0]), 3) == false do return
	for slot in 0 ..< 3 do expect_palette(t, "bind pose", animator.pose.palettes[0][slot], identity)
}

@(test)
the_wave_clip_gives_the_palettes_numpy_works_out :: proc(t:^testing.T) {
	arm, ok := load_test_model(t, "tools/testdata/models/test_arm.glb", 256)
	if ok == false do return
	defer destroy_model_data(arm.data)

	// Straight from `python tools/make_test_skinned_model.py`. t = 0.5 is LINEAR halfway to 90 degrees and the CUBICSPLINE
	// scale at 1.75 on its way to 2 (zero in-tangent at the far key, 2 out of the near one); t = 1 has the STEP translation
	// taken; t = 1.5 is on the way back, the STEP still held
	cases := [?]struct {
		time:f32,
		palettes:[3][12]f32,
	} {
		{0, {{1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0}, {1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0}, {1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0}}},
		{0.5, {
			{1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0},
			{0.707107, -0.707107, 0, 1.0, 0.707107, 0.707107, 0, -0.414214, 0, 0, 1, 0},
			{1.237437, -0.707107, 0, -0.06066, 1.237437, 0.707107, 0, -1.474874, 0, 0, 1, 0},
		}},
		{1.0, {
			{1, 0, 0, 0, 0, 1, 0, 0.5, 0, 0, 1, 0},
			{0, -1, 0, 2.0, 1, 0, 0, 0.5, 0, 0, 1, 0},
			{0, -1, 0, 2.0, 2, 0, 0, -1.5, 0, 0, 1, 0},
		}},
		{1.5, {
			{1, 0, 0, 0, 0, 1, 0, 0.5, 0, 0, 1, 0},
			{0.707107, -0.707107, 0, 1.0, 0.707107, 0.707107, 0, 0.085786, 0, 0, 1, 0},
			{1.06066, -0.707107, 0, 0.292893, 1.06066, 0.707107, 0, -0.62132, 0, 0, 1, 0},
		}},
	}

	for case_ in cases {
		animator := create_animator(arm.model)
		defer destroy_animator(&animator)
		testing.expect(t, play_animation(&animator, arm.model, "Wave"))
		update_animator(&animator, arm.model, case_.time)
		for slot in 0 ..< 3 {
			expect_palette(t, "Wave", animator.pose.palettes[0][slot], case_.palettes[slot])
		}
	}
}

@(test)
a_clip_that_is_not_looping_finishes_and_one_that_is_wraps :: proc(t:^testing.T) {
	arm, ok := load_test_model(t, "tools/testdata/models/test_arm.glb", 256)
	if ok == false do return
	defer destroy_model_data(arm.data)

	once := create_animator(arm.model)
	defer destroy_animator(&once)
	play_animation(&once, arm.model, "Wave", looping = false)
	update_animator(&once, arm.model, 1.5)
	testing.expect(t, once.playing)
	update_animator(&once, arm.model, 1.5)
	testing.expect(t, once.playing == false) // polled by the game, never called back
	testing.expect_value(t, once.time, 2)

	looped := create_animator(arm.model)
	defer destroy_animator(&looped)
	play_animation(&looped, arm.model, "Wave")
	update_animator(&looped, arm.model, 2.5)
	testing.expect(t, looped.playing)
	testing.expectf(t, abs(looped.time - 0.5) < 1e-5, "looped clip is at %v, expected 0.5", looped.time)

	_, found := get_animation_index(arm.model, "Nope") // play_animation logs an error for a name like this, which fails a test
	testing.expect(t, found == false)
}

/*The angle about Z of a rotation, in degrees: what the arm's tracks turn*/
@(private = "file")
angle_about_z :: proc(rotation:quaternion128) -> f32 {
	return math.to_degrees(2 * math.atan2(kmag(rotation), real(rotation)))
}

@(test)
changing_clip_fades_over_the_blend_duration_with_the_old_one_still_moving :: proc(t:^testing.T) {
	arm, ok := load_test_model(t, "tools/testdata/models/test_arm.glb", 256)
	if ok == false do return
	defer destroy_model_data(arm.data)
	animator := create_animator(arm.model) // blend on, 0.2 s
	defer destroy_animator(&animator)

	play_animation(&animator, arm.model, "Wave")
	update_animator(&animator, arm.model, 1.0) // J1 at 90 degrees
	testing.expectf(t, abs(angle_about_z(animator.pose.locals[3].rotation) - 90) < 1e-3, "J1 at %v", angle_about_z(animator.pose.locals[3].rotation))

	play_animation(&animator, arm.model, "Bend")
	testing.expect(t, animator.blend.active)

	// Halfway through the fade the ease is 0.5. Wave has kept running to 1.1 s (81 degrees) and Bend is held at 45,
	// so the mix is 63. Had the outgoing clip frozen it would be 67.5
	update_animator(&animator, arm.model, 0.1)
	testing.expectf(t, abs(angle_about_z(animator.pose.locals[3].rotation) - 63) < 1e-2, "mid-fade J1 at %v, expected 63", angle_about_z(animator.pose.locals[3].rotation))
	testing.expect(t, animator.blend.active)

	update_animator(&animator, arm.model, 0.1)
	testing.expect(t, animator.blend.active == false)
	testing.expectf(t, abs(angle_about_z(animator.pose.locals[3].rotation) - 45) < 1e-3, "after the fade J1 at %v, expected 45", angle_about_z(animator.pose.locals[3].rotation))

	// Switching with no fade snaps
	snapped := create_animator(arm.model, Animation_Blend{enabled = false})
	defer destroy_animator(&snapped)
	play_animation(&snapped, arm.model, "Wave")
	update_animator(&snapped, arm.model, 1.0)
	play_animation(&snapped, arm.model, "Bend")
	testing.expect(t, snapped.blend.active == false)
	update_animator(&snapped, arm.model, 0.01)
	testing.expectf(t, abs(angle_about_z(snapped.pose.locals[3].rotation) - 45) < 1e-3, "snapped J1 at %v", angle_about_z(snapped.pose.locals[3].rotation))
}

@(test)
two_animators_on_one_model_keep_their_own_poses :: proc(t:^testing.T) {
	arm, ok := load_test_model(t, "tools/testdata/models/test_arm.glb", 256)
	if ok == false do return
	defer destroy_model_data(arm.data)

	a := create_animator(arm.model)
	defer destroy_animator(&a)
	b := create_animator(arm.model)
	defer destroy_animator(&b)
	play_animation(&a, arm.model, "Wave")
	play_animation(&b, arm.model, "Wave")
	update_animator(&a, arm.model, 1.0)
	update_animator(&b, arm.model, 0.5)

	expect_palette(t, "a", a.pose.palettes[0][1], {0, -1, 0, 2, 1, 0, 0, 0.5, 0, 0, 1, 0})
	expect_palette(t, "b", b.pose.palettes[0][1], {0.707107, -0.707107, 0, 1.0, 0.707107, 0.707107, 0, -0.414214, 0, 0, 1, 0})
}

@(test)
a_node_is_found_by_name_and_is_not_a_joint_index :: proc(t:^testing.T) {
	arm, ok := load_test_model(t, "tools/testdata/models/test_arm.glb", 256)
	if ok == false do return
	defer destroy_model_data(arm.data)

	node, found := get_node_index(arm.model, "J2")
	testing.expect(t, found)
	testing.expect_value(t, node, 4) // joint number 2, node number 4
	_, missing := get_node_index(arm.model, "J")
	testing.expect(t, missing == false) // exact match only

	animator := create_animator(arm.model)
	defer destroy_animator(&animator)
	play_animation(&animator, arm.model, "Wave")
	update_animator(&animator, arm.model, 1.0)
	// J2's origin in the model's space at t = 1: the armature (0,1,0), J0 up 0.5, J1 one along +X, J2 one along J1's X
	// which J1 has turned 90 degrees to point up: (0 + 1 + 0, 1 + 0.5 + 0 + 1) = (1, 2.5)
	matrix_ := calculate_node_matrix(arm.model, animator, node)
	testing.expectf(t, abs(matrix_[0, 3] - 1) < 1e-4 && abs(matrix_[1, 3] - 2.5) < 1e-4, "J2 at (%v, %v)", matrix_[0, 3], matrix_[1, 3])
}

@(test)
a_primitive_with_more_joints_than_a_draw_allows_is_cut_into_parts :: proc(t:^testing.T) {
	// 40 joints in a chain, 41 rows of two vertices, 240 indices
	whole, whole_ok := load_test_model(t, "tools/testdata/models/test_rope.glb", 256)
	if whole_ok == false do return
	defer destroy_model_data(whole.data)
	testing.expect_value(t, len(whole.data.parts), 1)
	testing.expect_value(t, len(whole.data.parts[0].joint_map), 40)

	cut, cut_ok := load_test_model(t, "tools/testdata/models/test_rope.glb", 22)
	if cut_ok == false do return
	defer destroy_model_data(cut.data)
	testing.expect(t, len(cut.data.parts) >= 2)

	indices := 0
	for part in cut.data.parts {
		indices += len(part.indices)
		testing.expectf(t, len(part.joint_map) <= 22 && len(part.joint_map) > 0, "a part has %d joints", len(part.joint_map))
		for vertex in part.skinned_vertices {
			for slot in 0 ..< 4 {
				// Every vertex of a piece names a slot of the piece's own map, even where its weight is zero
				testing.expectf(t, int(vertex.joints[slot]) < len(part.joint_map), "joint slot %d is outside a map of %d", vertex.joints[slot], len(part.joint_map))
			}
		}
	}
	testing.expect_value(t, indices, 240) // no triangle lost

	// Each part has its own palette, sized to its own joint map
	animator_cut := create_animator(cut.model)
	defer destroy_animator(&animator_cut)
	testing.expect(t, len(animator_cut.pose.joint_data) >= 40)
}

@(test)
weights_are_quantised_to_sum_to_255 :: proc(t:^testing.T) {
	joints, weights := quantize_skin_influences({joints = {3, 4, 5, 6}, weights = {0.5, 0.25, 0.25, 0}})
	testing.expect_value(t, weights, [4]u8{127, 64, 64, 0})
	testing.expect_value(t, joints, [4]u16{3, 4, 5, 3}) // a zero weight points at a joint the piece already has

	// WEIGHTS_1 may hold the rest: what arrives short of one is scaled up rather than left to drag the vertex to the origin
	_, scaled := quantize_skin_influences({joints = {1, 2, 0, 0}, weights = {0.3, 0.3, 0, 0}})
	testing.expect_value(t, scaled, [4]u8{127, 128, 0, 0})

	// No weight at all: pinned to the first joint, whole
	pinned_joints, pinned := quantize_skin_influences({joints = {7, 8, 9, 10}, weights = {0, 0, 0, 0}})
	testing.expect_value(t, pinned, [4]u8{255, 0, 0, 0})
	testing.expect_value(t, pinned_joints[0], 7)
}

@(test)
a_triangle_needing_more_joints_than_the_limit_refuses :: proc(t:^testing.T) {
	vertices := make([]Lit_Vertex, 3, context.temp_allocator)
	influences := []Skin_Influences {
		{joints = {0, 1, 2, 3}, weights = {0.25, 0.25, 0.25, 0.25}},
		{joints = {4, 5, 6, 7}, weights = {0.25, 0.25, 0.25, 0.25}},
		{joints = {8, 9, 10, 11}, weights = {0.25, 0.25, 0.25, 0.25}},
	}
	pieces, ok := split_skinned_primitive(vertices, influences, {0, 1, 2}, 12, 11, context.temp_allocator)
	testing.expect(t, ok == false)

	pieces, ok = split_skinned_primitive(vertices, influences, {0, 1, 2}, 12, 12, context.temp_allocator)
	testing.expect(t, ok)
	if testing.expect_value(t, len(pieces), 1) do testing.expect_value(t, len(pieces[0].joint_map), 12)
}

@(test)
the_joint_arena_hands_the_shader_row_arrays_padded_with_the_identity :: proc(t:^testing.T) {
	sync.mutex_lock(&mbi_lock)
	defer sync.mutex_unlock(&mbi_lock)
	saved_limit := mbi.skin_settings.joint_limit
	saved_rows := mbi.skin_state.rows
	mbi.skin_settings.joint_limit = 4
	mbi.skin_state.rows = nil
	defer {
		delete(mbi.skin_state.rows)
		mbi.skin_settings.joint_limit = saved_limit
		mbi.skin_state.rows = saved_rows
	}

	first := matrix[4, 4]f32{
		1, 0, 0, 5,
		0, 1, 0, 6,
		0, 0, 1, 7,
		0, 0, 0, 1,
	}
	second := matrix[4, 4]f32{
		2, 0, 0, 8,
		0, 3, 0, 9,
		0, 0, 4, 10,
		0, 0, 0, 1,
	}
	push_skin_palette({linalg.MATRIX4F32_IDENTITY}) // something already in the arena: the next draw's offset is not 0
	offset, count := push_skin_palette({first, second})
	testing.expect_value(t, offset, 1)
	testing.expect_value(t, count, 2)

	rows := get_skin_rows(Render_Item{joint_offset = offset, joint_count = count})
	if testing.expect_value(t, len(rows), 12) == false do return
	// All the first rows, then all the second, then all the third; joints 2 and 3 are the identity
	testing.expect_value(t, rows[0], [4]f32{1, 0, 0, 5})
	testing.expect_value(t, rows[1], [4]f32{2, 0, 0, 8})
	testing.expect_value(t, rows[2], [4]f32{1, 0, 0, 0})
	testing.expect_value(t, rows[4 + 1], [4]f32{0, 3, 0, 9})
	testing.expect_value(t, rows[8 + 0], [4]f32{0, 0, 1, 7})
	testing.expect_value(t, rows[8 + 1], [4]f32{0, 0, 4, 10})
	testing.expect_value(t, rows[8 + 3], [4]f32{0, 0, 1, 0})

	// No palette is the bind pose: the identity throughout
	bind := get_skin_rows(Render_Item{})
	testing.expect_value(t, bind[4], [4]f32{0, 1, 0, 0})
}
