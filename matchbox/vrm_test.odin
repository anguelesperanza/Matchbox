package matchbox

/*
	VRM -- headless tests
	---------------------
	Everything here runs on hand-built data: `core:encoding/json` values
	constructed the way `json.parse_object` would have produced them, and
	`Skeleton`/`Animation_Source` structs the way `build_skeleton` would have.
	No file, no GPU, no window -- see `vrm.md`'s "What can be tested without a
	VRM asset" for why nearly everything here does not need `character.vrm` on
	disk, and for what is left to check against the real files instead
	(whether the corrected facing reads right to the eye, and whether the
	retargeted clips look like the same motion on the new rig).
*/

import "core:encoding/json"
import "core:fmt"
import "core:math"
import "core:math/linalg"
import "core:slice"
import "core:strings"
import "core:testing"

// -----------------------------------------------------------------------
// Step 1 -- version detection and the facing correction
// -----------------------------------------------------------------------

// A file whose `extensions` carries the 0.0-shaped `"VRM"` key is a 0.0 file,
// however little else is in that block -- the test object below has no other
// key VRM actually writes.
@(test)
test_vrm_version_detects_v0 :: proc(t: ^testing.T) {
	vrm_object := make(json.Object)
	defer delete(vrm_object)
	extensions := make(json.Object)
	defer delete(extensions)
	extensions["VRM"] = vrm_object

	testing.expect_value(t, vrm_version(json.Value(extensions)), Vrm_Version.V0)
}

// The 1.0 key is `"VRMC_vrm"`, a different string entirely rather than a
// version field inside the same block -- the two specs do not share a
// container, so detecting one has to look for the other's own key too.
@(test)
test_vrm_version_detects_v1 :: proc(t: ^testing.T) {
	vrmc_object := make(json.Object)
	defer delete(vrmc_object)
	extensions := make(json.Object)
	defer delete(extensions)
	extensions["VRMC_vrm"] = vrmc_object

	testing.expect_value(t, vrm_version(json.Value(extensions)), Vrm_Version.V1)
}

// An ordinary glTF file's `extensions` -- present, but carrying some other
// extension entirely -- must not be mistaken for either VRM spec.
@(test)
test_vrm_version_none_for_unrelated_extension :: proc(t: ^testing.T) {
	other := make(json.Object)
	defer delete(other)
	extensions := make(json.Object)
	defer delete(extensions)
	extensions["KHR_materials_unlit"] = other

	testing.expect_value(t, vrm_version(json.Value(extensions)), Vrm_Version.NONE)
}

// A file with no `extensions` object at all -- `Extensions` is its zero
// value, `nil` -- is the ordinary case every non-VRM model takes, and must
// not crash the type assertion.
@(test)
test_vrm_version_none_for_nil_extensions :: proc(t: ^testing.T) {
	testing.expect_value(t, vrm_version(nil), Vrm_Version.NONE)
}

// VRM 1.0 already faces -Z like everything else in this package, so its
// correction is the identity -- applying it must be provably free, not just
// visually unnoticeable.
@(test)
test_vrm_facing_correction_is_identity_for_v1_and_none :: proc(t: ^testing.T) {
	testing.expect_value(t, vrm_facing_correction(.V1), linalg.QUATERNIONF32_IDENTITY)
	testing.expect_value(t, vrm_facing_correction(.NONE), linalg.QUATERNIONF32_IDENTITY)
}

// VRM 0.0's correction is a plain 180-degree turn about Y -- checked by
// rotating a forward-pointing vector and asserting it comes out backward and
// unchanged in height, rather than by comparing the quaternion's own
// components (which a sign-flipped-but-equal quaternion would fail on for no
// reason that matters).
@(test)
test_vrm_facing_correction_v0_turns_forward_to_backward :: proc(t: ^testing.T) {
	correction := vrm_facing_correction(.V0)
	turned := linalg.quaternion_mul_vector3(correction, [3]f32{0, 0, 1})

	testing.expect(t, abs(turned.x - 0) < 1e-5, "a pure Y turn must not introduce any X")
	testing.expect(t, abs(turned.y - 0) < 1e-5, "a pure Y turn must not change height")
	testing.expect(t, abs(turned.z - (-1)) < 1e-5, "+Z must turn all the way around to -Z")
}

// The correction lands on every root and nowhere else: a root's rotation
// composes with the turn, a non-root is untouched, and passing the identity
// (the every-non-VRM-file case) changes nothing at all.
@(test)
test_apply_root_correction_turns_only_roots :: proc(t: ^testing.T) {
	skeleton := Skeleton{
		parents = slice.clone([]i32{-1, 0}),
		rest    = slice.clone([]Transform{transform_identity(), transform_identity()}),
	}
	defer delete(skeleton.parents)
	defer delete(skeleton.rest)

	correction := transform_rotation({0, 1, 0}, math.PI)
	apply_root_correction(&skeleton, correction)

	turned := linalg.quaternion_mul_vector3(skeleton.rest[0].rotation, [3]f32{0, 0, 1})
	testing.expect(t, abs(turned.z - (-1)) < 1e-5, "the root's rest rotation should carry the turn")
	testing.expect_value(t, skeleton.rest[1].rotation, linalg.QUATERNIONF32_IDENTITY)
}

@(test)
test_apply_root_correction_identity_changes_nothing :: proc(t: ^testing.T) {
	original := transform_rotation({1, 0, 0}, 0.4)

	skeleton := Skeleton{
		parents = slice.clone([]i32{-1}),
		rest    = slice.clone([]Transform{{rotation = original, scale = {1, 1, 1}}}),
	}
	defer delete(skeleton.parents)
	defer delete(skeleton.rest)

	apply_root_correction(&skeleton, linalg.QUATERNIONF32_IDENTITY)

	testing.expect_value(t, skeleton.rest[0].rotation, original)
}

// -----------------------------------------------------------------------
// Step 2 -- the humanoid bone map
// -----------------------------------------------------------------------

