package matchbox

/*
	VRM
	---
	Reading what a `.vrm` file adds on top of an ordinary glTF one, and using
	it to put a VRoid character on screen facing the right way.

	See `vrm.md` in the repository root for the measurements this was written
	against -- a VRM 0.0 file's real shape and the two skeletons' rest poses,
	checked against `character.vrm` and a Mesh2Motion export rather than
	against the spec alone.

	**No VRM-specific parsing lives in `matchbox/gltf2`.** A `.vrm`'s extra
	JSON already reaches here as `data.extensions`, because the vendored
	parser stores every extension block as a raw `json.Value`
	(`Extensions :: json.Value`, `gltf2/types.odin:137`) rather than
	interpreting any of them. So this file reads `data.extensions` the way
	`model_load.odin` reads everything else the loader does not specialise
	for, and the vendored package needed no `MATCHBOX PATCH` at all.

	This is step 1 of `vrm.md`: the container and the facing. The humanoid
	bone map and animation retargeting follow in later commits.
*/

import "core:encoding/json"
import "core:math"
import "core:math/linalg"

import gltf "./gltf2"

// -----------------------------------------------------------------------
// Step 1 -- the container and the facing
// -----------------------------------------------------------------------

// Which of the two incompatible VRM specs a file's `extensions` carries, if
// either. `NONE` is also what an ordinary glTF file gets -- VRM-ness is
// detected from the data, never assumed from the extension on disk, so a
// plain `.glb` or `.gltf` pays nothing for this file existing.
Vrm_Version :: enum {
	NONE,
	V0,
	V1,
}

/*
	Reads which VRM spec, if any, a parsed file's `extensions` object carries.

	`extensions_used` and `extensions_required` are name lists
	(`gltf2/types.odin:71-72`) and say nothing about where a VRM block's own
	data lives -- that is under `extensions` itself, keyed `"VRM"` for 0.0 and
	`"VRMC_vrm"` for 1.0. Checking the name lists would tell us a file
	*mentions* VRM; checking the keyed object is what tells us the data is
	actually there to read.
*/
vrm_version :: proc(extensions: gltf.Extensions) -> Vrm_Version {
	object, is_object := extensions.(json.Object)
	if !is_object do return .NONE

	if _, has_v0 := object["VRM"]; has_v0 do return .V0
	if _, has_v1 := object["VRMC_vrm"]; has_v1 do return .V1
	return .NONE
}

/*
	The turn a VRM file's rest pose needs before it agrees with everything
	else in this package.

	VRM 0.0 avatars face +Z; VRM 1.0 avatars face -Z, the same as plain glTF
	and the facing every example here already assumes (`examples/third-person`:
	"Facing -pi/2 is along -z"). So only a 0.0 file needs correcting -- a 1.0
	one already agrees, and the identity this returns for it costs nothing at
	the two call sites that apply it.

	Measured, not guessed: before this turn, `character.vrm`'s left arm sits
	at x=-0.109 while the equivalent bone in a rig that already faces -Z sits
	at x=+0.156 -- opposite sides of the character. After it, both are
	positive and within a few centimetres of each other, which is a scale
	difference between two rigs rather than a facing one.
*/
vrm_facing_correction :: proc(version: Vrm_Version) -> quaternion128 {
	if version != .V0 do return linalg.QUATERNIONF32_IDENTITY
	return transform_rotation({0, 1, 0}, math.PI)
}
