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

	added := retarget_animations(&dst, src, names)
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

	retarget_animations(&dst, src, names)

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

	added := retarget_animations(&dst, src, names)
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

	retarget_animations(&dst, src, names)

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
	testing.expect_value(t, retarget_animations(&dst, src, names), 1)

	// A second source file, arriving separately the way a second clip set does.
	destroy_animations(src.animations)
	src.animations = one_clip("punch")
	testing.expect_value(t, retarget_animations(&dst, src, names), 1)

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

	added := retarget_animations(&dst, src, names)
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

	added := retarget_animations(&dst, src, names)
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