/*
	VRM 0.0's array-of-objects shape. Built by hand the way json.parse_object
	would have, including the fact that a number always tokenizes as
	json.Value's Float variant here (gltf2 parses with the library's default
	parse_integers = false) -- see parse_vrm_humanoid's doc comment.

	Every key and every string leaf is `strings.clone`d rather than a literal
	handed straight to the map, so that `free_json_object` below -- which is
	`json.destroy_value`, the same procedure `gltf2.unload` uses on a real
	parse -- can free this fixture exactly the way it frees a real one.
	`json.parse_object` always allocates the strings it hands back, so a
	fixture built out of unowned literals would be testing against a shape
	`destroy_value` never actually sees; it would also hand `delete` a
	pointer into the binary's own read-only data the first time this test
	file's cleanup ran.
*/
@(private = "file")
v0_humanoid_extensions :: proc(hips_node, spine_node: f64) -> json.Object {
	bones := make(json.Array)
	hips := make(json.Object)
	hips[strings.clone("bone")] = strings.clone("hips")
	hips[strings.clone("node")] = hips_node
	spine := make(json.Object)
	spine[strings.clone("bone")] = strings.clone("spine")
	spine[strings.clone("node")] = spine_node
	append(&bones, json.Value(hips))
	append(&bones, json.Value(spine))

	humanoid := make(json.Object)
	humanoid[strings.clone("humanBones")] = bones

	vrm := make(json.Object)
	vrm[strings.clone("humanoid")] = humanoid

	extensions := make(json.Object)
	extensions[strings.clone("VRM")] = vrm
	return extensions
}

// VRM 1.0's object-keyed shape, carrying the same two bones as the 0.0
// fixture above -- the two are asserted to parse to the identical
// Vrm_Humanoid, which is the whole point of having two shapes feed one type.
@(private = "file")
v1_humanoid_extensions :: proc(hips_node, spine_node: f64) -> json.Object {
	hips := make(json.Object)
	hips[strings.clone("node")] = hips_node
	spine := make(json.Object)
	spine[strings.clone("node")] = spine_node

	bones := make(json.Object)
	bones[strings.clone("hips")] = hips
	bones[strings.clone("spine")] = spine

	humanoid := make(json.Object)
	humanoid[strings.clone("humanBones")] = bones

	vrmc := make(json.Object)
	vrmc[strings.clone("humanoid")] = humanoid

	extensions := make(json.Object)
	extensions[strings.clone("VRMC_vrm")] = vrmc
	return extensions
}

@(private = "file")
free_json_object :: proc(object: json.Object) {
	json.destroy_value(json.Value(object))
}

@(test)
test_parse_vrm_humanoid_v0_array_shape :: proc(t: ^testing.T) {
	extensions := v0_humanoid_extensions(5, 12)
	defer free_json_object(extensions)

	humanoid := parse_vrm_humanoid(json.Value(extensions), .V0)

	node, found := humanoid.bones[Vrm_Bone.HIPS].?
	testing.expect(t, found, "hips should have parsed")
	testing.expect_value(t, node, u32(5))

	node, found = humanoid.bones[Vrm_Bone.SPINE].?
	testing.expect(t, found, "spine should have parsed")
	testing.expect_value(t, node, u32(12))

	_, found = humanoid.bones[Vrm_Bone.HEAD].?
	testing.expect(t, !found, "a bone the file never mapped must report not-found, not node 0")
}

// The two shapes carrying the same two bones must produce the same
// Vrm_Humanoid -- the container differs, the meaning does not.
@(test)
test_parse_vrm_humanoid_v0_and_v1_agree :: proc(t: ^testing.T) {
	v0_extensions := v0_humanoid_extensions(5, 12)
	defer free_json_object(v0_extensions)
	v1_extensions := v1_humanoid_extensions(5, 12)
	defer free_json_object(v1_extensions)

	v0_humanoid := parse_vrm_humanoid(json.Value(v0_extensions), .V0)
	v1_humanoid := parse_vrm_humanoid(json.Value(v1_extensions), .V1)

	testing.expect_value(t, v0_humanoid.bones[Vrm_Bone.HIPS], v1_humanoid.bones[Vrm_Bone.HIPS])
	testing.expect_value(t, v0_humanoid.bones[Vrm_Bone.SPINE], v1_humanoid.bones[Vrm_Bone.SPINE])
}

// A file with no humanoid block at all -- a non-VRM file that nonetheless
// reached this code path, or a VRM file missing the block -- parses to every
// bone unmapped rather than a crash.
@(test)
test_parse_vrm_humanoid_empty_for_missing_block :: proc(t: ^testing.T) {
	humanoid := parse_vrm_humanoid(nil, .NONE)

	_, found := humanoid.bones[Vrm_Bone.HIPS].?
	testing.expect(t, !found, "no extensions at all should leave every bone unmapped")
}

/*
	The naming split this file's doc comment on Vrm_Bone calls out by name:
	VRM 0.0's "leftThumbProximal" is the *base* joint (1.0 calls that one
	"leftThumbMetacarpal"), and 0.0's "leftThumbIntermediate" is the *middle*
	joint (1.0's "leftThumbProximal"). Both specs' "leftThumbDistal" mean the
	tip and agree. Getting this backwards silently swaps which joint of a
	VRoid character's thumb a game thinks it is asking for -- so this is
	pinned down directly rather than trusted to the identical-shape test above,
	which never touches a finger.
*/
@(test)
test_vrm_bone_from_name_v0_thumb_matches_v1_by_position_not_by_string :: proc(t: ^testing.T) {
	testing.expect_value(t, vrm_bone_from_name_v0("leftThumbProximal"), Vrm_Bone.LEFT_THUMB_METACARPAL)
	testing.expect_value(t, vrm_bone_from_name_v0("leftThumbIntermediate"), Vrm_Bone.LEFT_THUMB_PROXIMAL)
	testing.expect_value(t, vrm_bone_from_name_v0("leftThumbDistal"), Vrm_Bone.LEFT_THUMB_DISTAL)

	testing.expect_value(t, vrm_bone_from_name_v1("leftThumbMetacarpal"), Vrm_Bone.LEFT_THUMB_METACARPAL)
	testing.expect_value(t, vrm_bone_from_name_v1("leftThumbProximal"), Vrm_Bone.LEFT_THUMB_PROXIMAL)
	testing.expect_value(t, vrm_bone_from_name_v1("leftThumbDistal"), Vrm_Bone.LEFT_THUMB_DISTAL)
}

