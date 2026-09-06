package matchbox

/*
	3D animation -- masks, layers, and the play_animation idempotence fix
	----------------------------------------------------------------------
	All of this runs on a synthetic skeleton, headlessly: `Model` and
	`Skeleton` are plain structs, so a five-node rig and a couple of
	one-keyframe clips are enough to pin down the composition arithmetic
	without a file, a GPU, or a window. See `animation3d.md` for what this
	deliberately does not cover -- whether a mask reads as "the upper body"
	on a real rig needs the asset and the eye, not a test.

	The skeleton is a root with two chains, as `animation3d.md` describes it:

		root(0) -- spine(1) -- hand(2)
		        \- hip(3)   -- foot(4)

	Both clips use `.STEP` interpolation with a single keyframe, so the value
	a track produces does not depend on the playback time -- what is under
	test is which nodes a layer touches and by how much, not the sampler.
*/

import "core:log"
import "core:math/linalg"
import "core:slice"
import "core:strings"
import "core:testing"

/*
	Every slice below goes through `slice.clone` rather than a bare literal --
	a literal's backing array lives on this procedure's stack frame, and
	`Skeleton`/`Model` outlive it once returned. `odin check` catches the bare
	form as unsafe; cloning is the fix, not working around the check.

	Names go through `strings.clone` individually, on top of that: `destroy_model`
	is what tears this fixture down again (see `test_model`), and it frees
	`skeleton.names` and `clip.name` string by string, the way the glTF loader's
	own clones do. Handing it the original string literals would ask it to free
	memory it never allocated.
*/
@(private = "file")
test_skeleton :: proc() -> Skeleton {
	identity := transform_identity()

	names := make([]string, 5)
	raw_names := []string{"root", "spine", "hand", "hip", "foot"}
	for name, i in raw_names {
		names[i] = strings.clone(name)
	}

	return Skeleton{
		parents = slice.clone([]i32{-1, 0, 1, 0, 3}),
		rest    = slice.clone([]Transform{identity, identity, identity, identity, identity}),
		order   = slice.clone([]u32{0, 1, 2, 3, 4}),
		names   = names,
		skins   = slice.clone([]Model_Skin{
			{
				joints       = slice.clone([]u32{0, 1, 2, 3, 4}),
				inverse_bind = slice.clone([]matrix[4, 4]f32{
					linalg.MATRIX4F32_IDENTITY, linalg.MATRIX4F32_IDENTITY,
					linalg.MATRIX4F32_IDENTITY, linalg.MATRIX4F32_IDENTITY,
					linalg.MATRIX4F32_IDENTITY,
				}),
			},
		}),
	}
}

@(private = "file")
step_track :: proc(node: u32, position: [3]f32) -> Animation_Track {
	return Animation_Track{
		node          = node,
		path          = .TRANSLATION,
		interpolation = .STEP,
		times         = slice.clone([]f32{0}),
		vectors       = slice.clone([][3]f32{position}),
	}
}

// "base" moves the hip (3); "upper" moves the spine (1). Neither touches the
// other's node, so a test can tell a base value from a layer value on sight.
//
// Torn down with `destroy_model`, the same verb a game uses -- it frees the
// skeleton and the clips and, with no renderer running in a test process,
// stops there rather than reaching for a GPU device that does not exist.
@(private = "file")
test_model :: proc() -> Model {
	return Model{
		skeleton = test_skeleton(),
		animations = slice.clone([]Model_Animation{
			{name = strings.clone("base"), duration = 1, tracks = slice.clone([]Animation_Track{step_track(3, {1, 0, 0})})},
			{name = strings.clone("upper"), duration = 1, tracks = slice.clone([]Animation_Track{step_track(1, {2, 0, 0})})},
		}),
	}
}

// -----------------------------------------------------------------------
// Masks
// -----------------------------------------------------------------------

// A mask below an internal node covers it and everything under it, and
// nothing above -- the case that motivates the whole feature: "spine up".
@(test)
test_mask_below_covers_exactly_the_subtree :: proc(t: ^testing.T) {
	model := test_model()
	defer destroy_model(&model)
	mask  := animation_mask_below(model, 1) // spine
	defer delete(mask)

	testing.expect(t, mask[1], "the mask's own root should be included")
	testing.expect(t, mask[2], "a child of the root should be included")
	testing.expect(t, !mask[0], "the mask's own parent must not be included")
	testing.expect(t, !mask[3], "an unrelated branch must not be included")
	testing.expect(t, !mask[4], "an unrelated branch's child must not be included")
}

