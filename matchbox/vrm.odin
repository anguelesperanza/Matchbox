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

	This is steps 1 and 2 of `vrm.md`: the container and the facing, and the
	humanoid bone map. Animation retargeting follows in a later commit.
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

// -----------------------------------------------------------------------
// Step 2 -- the humanoid bone map
// -----------------------------------------------------------------------

/*
	One structural role in VRM's humanoid vocabulary, spec-defined and the
	same set of names for both VRM versions -- only the JSON shape mapping a
	name to a node differs between them (see `parse_vrm_humanoid`).

	**The three thumb bones are named after VRM 1.0's scheme, not VRM 0.0's.**
	The two specs disagree about what the thumb's *base* joint is called --
	0.0 calls it `leftThumbProximal` and treats the middle joint as
	`leftThumbIntermediate`; 1.0 renamed the base joint to
	`leftThumbMetacarpal` and shifted `leftThumbProximal` down to mean the
	middle joint instead, matching Metacarpal/Proximal/Distal for the thumb
	the way Proximal/Intermediate/Distal already names the other four
	fingers. Picking one spelling here and mapping *both* specs' strings onto
	it by joint position (see the V0 branch of `parse_vrm_humanoid`) is what
	keeps a 0.0 file's thumb from silently reporting a `LEFT_THUMB_PROXIMAL`
	that is actually the middle bone.
*/
Vrm_Bone :: enum {
	NONE, // the zero value, so an unmapped entry is falsy

	HIPS,
	SPINE,
	CHEST,
	UPPER_CHEST,
	NECK,
	HEAD,

	LEFT_EYE,
	RIGHT_EYE,
	JAW,

	LEFT_UPPER_LEG,
	LEFT_LOWER_LEG,
	LEFT_FOOT,
	LEFT_TOES,
	RIGHT_UPPER_LEG,
	RIGHT_LOWER_LEG,
	RIGHT_FOOT,
	RIGHT_TOES,

	LEFT_SHOULDER,
	LEFT_UPPER_ARM,
	LEFT_LOWER_ARM,
	LEFT_HAND,
	RIGHT_SHOULDER,
	RIGHT_UPPER_ARM,
	RIGHT_LOWER_ARM,
	RIGHT_HAND,

	LEFT_THUMB_METACARPAL,
	LEFT_THUMB_PROXIMAL,
	LEFT_THUMB_DISTAL,
	LEFT_INDEX_PROXIMAL,
	LEFT_INDEX_INTERMEDIATE,
	LEFT_INDEX_DISTAL,
	LEFT_MIDDLE_PROXIMAL,
	LEFT_MIDDLE_INTERMEDIATE,
	LEFT_MIDDLE_DISTAL,
	LEFT_RING_PROXIMAL,
	LEFT_RING_INTERMEDIATE,
	LEFT_RING_DISTAL,
	LEFT_LITTLE_PROXIMAL,
	LEFT_LITTLE_INTERMEDIATE,
	LEFT_LITTLE_DISTAL,

	RIGHT_THUMB_METACARPAL,
	RIGHT_THUMB_PROXIMAL,
	RIGHT_THUMB_DISTAL,
	RIGHT_INDEX_PROXIMAL,
	RIGHT_INDEX_INTERMEDIATE,
	RIGHT_INDEX_DISTAL,
	RIGHT_MIDDLE_PROXIMAL,
	RIGHT_MIDDLE_INTERMEDIATE,
	RIGHT_MIDDLE_DISTAL,
	RIGHT_RING_PROXIMAL,
	RIGHT_RING_INTERMEDIATE,
	RIGHT_RING_DISTAL,
	RIGHT_LITTLE_PROXIMAL,
	RIGHT_LITTLE_INTERMEDIATE,
	RIGHT_LITTLE_DISTAL,
}

/*
	A VRM file's own map from a humanoid role to the node playing it.

	The zero value is every slot unmapped, which is what a file with no
	`humanoid` block gets -- the same "empty unless the file had one" shape as
	`Skeleton` and `[]Model_Animation` on `Model`. `Maybe(u32)` rather than the
	`i32`-with-`-1`-for-absent that `vrm.md` sketches: node 0 is a real,
	frequently-used index, and a plain `i32` defaulting to its zero value
	would make an untouched slot indistinguishable from "node 0 plays this
	role" the moment anyone constructs a `Vrm_Humanoid` without going through
	`parse_vrm_humanoid` -- a zeroed `Model{}`, which `model_load.odin` returns
	for a file with no drawable primitives, among others. `Maybe` carries
	"absent" as its own state instead of overloading a number to mean it.
*/
Vrm_Humanoid :: struct {
	bones: [Vrm_Bone]Maybe(u32),
}