// vrm_bone on a model with no humanoid block at all -- the zero-valued
// Vrm_Humanoid every non-VRM Model gets -- must report every bone not found,
// never node 0. This is the bug Maybe(u32) exists to rule out; see
// Vrm_Humanoid's doc comment.
@(test)
test_vrm_bone_not_found_on_zero_value_model :: proc(t: ^testing.T) {
	model: Model
	_, found := vrm_bone(model, .HIPS)
	testing.expect(t, !found, "a model with no humanoid block must not claim node 0 for every bone")
}

// -----------------------------------------------------------------------
// Step 3 -- retargeting
// -----------------------------------------------------------------------

/*
	Two two-node chains -- root(0) <- bone(1) in each -- built with
	*deliberately different* rest rotations on both nodes, the way VRoid's
	near-axis-aligned bones and an Unreal-style rig's along-the-bone ones
	really do disagree (see vrm.md's measured angles). If retarget_animations
	had a bracket transposed or applied on the wrong side, this is the shape
	of rig where it would produce a plausible-looking but wrong number rather
	than an obvious garbage one -- which is the failure this test exists to
	catch.

	Torn down by the two destroy_ calls a game would use: destroy_model frees
	the destination's skeleton and clips, destroy_animation_source the
	source's.
*/
@(private = "file")
retarget_fixture :: proc() -> (dst: Model, src: Animation_Source, names: []Vrm_Bone_Name) {
	src_root_rot := transform_rotation({1, 0, 0}, 0.3)
	src_bone_rot := transform_rotation({0, 1, 0}, 0.6)
	dst_root_rot := transform_rotation({0, 0, 1}, 0.5)
	dst_bone_rot := transform_rotation({1, 0, 0}, -0.8)

	src = Animation_Source{
		skeleton = Skeleton{
			parents = slice.clone([]i32{-1, 0}),
			rest    = slice.clone([]Transform{
				{rotation = src_root_rot, scale = {1, 1, 1}},
				{rotation = src_bone_rot, scale = {1, 1, 1}},
			}),
			order = slice.clone([]u32{0, 1}),
			names = slice.clone([]string{strings.clone("root"), strings.clone("bone")}),
		},
		animations = nil,
	}

	dst = Model{
		skeleton = Skeleton{
			parents = slice.clone([]i32{-1, 0}),
			rest    = slice.clone([]Transform{
				{rotation = dst_root_rot, scale = {1, 1, 1}},
				{rotation = dst_bone_rot, scale = {1, 1, 1}},
			}),
			order = slice.clone([]u32{0, 1}),
			names = slice.clone([]string{strings.clone("dst_root"), strings.clone("dst_bone")}),
			skins = slice.clone([]Model_Skin{{joints = slice.clone([]u32{0, 1})}}),
		},
	}
	dst.vrm_humanoid.bones[Vrm_Bone.HIPS]  = u32(0)
	dst.vrm_humanoid.bones[Vrm_Bone.SPINE] = u32(1)

	names = slice.clone([]Vrm_Bone_Name{{"root", .HIPS}, {"bone", .SPINE}})
	return dst, src, names
}

@(private = "file")
destroy_retarget_fixture :: proc(dst: ^Model, src: ^Animation_Source, names: []Vrm_Bone_Name) {
	destroy_model(dst)
	destroy_animation_source(src)
	delete(names)
}

// The property the whole conjugation exists to guarantee, stated exactly as
// vrm.md states it: the destination bone's global orientation after
// retargeting equals the source's own delta-from-its-rest, carried onto the
// destination's rest. Checked by rotating a reference vector through both
// sides independently -- not by comparing quaternion components, which a
// sign flip (q and -q are the same rotation) would fail for no real reason.
@(test)
test_retarget_rotation_matches_source_delta_from_rest :: proc(t: ^testing.T) {
	dst, src, names := retarget_fixture()
	defer destroy_retarget_fixture(&dst, &src, names)

	// The source's authored pose: some arbitrary absolute local rotation for
	// "bone", unrelated to its own rest value -- a track never stores a delta.
	authored := transform_rotation({0, 0, 1}, 1.1)

	src.animations = slice.clone([]Model_Animation{
		{
			name = strings.clone("clip"),
			duration = 0,
			tracks = slice.clone([]Animation_Track{
				{
					node = 1, path = .ROTATION, interpolation = .STEP,
					times = slice.clone([]f32{0}),
					quats = slice.clone([]quaternion128{authored}),
				},
			}),
		},
	})

	added := retarget_animations(&dst, src, {names = names})
	testing.expect_value(t, added, 1)
	testing.expect_value(t, len(dst.animations), 1)
	testing.expect_value(t, len(dst.animations[0].tracks), 1)

	retargeted_track := dst.animations[0].tracks[0]
	testing.expect_value(t, retargeted_track.node, u32(1))
	L_d := retargeted_track.quats[0]

	// Expected, independently: G_d(t) = [G_s(t) * G_s_rest^-1] * G_d_rest,
	// with both roots static (no track on node 0) so G_*_parent(t) ==
	// G_*_parent_rest.
	G_s_parent_rest := src.skeleton.rest[0].rotation
	G_s_rest        := linalg.quaternion_mul_quaternion(G_s_parent_rest, src.skeleton.rest[1].rotation)
	G_s_t           := linalg.quaternion_mul_quaternion(G_s_parent_rest, authored)

	G_d_parent_rest := dst.skeleton.rest[0].rotation
	G_d_rest        := linalg.quaternion_mul_quaternion(G_d_parent_rest, dst.skeleton.rest[1].rotation)

	delta := linalg.quaternion_mul_quaternion(G_s_t, linalg.quaternion_inverse(G_s_rest))
	G_d_expected := linalg.quaternion_mul_quaternion(delta, G_d_rest)

	// Actual, the way animator_resolve would compute it from the retargeted
	// local: G_d(t) = G_d_parent_rest * L_d(t).
	G_d_actual := linalg.quaternion_mul_quaternion(G_d_parent_rest, L_d)

	reference := [3]f32{0.4, 0.7, -0.2} // arbitrary and non-axis-aligned on purpose
	expected_v := linalg.quaternion_mul_vector3(G_d_expected, reference)
	actual_v   := linalg.quaternion_mul_vector3(G_d_actual, reference)

	testing.expect(t, linalg.length(expected_v - actual_v) < 1e-4,
		"the retargeted bone's global orientation should match the source's delta-from-rest, carried onto the destination's rest")
}

