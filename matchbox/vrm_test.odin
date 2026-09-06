package matchbox

/*
	VRM -- headless tests
	---------------------
	Everything here runs on hand-built data: `core:encoding/json` values
	constructed the way `json.parse_object` would have produced them, and a
	`Skeleton` built the way `build_skeleton` would have. No file, no GPU, no
	window -- see `vrm.md`'s "What can be tested without a VRM asset" for why,
	and for what is left to check against the real file instead (whether the
	corrected facing reads right to the eye).
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