/*
	The node playing `bone` in this model's humanoid map, if the file said so.

	Shaped like `node_index` on purpose -- a `u32` named `node`, not a joint
	index -- because a VRM humanoid bone is resolved from the same node array
	`skeleton.parents`/`rest`/`names` already use, and the two accessors exist
	for the same reason: find the number once, at load, and check `found`
	there rather than every frame.
*/
vrm_bone :: proc(model: Model, bone: Vrm_Bone) -> (node: u32, found: bool) {
	if bone == .NONE do return 0, false
	return model.vrm_humanoid.bones[bone].?
}

/*
	Builds a `Vrm_Humanoid` out of a parsed file's `extensions`, or an empty
	one for anything that is not VRM or carries no `humanoid` block.

	**Two shapes for the same data**, because the two specs disagree here and
	nowhere else this file cares about: VRM 0.0 writes `humanBones` as an
	array of `{bone: "hips", node: 5}` objects, VRM 1.0 as an object keyed by
	name, `humanBones.hips.node`. Both give a `node` that is a plain index
	into `data.nodes`, the same space `skeleton.rest` already uses, so nothing
	downstream of this needs to know which shape produced it.

	Every number in `extensions` arrives as `json.Value`'s `Float` variant, not
	`Integer` -- `gltf2.parse` calls `json.make_parser` with its default
	`parse_integers = false` (`gltf.odin:118`'s own `scene.(f64)` reads the
	same way), so a `node` written as a plain integer in the file still comes
	back typed as a float here. Asserting `.(f64)` is reading what the parser
	actually produced, not a defensive fallback.
*/
@(private)
parse_vrm_humanoid :: proc(extensions: gltf.Extensions, version: Vrm_Version) -> Vrm_Humanoid {
	humanoid := Vrm_Humanoid{}

	root, is_object := extensions.(json.Object)
	if !is_object do return humanoid

	switch version {
	case .V0:
		bones_array, ok := vrm_json_path(root, {"VRM", "humanoid", "humanBones"}).(json.Array)
		if !ok do return humanoid

		for entry in bones_array {
			entry_object, is_entry_object := entry.(json.Object)
			if !is_entry_object do continue

			name, has_name  := entry_object["bone"].(string)
			node, has_node  := entry_object["node"].(f64)
			if !has_name || !has_node do continue

			bone := vrm_bone_from_name_v0(name)
			if bone != .NONE do humanoid.bones[bone] = u32(node)
		}

	case .V1:
		bones_object, ok := vrm_json_path(root, {"VRMC_vrm", "humanoid", "humanBones"}).(json.Object)
		if !ok do return humanoid

		for name, value in bones_object {
			bone := vrm_bone_from_name_v1(name)
			if bone == .NONE do continue

			value_object, is_value_object := value.(json.Object)
			if !is_value_object do continue

			if node, has_node := value_object["node"].(f64); has_node {
				humanoid.bones[bone] = u32(node)
			}
		}

	case .NONE:
	}

	return humanoid
}

// Walks a chain of object keys through nested `json.Value`s, stopping and
// returning nil the moment one is missing or is not an object -- which for
// every caller here means "this file has no humanoid block", not a crash.
@(private)
vrm_json_path :: proc(root: json.Object, keys: []string) -> json.Value {
	current: json.Value = root

	for key, i in keys {
		object, is_object := current.(json.Object)
		if !is_object do return nil

		value, present := object[key]
		if !present do return nil

		current = value
		_ = i
	}

	return current
}