// A destination bone with no counterpart in the name table (or whose model
// never mapped it) is never written by a retarget and keeps exactly the rest
// pose it already had -- the "inert degrade" vrm.md calls out for a
// spring-bone joint.
@(test)
test_retarget_leaves_unmapped_destination_bone_at_rest :: proc(t: ^testing.T) {
	dst, src, names := retarget_fixture()
	defer destroy_retarget_fixture(&dst, &src, names)

	original_root_rotation := dst.skeleton.rest[0].rotation

	src.animations = slice.clone([]Model_Animation{
		{
			name = strings.clone("clip"), duration = 0,
			tracks = slice.clone([]Animation_Track{
				{
					node = 1, path = .ROTATION, interpolation = .STEP,
					times = slice.clone([]f32{0}),
					quats = slice.clone([]quaternion128{transform_rotation({0, 0, 1}, 1.1)}),
				},
			}),
		},
	})

	retarget_animations(&dst, src, {names = names})

	for track in dst.animations[0].tracks {
		testing.expect(t, track.node != 0, "the retarget only named 'bone' -> node 1; node 0 should never be written")
	}
	testing.expect_value(t, dst.skeleton.rest[0].rotation, original_root_rotation)
}

// A source track naming a node the table has no entry for is dropped
// outright, not written to node 0 or any other guess.
@(test)
test_retarget_drops_a_source_track_with_no_mapped_bone :: proc(t: ^testing.T) {
	dst, src, names := retarget_fixture()
	defer destroy_retarget_fixture(&dst, &src, names)

	src.animations = slice.clone([]Model_Animation{
		{
			name = strings.clone("clip"), duration = 0,
			tracks = slice.clone([]Animation_Track{
				// node 99 names nothing in "src" and nothing in `names`.
				{
					node = 99, path = .ROTATION, interpolation = .STEP,
					times = slice.clone([]f32{0}),
					quats = slice.clone([]quaternion128{linalg.QUATERNIONF32_IDENTITY}),
				},
			}),
		},
	})

	added := retarget_animations(&dst, src, {names = names})
	testing.expect_value(t, added, 0)
	testing.expect_value(t, len(dst.animations), 0)
}

// Keyframe times survive a retarget exactly -- the conjugation touches the
// value at each key, never the key's own time or how many of them there are.
@(test)
test_retarget_keeps_keyframe_times_exactly :: proc(t: ^testing.T) {
	dst, src, names := retarget_fixture()
	defer destroy_retarget_fixture(&dst, &src, names)

	times := []f32{0, 0.25, 0.9}

	src.animations = slice.clone([]Model_Animation{
		{
			name = strings.clone("clip"), duration = 0.9,
			tracks = slice.clone([]Animation_Track{
				{
					node = 1, path = .ROTATION, interpolation = .LINEAR,
					times = slice.clone(times),
					quats = slice.clone([]quaternion128{
						linalg.QUATERNIONF32_IDENTITY,
						transform_rotation({0, 1, 0}, 0.2),
						transform_rotation({0, 1, 0}, 0.4),
					}),
				},
			}),
		},
	})

	retarget_animations(&dst, src, {names = names})

	retargeted_times := dst.animations[0].tracks[0].times
	testing.expect_value(t, len(retargeted_times), len(times))
	for time, i in times do testing.expect_value(t, retargeted_times[i], time)
}

/*
	Retargeting adds to what a model already has rather than standing in for
	it -- a locomotion set from one file and a combat set from another both
	land, and a model that arrived with clips of its own keeps them.

	A VRM has no clips, so for the case this was built for appending and
	replacing look identical; this is the test that tells them apart, and the
	reason it exists is that replacing loses the first source's work silently.
*/
@(test)
test_retarget_appends_rather_than_replacing :: proc(t: ^testing.T) {
	dst, src, names := retarget_fixture()
	defer destroy_retarget_fixture(&dst, &src, names)

	// What a glTF model would arrive carrying, unlike a VRM.
	dst.animations = slice.clone([]Model_Animation{
		{name = strings.clone("existing"), duration = 0, tracks = {}},
	})

	one_clip :: proc(name: string) -> []Model_Animation {
		return slice.clone([]Model_Animation{
			{
				name = strings.clone(name), duration = 0,
				tracks = slice.clone([]Animation_Track{
					{
						node = 1, path = .ROTATION, interpolation = .STEP,
						times = slice.clone([]f32{0}),
						quats = slice.clone([]quaternion128{transform_rotation({0, 1, 0}, 0.3)}),
					},
				}),
			},
		})
	}

	src.animations = one_clip("walk")
	testing.expect_value(t, retarget_animations(&dst, src, {names = names}), 1)

	// A second source file, arriving separately the way a second clip set does.
	destroy_animations(src.animations)
	src.animations = one_clip("punch")
	testing.expect_value(t, retarget_animations(&dst, src, {names = names}), 1)

	testing.expect_value(t, len(dst.animations), 3)

	for want in ([]string{"existing", "walk", "punch"}) {
		if _, found := animation_index(dst, want); !found {
			testing.expectf(t, false, "%q should have survived the second retarget", want)
		}
	}
}

/*
	Adopting a rest pose replaces the transforms of same-named bones and
	nothing else -- node indices in particular survive, because the tracks
	that name them have to stay valid.

	The case this exists for is a clip file whose own rest is not the pose its
	clips were authored against; see `load_animation_source`. Getting it wrong
	by rebuilding the skeleton instead of only its rest would leave every
	track pointing at the wrong bone, which is loud, but getting it wrong by
	matching on index instead of name would be silent.
*/
@(test)
test_adopt_rest_pose_replaces_by_name_only :: proc(t: ^testing.T) {
	pose :: proc(y: f32) -> Transform {
		return Transform{position = {0, y, 0}, rotation = linalg.QUATERNIONF32_IDENTITY, scale = {1, 1, 1}}
	}

	// Deliberately in a different order, and one bone short, so a match by
	// index would give different answers from a match by name.
	reference := Skeleton{
		parents = slice.clone([]i32{-1, 0}),
		rest    = slice.clone([]Transform{pose(20), pose(10)}),
		order   = slice.clone([]u32{0, 1}),
		names   = slice.clone([]string{strings.clone("b"), strings.clone("a")}),
	}
	defer destroy_skeleton(&reference)

	skeleton := Skeleton{
		parents = slice.clone([]i32{-1, 0, 1}),
		rest    = slice.clone([]Transform{pose(1), pose(2), pose(3)}),
		order   = slice.clone([]u32{0, 1, 2}),
		names   = slice.clone([]string{strings.clone("a"), strings.clone("b"), strings.clone("c")}),
	}
	defer destroy_skeleton(&skeleton)

	adopt_rest_pose(&skeleton, reference)

	// "a" and "b" take the reference's values, found by name rather than slot.
	testing.expect_value(t, skeleton.rest[0].position.y, f32(10))
	testing.expect_value(t, skeleton.rest[1].position.y, f32(20))

	// "c" has no counterpart and keeps what it had rather than being zeroed.
	testing.expect_value(t, skeleton.rest[2].position.y, f32(3))

	// Everything that is not the rest is untouched -- the tracks depend on it.
	testing.expect_value(t, len(skeleton.parents), 3)
	testing.expect_value(t, skeleton.parents[2], i32(1))
	testing.expect_value(t, skeleton.names[2], "c")
}

