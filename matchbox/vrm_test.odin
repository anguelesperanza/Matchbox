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