/*
	VRM 0.0's spelling of the humanoid vocabulary to `Vrm_Bone`.

	Everything but the thumb maps one string to one bone. The thumb does not,
	on purpose -- see `Vrm_Bone`'s doc comment for why `leftThumbProximal`
	here means the *middle* joint (`LEFT_THUMB_PROXIMAL`, in 1.0's naming) and
	not the base one.
*/
@(private)
vrm_bone_from_name_v0 :: proc(name: string) -> Vrm_Bone {
	switch name {
	case "hips":            return .HIPS
	case "spine":           return .SPINE
	case "chest":           return .CHEST
	case "upperChest":      return .UPPER_CHEST
	case "neck":            return .NECK
	case "head":            return .HEAD

	case "leftEye":         return .LEFT_EYE
	case "rightEye":        return .RIGHT_EYE
	case "jaw":             return .JAW

	case "leftUpperLeg":    return .LEFT_UPPER_LEG
	case "leftLowerLeg":    return .LEFT_LOWER_LEG
	case "leftFoot":        return .LEFT_FOOT
	case "leftToes":        return .LEFT_TOES
	case "rightUpperLeg":   return .RIGHT_UPPER_LEG
	case "rightLowerLeg":   return .RIGHT_LOWER_LEG
	case "rightFoot":       return .RIGHT_FOOT
	case "rightToes":       return .RIGHT_TOES

	case "leftShoulder":    return .LEFT_SHOULDER
	case "leftUpperArm":    return .LEFT_UPPER_ARM
	case "leftLowerArm":    return .LEFT_LOWER_ARM
	case "leftHand":        return .LEFT_HAND
	case "rightShoulder":   return .RIGHT_SHOULDER
	case "rightUpperArm":   return .RIGHT_UPPER_ARM
	case "rightLowerArm":   return .RIGHT_LOWER_ARM
	case "rightHand":       return .RIGHT_HAND

	// The base joint in 0.0's own naming; see Vrm_Bone's doc comment.
	case "leftThumbProximal":     return .LEFT_THUMB_METACARPAL
	case "leftThumbIntermediate": return .LEFT_THUMB_PROXIMAL
	case "leftThumbDistal":       return .LEFT_THUMB_DISTAL
	case "leftIndexProximal":     return .LEFT_INDEX_PROXIMAL
	case "leftIndexIntermediate": return .LEFT_INDEX_INTERMEDIATE
	case "leftIndexDistal":       return .LEFT_INDEX_DISTAL
	case "leftMiddleProximal":     return .LEFT_MIDDLE_PROXIMAL
	case "leftMiddleIntermediate": return .LEFT_MIDDLE_INTERMEDIATE
	case "leftMiddleDistal":       return .LEFT_MIDDLE_DISTAL
	case "leftRingProximal":     return .LEFT_RING_PROXIMAL
	case "leftRingIntermediate": return .LEFT_RING_INTERMEDIATE
	case "leftRingDistal":       return .LEFT_RING_DISTAL
	case "leftLittleProximal":     return .LEFT_LITTLE_PROXIMAL
	case "leftLittleIntermediate": return .LEFT_LITTLE_INTERMEDIATE
	case "leftLittleDistal":       return .LEFT_LITTLE_DISTAL

	case "rightThumbProximal":     return .RIGHT_THUMB_METACARPAL
	case "rightThumbIntermediate": return .RIGHT_THUMB_PROXIMAL
	case "rightThumbDistal":       return .RIGHT_THUMB_DISTAL
	case "rightIndexProximal":     return .RIGHT_INDEX_PROXIMAL
	case "rightIndexIntermediate": return .RIGHT_INDEX_INTERMEDIATE
	case "rightIndexDistal":       return .RIGHT_INDEX_DISTAL
	case "rightMiddleProximal":     return .RIGHT_MIDDLE_PROXIMAL
	case "rightMiddleIntermediate": return .RIGHT_MIDDLE_INTERMEDIATE
	case "rightMiddleDistal":       return .RIGHT_MIDDLE_DISTAL
	case "rightRingProximal":     return .RIGHT_RING_PROXIMAL
	case "rightRingIntermediate": return .RIGHT_RING_INTERMEDIATE
	case "rightRingDistal":       return .RIGHT_RING_DISTAL
	case "rightLittleProximal":     return .RIGHT_LITTLE_PROXIMAL
	case "rightLittleIntermediate": return .RIGHT_LITTLE_INTERMEDIATE
	case "rightLittleDistal":       return .RIGHT_LITTLE_DISTAL
	}

	return .NONE
}