// A scale track has no case to retarget it and is dropped rather than
// guessed at -- vrm.md measured none in the pipeline this was built for, and
// a wrong guess here would silently misscale a character.
@(test)
test_retarget_drops_scale_tracks :: proc(t: ^testing.T) {
	dst, src, names := retarget_fixture()
	defer destroy_retarget_fixture(&dst, &src, names)

	src.animations = slice.clone([]Model_Animation{
		{
			name = strings.clone("clip"), duration = 0,
			tracks = slice.clone([]Animation_Track{
				{
					node = 1, path = .SCALE, interpolation = .STEP,
					times = slice.clone([]f32{0}),
					vectors = slice.clone([][3]f32{{2, 2, 2}}),
				},
			}),
		},
	})

	added := retarget_animations(&dst, src, {names = names})
	testing.expect_value(t, added, 0)
}

/*
	Hips translation: the one non-rotation case. `hips_src_node` is "root"
	here (mapped to .HIPS in the fixture) rather than some third node, so the
	scale is exactly the ratio of the two rigs' *root* rest heights, and the
	basis correction is `pre` for that same node -- both computed the same
	way a real pelvis's would be.

	The source rest position is nonzero on purpose, so a delta-from-rest
	computed against the wrong origin (e.g. against zero instead of the
	source's own rest position) would move the destination hips by the
	authored position itself rather than by its motion, and this test would
	catch that as a large, obviously wrong offset rather than a subtle one.
*/
@(test)
test_retarget_hips_translation_scales_and_reprojects :: proc(t: ^testing.T) {
	dst, src, names := retarget_fixture()
	defer destroy_retarget_fixture(&dst, &src, names)

	src.skeleton.rest[0].position = {0, 1.0, 0}
	dst.skeleton.rest[0].position = {0, 2.0, 0} // destination root sits twice as high at rest

	authored_position := [3]f32{0, 1.1, 0} // 0.1 above the source's own rest height

	src.animations = slice.clone([]Model_Animation{
		{
			name = strings.clone("clip"), duration = 0,
			tracks = slice.clone([]Animation_Track{
				{
					node = 0, path = .TRANSLATION, interpolation = .STEP,
					times = slice.clone([]f32{0}),
					vectors = slice.clone([][3]f32{authored_position}),
				},
			}),
		},
	})

	added := retarget_animations(&dst, src, {names = names})
	testing.expect_value(t, added, 1)

	track := dst.animations[0].tracks[0]
	testing.expect_value(t, track.node, u32(0))
	testing.expect_value(t, track.path, Animation_Path.TRANSLATION)

	// delta = authored - src_rest = {0, 0.1, 0}; the destination root has no
	// parent, so `pre` for it is the identity and the delta is simply scaled
	// by dst_height / src_height == 2. Expected: dst_rest + delta*2.
	got := track.vectors[0]
	testing.expect(t, abs(got.y - (2.0 + 0.2)) < 1e-4,
		"hips delta should scale by the ratio of rest heights and add onto the destination's own rest position")
	testing.expect(t, abs(got.x) < 1e-4 && abs(got.z) < 1e-4, "no horizontal motion was authored")
}

// -----------------------------------------------------------------------
// Step 4 -- proportions
// -----------------------------------------------------------------------