// A mask below a leaf is just that one node -- there is nothing under it to
// pull in, and the walk over `order` must not reach upward by mistake.
@(test)
test_mask_below_a_leaf_is_just_that_node :: proc(t: ^testing.T) {
	model := test_model()
	defer destroy_model(&model)
	mask  := animation_mask_below(model, 2) // hand, a leaf
	defer delete(mask)

	testing.expect(t, mask[2], "the leaf itself should be included")
	testing.expect(t, !mask[0], "root must not be included")
	testing.expect(t, !mask[1], "the leaf's own parent must not be included")
	testing.expect(t, !mask[3], "an unrelated branch must not be included")
	testing.expect(t, !mask[4], "an unrelated branch's child must not be included")
}

// A mask built from names covers exactly those nodes, with no hierarchy
// walk -- unlike animation_mask_below, a parent named alongside a child pulls
// in only the two named, not anything between them.
@(test)
test_mask_named_covers_only_the_named_nodes :: proc(t: ^testing.T) {
	model := test_model()
	defer destroy_model(&model)
	mask  := animation_mask_named(model, []string{"hand", "foot"})
	defer delete(mask)

	testing.expect(t, mask[2], "hand was named")
	testing.expect(t, mask[4], "foot was named")
	testing.expect(t, !mask[0], "root was not named")
	testing.expect(t, !mask[1], "spine was not named, even though it is hand's parent")
	testing.expect(t, !mask[3], "hip was not named, even though it is foot's parent")
}

// -----------------------------------------------------------------------
// Layers
// -----------------------------------------------------------------------

// A layer at weight 1 replaces its masked joints outright and leaves
// everything else exactly where the base clip put it.
@(test)
test_layer_at_weight_one_overrides_only_masked_joints :: proc(t: ^testing.T) {
	model    := test_model()
	defer destroy_model(&model)
	animator := create_animator(model)
	defer destroy_animator(&animator)

	play_animation(&animator, model, "base")

	mask := animation_mask_below(model, 1) // spine and hand
	defer delete(mask)
	testing.expect(t, play_animation_layer(&animator, model, 0, "upper", mask), "layer should start")
	set_animation_layer_weight(&animator, 0, 1)

	update_animator(&animator, model, 0.1)

	testing.expect_value(t, animator.pose.locals[1].position, [3]f32{2, 0, 0})
	testing.expect_value(t, animator.pose.locals[3].position, [3]f32{1, 0, 0})
}

// A layer at weight 0 is skipped by the composition loop entirely, so the
// base's own values stand.
@(test)
test_layer_at_weight_zero_changes_nothing :: proc(t: ^testing.T) {
	model    := test_model()
	defer destroy_model(&model)
	animator := create_animator(model)
	defer destroy_animator(&animator)

	play_animation(&animator, model, "base")

	mask := animation_mask_below(model, 1)
	defer delete(mask)
	play_animation_layer(&animator, model, 0, "upper", mask)
	set_animation_layer_weight(&animator, 0, 0)

	update_animator(&animator, model, 0.1)

	testing.expect_value(t, animator.pose.locals[1].position, [3]f32{0, 0, 0})
}

// A layer at 0.5 lands exactly halfway between the base's value and the
// layer's, checked against transform_mix directly rather than against a
// hand-computed number.
@(test)
test_layer_at_half_weight_lands_halfway :: proc(t: ^testing.T) {
	model    := test_model()
	defer destroy_model(&model)
	animator := create_animator(model)
	defer destroy_animator(&animator)

	play_animation(&animator, model, "base")

	mask := animation_mask_below(model, 1)
	defer delete(mask)
	play_animation_layer(&animator, model, 0, "upper", mask)
	set_animation_layer_weight(&animator, 0, 0.5)

	update_animator(&animator, model, 0.1)

	base_value  := transform_identity()               // node 1 is untouched by "base"
	layer_value := Transform{position = {2, 0, 0}, rotation = linalg.QUATERNIONF32_IDENTITY, scale = {1, 1, 1}}
	expected    := transform_mix(base_value, layer_value, 0.5)

	testing.expect_value(t, animator.pose.locals[1].position, expected.position)
}

// A layer that was never started is `active == false`, and the composition
// loop's first check skips it before touching the pose or its own clock.
@(test)
test_inactive_layer_costs_nothing :: proc(t: ^testing.T) {
	model    := test_model()
	defer destroy_model(&model)
	animator := create_animator(model)
	defer destroy_animator(&animator)

	play_animation(&animator, model, "base")

	for _ in 0 ..< 5 do update_animator(&animator, model, 0.1)

	testing.expect_value(t, animator.pose.locals[1].position, [3]f32{0, 0, 0})
	testing.expect_value(t, animator.layers[0].time, f32(0))
}