// VRM 1.0's spelling of the same vocabulary. Identical to the 0.0 table
// except for the six thumb entries, which is exactly the set the two specs
// disagree about -- see Vrm_Bone's doc comment.
@(private)
vrm_bone_from_name_v1 :: proc(name: string) -> Vrm_Bone {
	switch name {
	case "hips":            return .HIPS
	case "spine":           return .SPINE
	case "chest":           return .CHEST
	case "upperChest":      return .UPPER_CHEST
	case "neck":            return .NECK
	case "head":            return .HEAD

	case "leftEye":         return .LEFT_EYE
	case "rightEye":        return .RIGHT_EYE
	case "jaw":             return .JAW

	case "leftUpperLeg":    return .LEFT_UPPER_LEG
	case "leftLowerLeg":    return .LEFT_LOWER_LEG
	case "leftFoot":        return .LEFT_FOOT
	case "leftToes":        return .LEFT_TOES
	case "rightUpperLeg":   return .RIGHT_UPPER_LEG
	case "rightLowerLeg":   return .RIGHT_LOWER_LEG
	case "rightFoot":       return .RIGHT_FOOT
	case "rightToes":       return .RIGHT_TOES

	case "leftShoulder":    return .LEFT_SHOULDER
	case "leftUpperArm":    return .LEFT_UPPER_ARM
	case "leftLowerArm":    return .LEFT_LOWER_ARM
	case "leftHand":        return .LEFT_HAND
	case "rightShoulder":   return .RIGHT_SHOULDER
	case "rightUpperArm":   return .RIGHT_UPPER_ARM
	case "rightLowerArm":   return .RIGHT_LOWER_ARM
	case "rightHand":       return .RIGHT_HAND

	case "leftThumbMetacarpal":   return .LEFT_THUMB_METACARPAL
	case "leftThumbProximal":     return .LEFT_THUMB_PROXIMAL
	case "leftThumbDistal":       return .LEFT_THUMB_DISTAL
	case "leftIndexProximal":     return .LEFT_INDEX_PROXIMAL
	case "leftIndexIntermediate": return .LEFT_INDEX_INTERMEDIATE
	case "leftIndexDistal":       return .LEFT_INDEX_DISTAL
	case "leftMiddleProximal":     return .LEFT_MIDDLE_PROXIMAL
	case "leftMiddleIntermediate": return .LEFT_MIDDLE_INTERMEDIATE
	case "leftMiddleDistal":       return .LEFT_MIDDLE_DISTAL
	case "leftRingProximal":     return .LEFT_RING_PROXIMAL
	case "leftRingIntermediate": return .LEFT_RING_INTERMEDIATE
	case "leftRingDistal":       return .LEFT_RING_DISTAL
	case "leftLittleProximal":     return .LEFT_LITTLE_PROXIMAL
	case "leftLittleIntermediate": return .LEFT_LITTLE_INTERMEDIATE
	case "leftLittleDistal":       return .LEFT_LITTLE_DISTAL

	case "rightThumbMetacarpal":   return .RIGHT_THUMB_METACARPAL
	case "rightThumbProximal":     return .RIGHT_THUMB_PROXIMAL
	case "rightThumbDistal":       return .RIGHT_THUMB_DISTAL
	case "rightIndexProximal":     return .RIGHT_INDEX_PROXIMAL
	case "rightIndexIntermediate": return .RIGHT_INDEX_INTERMEDIATE
	case "rightIndexDistal":       return .RIGHT_INDEX_DISTAL
	case "rightMiddleProximal":     return .RIGHT_MIDDLE_PROXIMAL
	case "rightMiddleIntermediate": return .RIGHT_MIDDLE_INTERMEDIATE
	case "rightMiddleDistal":       return .RIGHT_MIDDLE_DISTAL
	case "rightRingProximal":     return .RIGHT_RING_PROXIMAL
	case "rightRingIntermediate": return .RIGHT_RING_INTERMEDIATE
	case "rightRingDistal":       return .RIGHT_RING_DISTAL
	case "rightLittleProximal":     return .RIGHT_LITTLE_PROXIMAL
	case "rightLittleIntermediate": return .RIGHT_LITTLE_INTERMEDIATE
	case "rightLittleDistal":       return .RIGHT_LITTLE_DISTAL
	}

	return .NONE
}