/*
	Two rigs with a pair of arms each and *deliberately mismatched
	proportions*: the destination is half again as tall, its shoulders are
	twice as far apart in its own scale, and its arm bones are longer than
	either of those. No single scale on the skeleton reproduces it, which is
	the case `Retarget_Fit` exists for.

	`arm_angle` swings both upper arms down about z, which is what brings the
	hands near each other; leaving it at zero leaves them out at the sides,
	half a body apart. The two tests below are the same rig in those two
	poses, because "how far apart are the hands" is the whole of what decides
	whether the pass touches them.
*/
@(private = "file")
pair_fixture :: proc() -> (dst: Model, src: Animation_Source, names: []Vrm_Bone_Name) {
	chain :: proc(hips, chest, shoulder, upper, lower: f32, labels: []string) -> Skeleton {
		ident :: linalg.QUATERNIONF32_IDENTITY
		return Skeleton{
			parents = slice.clone([]i32{-1, 0, 1, 2, 3, 1, 5, 6}),
			order   = slice.clone([]u32{0, 1, 2, 3, 4, 5, 6, 7}),
			rest    = slice.clone([]Transform{
				{position = {0, hips, 0},      rotation = ident, scale = {1, 1, 1}},
				{position = {0, chest, 0},     rotation = ident, scale = {1, 1, 1}},
				{position = {shoulder, 0, 0},  rotation = ident, scale = {1, 1, 1}},
				{position = {upper, 0, 0},     rotation = ident, scale = {1, 1, 1}},
				{position = {lower, 0, 0},     rotation = ident, scale = {1, 1, 1}},
				{position = {-shoulder, 0, 0}, rotation = ident, scale = {1, 1, 1}},
				{position = {-upper, 0, 0},    rotation = ident, scale = {1, 1, 1}},
				{position = {-lower, 0, 0},    rotation = ident, scale = {1, 1, 1}},
			}),
			names = slice.clone([]string{
				strings.clone(labels[0]), strings.clone(labels[1]), strings.clone(labels[2]),
				strings.clone(labels[3]), strings.clone(labels[4]), strings.clone(labels[5]),
				strings.clone(labels[6]), strings.clone(labels[7]),
			}),
		}
	}

	src = Animation_Source{
		skeleton = chain(1.0, 0.5, 0.05, 0.4, 0.4,
			{"pelvis", "spine_02", "upperarm_l", "lowerarm_l", "hand_l", "upperarm_r", "lowerarm_r", "hand_r"}),
	}

	dst = Model{
		skeleton = chain(1.5, 0.75, 0.10, 0.5, 0.45,
			{"hips", "chest", "arm_l", "fore_l", "hand_l", "arm_r", "fore_r", "hand_r"}),
	}
	dst.skeleton.skins = slice.clone([]Model_Skin{{joints = slice.clone([]u32{0, 1, 2, 3, 4, 5, 6, 7})}})

	dst.vrm_humanoid.bones[Vrm_Bone.HIPS]            = u32(0)
	dst.vrm_humanoid.bones[Vrm_Bone.CHEST]           = u32(1)
	dst.vrm_humanoid.bones[Vrm_Bone.LEFT_UPPER_ARM]  = u32(2)
	dst.vrm_humanoid.bones[Vrm_Bone.LEFT_LOWER_ARM]  = u32(3)
	dst.vrm_humanoid.bones[Vrm_Bone.LEFT_HAND]       = u32(4)
	dst.vrm_humanoid.bones[Vrm_Bone.RIGHT_UPPER_ARM] = u32(5)
	dst.vrm_humanoid.bones[Vrm_Bone.RIGHT_LOWER_ARM] = u32(6)
	dst.vrm_humanoid.bones[Vrm_Bone.RIGHT_HAND]      = u32(7)

	names = slice.clone([]Vrm_Bone_Name{
		{"pelvis",     .HIPS},
		{"spine_02",   .CHEST},
		{"upperarm_l", .LEFT_UPPER_ARM},
		{"lowerarm_l", .LEFT_LOWER_ARM},
		{"hand_l",     .LEFT_HAND},
		{"upperarm_r", .RIGHT_UPPER_ARM},
		{"lowerarm_r", .RIGHT_LOWER_ARM},
		{"hand_r",     .RIGHT_HAND},
	})
	return dst, src, names
}

// Both upper arms swung down by `angle`, mirrored so the two arms stay
// symmetric. At pi/2 the hands hang near the centre line, a hand's width
// apart; at 0 they stay out at the sides.
@(private = "file")
arms_down_clip :: proc(angle: f32) -> []Model_Animation {
	return slice.clone([]Model_Animation{
		{
			name     = strings.clone("pose"),
			duration = 0,
			tracks   = slice.clone([]Animation_Track{
				{
					node = 2, path = .ROTATION, interpolation = .STEP,
					times = slice.clone([]f32{0}),
					quats = slice.clone([]quaternion128{transform_rotation({0, 0, 1}, -angle)}),
				},
				{
					node = 5, path = .ROTATION, interpolation = .STEP,
					times = slice.clone([]f32{0}),
					quats = slice.clone([]quaternion128{transform_rotation({0, 0, 1}, angle)}),
				},
			}),
		},
	})
}

@(private = "file")
posed_position :: proc(skeleton: Skeleton, tracks: []Animation_Track, node: u32) -> [3]f32 {
	locals  := make([]Transform, len(skeleton.rest), context.temp_allocator)
	globals := make([]matrix[4, 4]f32, len(skeleton.rest), context.temp_allocator)
	defer delete(locals, context.temp_allocator)
	defer delete(globals, context.temp_allocator)

	sample_clip_pose(skeleton, tracks, 0, locals)
	pose_globals(skeleton, locals, globals)
	return matrix_position(globals[node])
}

// Left tip to right tip, which is the one quantity the pass is about.
@(private = "file")
posed_gap :: proc(skeleton: Skeleton, tracks: []Animation_Track, left, right: u32) -> [3]f32 {
	return posed_position(skeleton, tracks, left) - posed_position(skeleton, tracks, right)
}

/*
	The property `.PROPORTIONS` exists to guarantee: when the source holds two
	tips together, the destination holds them the same distance apart at its
	own scale -- however differently its shoulders are placed.

	Stated as the gap rather than as two positions, because the gap is what
	the correction promises and each hand's own position is what it
	deliberately leaves to the angles.
*/
@(test)
test_retarget_proportions_preserves_a_contact_gap :: proc(t: ^testing.T) {
	dst, src, names := pair_fixture()
	defer destroy_retarget_fixture(&dst, &src, names)

	src.animations = arms_down_clip(math.PI * 0.5)

	testing.expect_value(t, retarget_animations(&dst, src, {names = names}), 1)

	SCALE :: f32(1.5) // the fixture's two hips heights, 1.5 over 1.0

	want := SCALE * posed_gap(src.skeleton, src.animations[0].tracks, 4, 7)
	got  := posed_gap(dst.skeleton, dst.animations[0].tracks, 4, 7)

	testing.expect(t, linalg.length(got - want) < 1e-4,
		fmt.tprintf("hands should end up %v apart, ended up %v apart", want, got))

	// And the correction really was needed -- otherwise this fixture proves
	// nothing about the pass.
	before := dst
	before.animations = nil
	defer destroy_animations(before.animations)
	retarget_animations(&before, src, {names = names, fit = .ROTATION_ONLY})

	uncorrected := posed_gap(before.skeleton, before.animations[0].tracks, 4, 7)
	testing.expect(t, linalg.length(uncorrected - want) > 0.02,
		"the rotation-only gap should be visibly wrong, or the fixture is not testing anything")
}