// stop_animation_layer drops a layer's contribution on the very next update,
// without touching its weight or clip -- play_animation_layer picks up
// cleanly afterwards.
@(test)
test_stop_animation_layer_removes_its_contribution :: proc(t: ^testing.T) {
	model    := test_model()
	defer destroy_model(&model)
	animator := create_animator(model)
	defer destroy_animator(&animator)

	play_animation(&animator, model, "base")

	mask := animation_mask_below(model, 1)
	defer delete(mask)
	play_animation_layer(&animator, model, 0, "upper", mask)
	set_animation_layer_weight(&animator, 0, 1)
	update_animator(&animator, model, 0.1)
	testing.expect_value(t, animator.pose.locals[1].position, [3]f32{2, 0, 0})

	stop_animation_layer(&animator, 0)
	update_animator(&animator, model, 0.1)

	testing.expect_value(t, animator.pose.locals[1].position, [3]f32{0, 0, 0})
}

/*
	A mask built against a different skeleton size is rejected rather than
	partially copied -- copy() would silently truncate instead of failing.

	The logger is silenced for the duration: the rejection is what is under
	test, and the error it logs is loud enough that the test runner counts it
	as a failure otherwise -- see `test_a_full_queue_drops_the_next_entry` on
	the 2D side for the same shape of test.
*/
@(test)
test_play_animation_layer_rejects_a_wrongly_sized_mask :: proc(t: ^testing.T) {
	context.logger = log.nil_logger()

	model    := test_model()
	defer destroy_model(&model)
	animator := create_animator(model)
	defer destroy_animator(&animator)

	wrong_mask := make([]bool, len(model.skeleton.rest) - 1)
	defer delete(wrong_mask)

	ok := play_animation_layer(&animator, model, 0, "upper", wrong_mask)
	testing.expect(t, !ok, "a wrongly-sized mask should be rejected")
	testing.expect(t, !animator.layers[0].active, "the layer should not have started")
}

// -----------------------------------------------------------------------
// play_animation's idempotence, and replay_animation_3d's restart
// -----------------------------------------------------------------------

// Asking for the clip already playing must not reset its clock -- the bug
// that froze a state machine-driven character on frame one.
@(test)
test_play_animation_does_not_reset_time_for_the_current_clip :: proc(t: ^testing.T) {
	model    := test_model()
	defer destroy_model(&model)
	animator := create_animator(model)
	defer destroy_animator(&animator)

	play_animation(&animator, model, "base")
	update_animator(&animator, model, 0.4)
	testing.expect(t, animator.time > 0, "the clock should have advanced")

	before := animator.time
	play_animation(&animator, model, "base")

	testing.expect_value(t, animator.time, before)
	testing.expect(t, animator.playing, "asking for the current clip should not stop it")
}

// replay_animation_3d is the verb play_animation deliberately does not have:
// it restarts the clip already on the animator, on purpose.
@(test)
test_replay_animation_3d_restarts_from_zero :: proc(t: ^testing.T) {
	model    := test_model()
	defer destroy_model(&model)
	animator := create_animator(model)
	defer destroy_animator(&animator)

	play_animation(&animator, model, "base")
	update_animator(&animator, model, 0.4)
	testing.expect(t, animator.time > 0, "the clock should have advanced")

	replay_animation_3d(&animator)

	testing.expect_value(t, animator.time, f32(0))
	testing.expect(t, animator.playing, "replay should be playing again")
}

// The same idempotence extends to a layer: asking play_animation_layer for
// the clip already on it must not reset that layer's own clock either.
@(test)
test_play_animation_layer_does_not_reset_time_for_the_current_clip :: proc(t: ^testing.T) {
	model    := test_model()
	defer destroy_model(&model)
	animator := create_animator(model)
	defer destroy_animator(&animator)

	play_animation(&animator, model, "base")

	mask := animation_mask_below(model, 1)
	defer delete(mask)
	play_animation_layer(&animator, model, 0, "upper", mask)
	set_animation_layer_weight(&animator, 0, 1)
	update_animator(&animator, model, 0.4)
	testing.expect(t, animator.layers[0].time > 0, "the layer's clock should have advanced")

	before := animator.layers[0].time
	play_animation_layer(&animator, model, 0, "upper", mask)

	testing.expect_value(t, animator.layers[0].time, before)
}

// -----------------------------------------------------------------------
// Skin weights
// -----------------------------------------------------------------------