/*
	The other half, and the one that was learned the hard way: two tips the
	source holds far apart are not in contact, so the pass leaves both limbs
	exactly as the angles made them.

	Without this, a hanging idle gets "corrected" -- the arm travels the
	distance the shoulder should have, and the hand ends up behind the
	character. Measured on a real pair of rigs before the fade existed: 10cm
	of it.
*/
@(test)
test_retarget_proportions_leaves_a_free_pose_alone :: proc(t: ^testing.T) {
	dst, src, names := pair_fixture()
	defer destroy_retarget_fixture(&dst, &src, names)

	src.animations = arms_down_clip(0) // arms straight out, hands a body apart

	corrected := dst
	corrected.animations = nil
	testing.expect_value(t, retarget_animations(&corrected, src, {names = names}), 1)
	defer destroy_animations(corrected.animations)

	testing.expect_value(t, retarget_animations(&dst, src, {names = names, fit = .ROTATION_ONLY}), 1)

	for node in ([]u32{4, 7}) {
		angles := posed_position(dst.skeleton, dst.animations[0].tracks, node)
		fitted := posed_position(corrected.skeleton, corrected.animations[0].tracks, node)

		testing.expect(t, linalg.length(fitted - angles) < 1e-4,
			fmt.tprintf("a hand with nothing to touch should not move; node %v went from %v to %v", node, angles, fitted))
	}
}

// `.ROTATION_ONLY` must still do what it always did: copy the angle and leave
// the keyframe alone -- one key in, one key out, still STEP.
@(test)
test_retarget_rotation_only_keeps_keys :: proc(t: ^testing.T) {
	dst, src, names := pair_fixture()
	defer destroy_retarget_fixture(&dst, &src, names)

	src.animations = arms_down_clip(math.PI * 0.5)

	testing.expect_value(t, retarget_animations(&dst, src, {names = names, fit = .ROTATION_ONLY}), 1)
	testing.expect_value(t, len(dst.animations[0].tracks), 2)

	for track in dst.animations[0].tracks {
		testing.expect_value(t, len(track.times), 1)
		testing.expect_value(t, track.interpolation, Animation_Interpolation.STEP)
	}
}

// Full weight in contact, none at a distance, and no step in between -- a
// step in the weight is a step in the pose, since this is evaluated per key.
@(test)
test_contact_weight_fades_smoothly :: proc(t: ^testing.T) {
	LIMB :: f32(1)

	testing.expect_value(t, contact_weight(0, LIMB), 1)
	testing.expect_value(t, contact_weight(0.2, LIMB), 1)
	testing.expect_value(t, contact_weight(0.8, LIMB), 0)
	testing.expect_value(t, contact_weight(5, LIMB), 0)

	// Monotonic, and continuous at both ends of the fade.
	previous := f32(1)
	for i in 0 ..= 100 {
		gap := f32(i) / 100
		w := contact_weight(gap, LIMB)
		testing.expect(t, w <= previous + 1e-6, "the weight should never rise as the gap widens")
		testing.expect(t, abs(w - previous) < 0.1, "the weight should not step")
		previous = w
	}

	// Scale-free: the same gap-to-limb ratio gives the same weight whatever
	// size the character is.
	testing.expect(t, abs(contact_weight(0.5, 1) - contact_weight(5, 10)) < 1e-6,
		"the fade should depend on the ratio, not on absolute size")
}

/*
	The solver on its own, with points picked by hand: apply the two turns the
	way the pass does and the tip must land on the target.

	Worth pinning separately because the composition is the part that is easy
	to get subtly wrong -- `mid_turn` already contains `root_turn`, and a
	version that expected the caller to combine them would pass any "does it
	move" test while missing by centimetres.
*/
@(test)
test_solve_two_bone_lands_the_tip_on_the_target :: proc(t: ^testing.T) {
	root := [3]f32{0, 0, 0}
	mid  := [3]f32{0, -1, 0}
	tip  := [3]f32{0.5, -1.8, 0}

	for target in ([][3]f32{{1.2, -0.6, 0}, {0.3, 1.4, 0}, {-0.9, -1.1, 0}, {0.2, -0.2, 0}}) {
		root_turn, mid_turn, _ := solve_two_bone(root, mid, tip, target)

		new_mid := root + linalg.quaternion_mul_vector3(root_turn, mid - root)
		new_tip := new_mid + linalg.quaternion_mul_vector3(mid_turn, tip - mid)

		testing.expect(t, linalg.length(new_tip - target) < 1e-4,
			fmt.tprintf("tip should land on %v, landed on %v", target, new_tip))

		// And the bones cannot change length doing it.
		testing.expect(t, abs(linalg.length(new_mid - root) - linalg.length(mid - root)) < 1e-5,
			"the upper bone changed length")
		testing.expect(t, abs(linalg.length(new_tip - new_mid) - linalg.length(tip - mid)) < 1e-5,
			"the lower bone changed length")
	}
}

// A target the chain cannot reach: it straightens and points at it, rather
// than folding, overshooting, or producing a NaN.
@(test)
test_solve_two_bone_clamps_an_unreachable_target :: proc(t: ^testing.T) {
	root := [3]f32{0, 0, 0}
	mid  := [3]f32{0, -1, 0}
	tip  := [3]f32{0.5, -1.8, 0}
	target := [3]f32{6, 0, 0}

	root_turn, mid_turn, _ := solve_two_bone(root, mid, tip, target)

	new_mid := root + linalg.quaternion_mul_vector3(root_turn, mid - root)
	new_tip := new_mid + linalg.quaternion_mul_vector3(mid_turn, tip - mid)

	straight := linalg.length(mid - root) + linalg.length(tip - mid)
	testing.expect(t, abs(linalg.length(new_tip - root) - straight) < 1e-4,
		"an unreachable target should leave the chain straight rather than part-folded")

	toward := linalg.dot(linalg.normalize(new_tip - root), linalg.normalize(target - root))
	testing.expect(t, toward > 0.9999, "a clamped chain should point at the target")

	testing.expect(t, new_tip.x == new_tip.x && new_tip.y == new_tip.y && new_tip.z == new_tip.z,
		"a clamped solve must not produce a NaN")
}

/*
	The bend plane comes from the chain's own geometry, and a chain too
	straight to have one keeps the plane it had.

	This is the difference between a walk and a walk with a twitch in it: the
	earlier version read the plane off the joint's offset from the *target*
	direction, which collapses mid-stride with the knee still properly bent,
	and the knee swung around the leg while the foot stayed put.
*/
@(test)
test_bend_plane_is_kept_through_straightness :: proc(t: ^testing.T) {
	root := [3]f32{0, 0, 0}
	bent := bend_plane(root, {0, -1, 0}, {0.8, -1.6, 0}, {})
	testing.expect(t, abs(abs(bent.z) - 1) < 1e-4, "a chain bent in the xy plane has a z normal")

	// Straight: nothing to read, so the hint stands.
	hint := [3]f32{0, 0, 1}
	straight := bend_plane(root, {0, -1, 0}, {0, -2, 0}, hint)
	testing.expect_value(t, straight, hint)

	// Straight with no hint at all still answers with *a* plane containing
	// the chain, rather than a zero vector the caller has to special-case.
	blind := bend_plane(root, {0, -1, 0}, {0, -2, 0}, {})
	testing.expect(t, abs(linalg.length(blind) - 1) < 1e-4, "the fallback plane should be a unit normal")
	testing.expect(t, abs(linalg.dot(blind, [3]f32{0, -1, 0})) < 1e-4, "the plane should contain the chain")

	// A target lining up with the upper bone is exactly the case that used to
	// collapse. The plane must still come out of the bend.
	aligned := bend_plane(root, {0, -1, 0}, {0.8, -1.6, 0}, {0, 0, 1})
	testing.expect(t, abs(abs(aligned.z) - 1) < 1e-4, "a bent chain's plane should not depend on any target")
}

// Every time any track has a key at, once each, in order -- the single time
// line the pass evaluates a limb on.
@(test)
test_union_track_times_sorts_and_dedupes :: proc(t: ^testing.T) {
	tracks := []Animation_Track{
		{times = []f32{0, 0.5, 1.0}},
		{times = []f32{0, 1.0}},
		{times = []f32{0.25, 0.5}},
	}

	times := union_track_times(tracks)
	defer delete(times)

	testing.expect_value(t, len(times), 4)
	testing.expect_value(t, times[0], f32(0))
	testing.expect_value(t, times[1], f32(0.25))
	testing.expect_value(t, times[2], f32(0.5))
	testing.expect_value(t, times[3], f32(1.0))
}

/*
	A pair correction that lands inside one keyframe interval is a snap, and
	this is the guard against it. Measured on the real clips, the arm pair was
	asked to move at 0.02-0.50 limb lengths per second in every clip that
	holds a grip, and at 5.69 in `Pistol_Reload` -- 10.3cm inside a single
	interval, as the support hand comes off the weapon. See
	`SHIFT_RATE_LIMIT`.
*/
@(test)
test_rate_limit_shift_passes_a_change_within_the_limit :: proc(t: ^testing.T) {
	// 1 limb length per second over a tenth of a second on a 0.4m limb is a
	// 4cm budget; a 3cm change spends less than that and arrives intact.
	got := rate_limit_shift({0, 0, 0}, {0.03, 0, 0}, 0.1, 0.4)

	testing.expect(t, linalg.length(got - [3]f32{0.03, 0, 0}) < 1e-6,
		fmt.tprintf("a change inside the budget should pass through, got %v", got))
}

@(test)
test_rate_limit_shift_clamps_a_change_beyond_the_limit :: proc(t: ^testing.T) {
	// The same 4cm budget against a 20cm demand: the result stops at the
	// budget and keeps the direction it was heading.
	got := rate_limit_shift({0, 0, 0}, {0.2, 0, 0}, 0.1, 0.4)

	testing.expect(t, abs(linalg.length(got) - 0.04) < 1e-6,
		fmt.tprintf("expected the change clamped to the 4cm budget, got %v", linalg.length(got)))
	testing.expect(t, got.x > 0 && abs(got.y) < 1e-6 && abs(got.z) < 1e-6,
		fmt.tprintf("the clamp should keep the direction, got %v", got))
}

// Clamping the *change* and not the shift: a correction already at 20cm and
// asked to stay there is not dragged back toward zero, however far from the
// origin it sits. This is what keeps a grip held for a whole clip steady.
@(test)
test_rate_limit_shift_leaves_a_large_steady_correction_alone :: proc(t: ^testing.T) {
	got := rate_limit_shift({0.2, 0, 0}, {0.2, 0, 0}, 0.1, 0.4)

	testing.expect(t, linalg.length(got - [3]f32{0.2, 0, 0}) < 1e-6,
		fmt.tprintf("an unchanged shift should be returned unchanged, got %v", got))
}

// A zero or negative interval has no budget to compute against -- the first
// keyframe of a clip, or two keys at the same time. Passing the demand
// through is the honest answer: there is no previous shift to rate-limit from.
@(test)
test_rate_limit_shift_passes_through_a_degenerate_interval :: proc(t: ^testing.T) {
	got := rate_limit_shift({0, 0, 0}, {0.2, 0, 0}, 0, 0.4)
	testing.expect(t, linalg.length(got - [3]f32{0.2, 0, 0}) < 1e-6,
		fmt.tprintf("dt of zero should pass the demand through, got %v", got))

	got = rate_limit_shift({0, 0, 0}, {0.2, 0, 0}, 0.1, 0)
	testing.expect(t, linalg.length(got - [3]f32{0.2, 0, 0}) < 1e-6,
		fmt.tprintf("a zero-length limb should pass the demand through, got %v", got))
}

/*
	The legs are not a contact pair, and this is the guard on that decision
	rather than on any one number.

	They were in `HUMANOID_PAIRS` once, on the argument that the two rigs' hip
	spans agree to 4mm so the correction would be nearly nothing. The pass is
	gated on the gap between the *feet*, which measured 0.27-0.39m wrong in
	every clip -- moving a foot up to 16.6cm, and up to 14.9cm between two
	adjacent keyframes. Two feet hold no constraint with each other; what a
	foot needs to meet is the ground. See `HUMANOID_PAIRS`.
*/
@(test)
test_humanoid_pairs_names_no_leg :: proc(t: ^testing.T) {
	legs := bit_set[Vrm_Bone]{
		.LEFT_UPPER_LEG, .LEFT_LOWER_LEG, .LEFT_FOOT, .LEFT_TOES,
		.RIGHT_UPPER_LEG, .RIGHT_LOWER_LEG, .RIGHT_FOOT, .RIGHT_TOES,
	}

	for pair in HUMANOID_PAIRS {
		for limb in ([]Retarget_Limb{pair.left, pair.right}) {
			for bone in ([]Vrm_Bone{limb.root, limb.mid, limb.tip}) {
				testing.expect(t, bone not_in legs,
					fmt.tprintf("%v is a leg bone; the pair correction does not apply to feet", bone))
			}
		}
	}
}