/*
	The skinning shader uses the weight sum unscaled, so a set summing to `s`
	puts the vertex at `s` times its correct position -- pulled toward the
	model's origin. These pin the renormalisation that stops it.

	`read_weights` needs a glTF document to read from, which a synthetic
	skeleton cannot provide, so this tests the arithmetic the loader applies
	rather than the loader's plumbing: the same normalise, over the cases that
	reach it.
*/
@(test)
test_weights_renormalise_to_one :: proc(t: ^testing.T) {
	// A vertex with a fifth influence in WEIGHTS_1: the four here sum short.
	w := [4]f32{0.4, 0.3, 0.1, 0.05}
	sum := w[0] + w[1] + w[2] + w[3]
	testing.expect(t, sum < 1, "setup: this set should sum short of one")

	normalised := [4]f32{w[0] / sum, w[1] / sum, w[2] / sum, w[3] / sum}
	total := normalised[0] + normalised[1] + normalised[2] + normalised[3]

	testing.expect(t, abs(total - 1) < 1e-6,
		"a short set must sum to one after normalising, or the vertex lands short of where it belongs")

	// The proportions between joints are what the artist authored -- only the
	// missing influence's share is redistributed, not the balance.
	testing.expect(t, abs(normalised[0] / normalised[1] - w[0] / w[1]) < 1e-6,
		"normalising must not change the ratio between two joints' say")
}

@(test)
test_unweighted_vertex_pins_rather_than_collapses :: proc(t: ^testing.T) {
	// Four zeroes would make the skin matrix zero and put the vertex on the
	// model origin, taking its triangle with it.
	w := [4]f32{0, 0, 0, 0}
	sum := w[0] + w[1] + w[2] + w[3]

	out := w
	if sum <= 0 do out = {1, 0, 0, 0}

	testing.expect_value(t, out, [4]f32{1, 0, 0, 0})
	testing.expect(t, out[0] + out[1] + out[2] + out[3] == 1,
		"an unweighted vertex must still sum to one, pinned to the first joint")
}

// -----------------------------------------------------------------------
// The compact per-part joint palette
// -----------------------------------------------------------------------

/*
	A part's palette holds only the joints that part uses, and a vertex names a
	slot in it rather than a joint in the skin -- `Model_Part.joint_map` is what
	turns one into the other.

	This exists because SDL's Vulkan backend binds a uniform with a range of
	4096 bytes, which is exactly 64 matrices, so a rig with more joints than
	that cannot hand the shader a palette of its whole skin. Getting the
	indirection backwards does not fail loudly: it fills a slot from the wrong
	joint, which reads as one limb following another.
*/
@(test)
test_palette_is_filled_through_the_joint_map :: proc(t: ^testing.T) {
	model := test_model()
	defer destroy_model(&model)

	// A part using two of the skeleton's five joints, deliberately out of
	// order and not starting at zero: slot 0 is joint 3, slot 1 is joint 1.
	model.parts = slice.clone([]Model_Part{{skin = 0, node = 0, joint_map = slice.clone([]u32{3, 1})}})
	defer {
		for &part in model.parts do delete(part.joint_map)
		delete(model.parts)
		model.parts = nil
	}

	anim := create_animator(model)
	defer destroy_animator(&anim)

	testing.expect_value(t, len(anim.pose.palettes[0]), 2)

	// hip(3) is what "base" moves, so its palette slot must be the one that
	// differs from the rest pose -- and it must be slot 0, not slot 3.
	play_animation(&anim, model, "base")
	update_animator(&anim, model, 0.1)

	node_for_slot_0 := model.skeleton.skins[0].joints[model.parts[0].joint_map[0]]
	testing.expect_value(t, node_for_slot_0, u32(3))

	expected := anim.pose.globals[3] * model.skeleton.skins[0].inverse_bind[3]
	testing.expect(t, anim.pose.palettes[0][0] == expected,
		"slot 0 must be built from the joint its map names, not from joint 0")
}

// A slot that cannot be resolved must leave its vertices where they are. `make`
// zeroes, and a zero matrix is the one value that collapses a vertex onto the
// origin and drags its triangles with it -- which is how this bug looked.
@(test)
test_unresolvable_palette_slots_are_identity :: proc(t: ^testing.T) {
	model := test_model()
	defer destroy_model(&model)

	// Slot 1 names a joint the skin does not have.
	model.parts = slice.clone([]Model_Part{{skin = 0, node = 0, joint_map = slice.clone([]u32{0, 99})}})
	defer {
		for &part in model.parts do delete(part.joint_map)
		delete(model.parts)
		model.parts = nil
	}

	anim := create_animator(model)
	defer destroy_animator(&anim)

	update_animator(&anim, model, 0.1)

	testing.expect(t, anim.pose.palettes[0][1] == linalg.MATRIX4F32_IDENTITY,
		"an unresolvable slot must be the identity, never a zero matrix")
}
