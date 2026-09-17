package matchbox

/*
	VRM
	---
	Reading what a `.vrm` file adds on top of an ordinary glTF one, and using
	it to put a VRoid character on screen facing the right way, with a name
	for each of its bones a game can actually ask for.

	See `vrm.md` in the repository root for the measurements this was written
	against -- a VRM 0.0 file's real shape, the two skeletons' rest poses, and
	the retargeting maths below, checked against `character.vrm` and a
	Mesh2Motion export rather than against the spec alone.

	**No VRM-specific parsing lives in `matchbox/gltf2`.** A `.vrm`'s extra
	JSON already reaches here as `data.extensions`, because the vendored
	parser stores every extension block as a raw `json.Value`
	(`Extensions :: json.Value`, `gltf2/types.odin:137`) rather than
	interpreting any of them. So this file reads `data.extensions` the way
	`model_load.odin` reads everything else the loader does not specialise
	for, and the vendored package needed no `MATCHBOX PATCH` at all.

	What is deliberately not here: blend shapes, spring bone physics, MToon
	materials, node constraints, and `meta`. See `vrm.md`'s "Not in this
	document, and why" for each.

	**The reason for two of those has changed, and the answer has not.** Spring
	bones and MToon used to be ruled out as outside Matchbox's rendering-and-
	input scope; that narrowing was reversed on 2026-09-09 (CLAUDE.md's own
	"Scope" section), so neither is out of scope any more. Both are simply not
	built. MToon in particular now has an obvious shape if it is ever wanted --
	a `Shading_Model` value and one `.hlsli` under `shaders/brdf`, the same
	five places every other model costs (`shading.odin`) -- and spring bones
	want the physics this package still does not have. "Not in scope" became
	"not written", which is a weaker claim and the honest one.
*/

import "core:encoding/json"
import "core:log"
import "core:math"
import "core:math/linalg"
import "core:path/filepath"
import "core:slice"
import "core:strings"

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

// -----------------------------------------------------------------------
// Step 3 -- animation from another file, retargeted
// -----------------------------------------------------------------------

/*
	One name a source rig uses, and the humanoid role it plays.

	The destination side of a retarget is free once step 2 lands -- the VRM
	file's own `humanoid` block already says which node is `leftUpperArm`. The
	source is an ordinary glTF export with no such block, so it needs a name
	table instead, and this is one entry of it.
*/
Vrm_Bone_Name :: struct {
	name: string,
	bone: Vrm_Bone,
}

/*
	Mesh2Motion's own bone names, Unreal-style -- `pelvis`, `spine_01/02/03`,
	`clavicle_l`, `upperarm_l`, `index_01_l` and the rest. Measured directly
	against `retargeted_animations.glb`, not guessed from a naming convention:
	every name below is a node that file actually has.

	The same table, `Head` entry aside, also matches Quaternius's CC0
	"Universal Animation Library" packs (`UAL1_Standard.glb`,
	`UAL2_Standard.glb`) verbatim -- measured the same way, against those
	files' own node names. It is the same community UE-mannequin rig under
	both, which is presumably why Mesh2Motion's export agrees with it.

	Shipped as the default rather than required, since it is the pipeline
	this was built for -- pass a different `[]Vrm_Bone_Name` to
	`retarget_animations` for a source with different names. Mixamo's
	"mixamorig:Hips" convention can be added the day something needs it.
*/
UNREAL_BONE_NAMES :: []Vrm_Bone_Name{
	{"pelvis",    .HIPS},
	{"spine_01",  .SPINE},
	{"spine_02",  .CHEST},
	{"spine_03",  .UPPER_CHEST},
	{"neck_01",   .NECK},
	{"head",      .HEAD},
	{"Head",      .HEAD}, // Quaternius's Universal Animation Library capitalises this one bone; the rest of its rig matches this table verbatim

	{"thigh_l", .LEFT_UPPER_LEG},
	{"calf_l",  .LEFT_LOWER_LEG},
	{"foot_l",  .LEFT_FOOT},
	{"ball_l",  .LEFT_TOES},
	{"thigh_r", .RIGHT_UPPER_LEG},
	{"calf_r",  .RIGHT_LOWER_LEG},
	{"foot_r",  .RIGHT_FOOT},
	{"ball_r",  .RIGHT_TOES},

	{"clavicle_l", .LEFT_SHOULDER},
	{"upperarm_l", .LEFT_UPPER_ARM},
	{"lowerarm_l", .LEFT_LOWER_ARM},
	{"hand_l",     .LEFT_HAND},
	{"clavicle_r", .RIGHT_SHOULDER},
	{"upperarm_r", .RIGHT_UPPER_ARM},
	{"lowerarm_r", .RIGHT_LOWER_ARM},
	{"hand_r",     .RIGHT_HAND},

	{"thumb_01_l",  .LEFT_THUMB_METACARPAL},
	{"thumb_02_l",  .LEFT_THUMB_PROXIMAL},
	{"thumb_03_l",  .LEFT_THUMB_DISTAL},
	{"index_01_l",  .LEFT_INDEX_PROXIMAL},
	{"index_02_l",  .LEFT_INDEX_INTERMEDIATE},
	{"index_03_l",  .LEFT_INDEX_DISTAL},
	{"middle_01_l", .LEFT_MIDDLE_PROXIMAL},
	{"middle_02_l", .LEFT_MIDDLE_INTERMEDIATE},
	{"middle_03_l", .LEFT_MIDDLE_DISTAL},
	{"ring_01_l",   .LEFT_RING_PROXIMAL},
	{"ring_02_l",   .LEFT_RING_INTERMEDIATE},
	{"ring_03_l",   .LEFT_RING_DISTAL},
	{"pinky_01_l",  .LEFT_LITTLE_PROXIMAL},
	{"pinky_02_l",  .LEFT_LITTLE_INTERMEDIATE},
	{"pinky_03_l",  .LEFT_LITTLE_DISTAL},

	{"thumb_01_r",  .RIGHT_THUMB_METACARPAL},
	{"thumb_02_r",  .RIGHT_THUMB_PROXIMAL},
	{"thumb_03_r",  .RIGHT_THUMB_DISTAL},
	{"index_01_r",  .RIGHT_INDEX_PROXIMAL},
	{"index_02_r",  .RIGHT_INDEX_INTERMEDIATE},
	{"index_03_r",  .RIGHT_INDEX_DISTAL},
	{"middle_01_r", .RIGHT_MIDDLE_PROXIMAL},
	{"middle_02_r", .RIGHT_MIDDLE_INTERMEDIATE},
	{"middle_03_r", .RIGHT_MIDDLE_DISTAL},
	{"ring_01_r",   .RIGHT_RING_PROXIMAL},
	{"ring_02_r",   .RIGHT_RING_INTERMEDIATE},
	{"ring_03_r",   .RIGHT_RING_DISTAL},
	{"pinky_01_r",  .RIGHT_LITTLE_PROXIMAL},
	{"pinky_02_r",  .RIGHT_LITTLE_INTERMEDIATE},
	{"pinky_03_r",  .RIGHT_LITTLE_DISTAL},
}

/*
	Clips and the skeleton they were authored against, with no mesh and no GPU
	resources -- this exists to be retargeted onto a model with
	`retarget_animations`, not drawn.

	A whole `Model` was not reused for this because loading one uploads a mesh
	to the GPU that a retarget throws away unread -- every part, every
	texture, work spent only to be immediately freed. The loader already
	separates skeleton- and clip-building from part-gathering internally
	(`build_skeleton`, `build_animations`), so this is that seam exposed
	rather than a new one cut.
*/
Animation_Source :: struct {
	skeleton:   Skeleton,
	animations: []Model_Animation,
}

/*
	Loads a clip set and the skeleton it was authored against, from a `.glb`
	or `.gltf` (or, since both are GLB containers underneath, a `.vrm`) --
	without paying for a mesh upload this is never going to draw.

	`rest_pose_path` is the answer to a problem that will otherwise ruin a
	retarget quietly, and it is worth understanding before ignoring it.
	`retarget_animations` transfers a bone's *deviation from its rest pose*,
	which is only meaningful if the two rigs' rest poses depict the same
	physical pose. A rig exported alongside its animations frequently does not
	have the rest one would expect: the file this was built against stores
	arms-down with a wide stance, while the character it retargets onto is a
	T-pose with its feet under its hips. Retargeting between those two
	directly gives a character that walks with its arms held straight out and
	its legs crossed -- correct arithmetic on a false premise.

	So: point `rest_pose_path` at a file holding the *same rig* in the same
	pose the destination is in, and its rest is used in place of the clip
	file's own. Only the rest changes; the clips, and the node indices their
	tracks name, stay this file's. Both files must share a world frame, which
	two exports of one rig from one tool do.

	Errors match `load_model`'s: a `File_Error` for a path that could not be
	read, `Model_Error.Parse_Failed` for one that could but is not glTF.
*/
load_animation_source :: proc(path: string, rest_pose_path := "") -> (source: Animation_Source, err: Error) {
	source.skeleton, source.animations = parse_animation_file(path) or_return

	if rest_pose_path != "" {
		reference, ref_animations := parse_animation_file(rest_pose_path) or_return
		defer destroy_animations(ref_animations)
		defer destroy_skeleton(&reference)

		adopt_rest_pose(&source.skeleton, reference)
	}

	return source, nil
}

// The parse `load_animation_source` needs twice when it is given a separate
// rest pose to read -- once for the clips, once for the pose they should be
// measured against.
@(private)
parse_animation_file :: proc(path: string) -> (skeleton: Skeleton, animations: []Model_Animation, err: Error) {
	bytes := read_entire_file(path, context.allocator) or_return
	defer delete(bytes)

	ext := filepath.ext(path)
	is_glb := strings.equal_fold(ext, ".glb") || strings.equal_fold(ext, ".vrm")
	dir := filepath.dir(path)

	data, parse_err := gltf.parse(bytes, {is_glb = is_glb, gltf_dir = dir})
	if parse_err != nil {
		log.errorf("could not parse animation source %s: %v", path, parse_err)
		return {}, nil, Model_Error.Parse_Failed
	}
	defer gltf.unload(data)

	return build_skeleton(data), build_animations(data), nil
}

/*
	Replaces a skeleton's rest transforms with those of the same-named bones in
	`reference`, leaving everything else -- node indices, parents, order, skins
	-- alone, so the tracks that name those indices stay valid.

	Matched by name through a map rather than a search per bone, for the reason
	`print_skeleton` builds one: eighty bones against eighty is six thousand
	string compares to do it the direct way, once, for nothing.

	A bone the reference does not carry keeps the rest it had. That is the
	right way round: the reference is usually a skeleton-only export of the
	same rig and may legitimately lack the clip file's mesh nodes, and a bone
	with no counterpart is better left as authored than zeroed.
*/
@(private)
adopt_rest_pose :: proc(skeleton: ^Skeleton, reference: Skeleton) {
	if len(reference.rest) == 0 {
		log.error("the rest pose file has no skeleton; keeping the clip file's own rest")
		return
	}

	by_name := make(map[string]int, len(reference.names), context.temp_allocator)
	defer delete(by_name)

	for name, i in reference.names {
		if name == "" do continue
		if _, taken := by_name[name]; taken do continue // first wins, as node_index does
		by_name[name] = i
	}

	replaced := 0
	for name, i in skeleton.names {
		if name == "" do continue
		if j, found := by_name[name]; found {
			skeleton.rest[i] = reference.rest[j]
			replaced += 1
		}
	}

	log.infof("adopted a rest pose for %v of %v bones", replaced, len(skeleton.names))
}

// Gives an `Animation_Source`'s skeleton and clips back. Joins the `destroy`
// group in `destroy.odin`, per `CLAUDE.md` -- `matchbox.destroy(&clips)`
// resolves the same way `matchbox.destroy(&model)` does.
destroy_animation_source :: proc(src: ^Animation_Source) {
	destroy_skeleton(&src.skeleton)
	destroy_animations(src.animations)
	src.animations = nil
}

/*
	Every node's rest pose, as a global matrix rather than the local one
	`skeleton.rest` stores.

	The retargeting maths needs a bone's rest orientation *in the file's own
	space*, not relative to its immediate parent -- the brackets in
	`retarget_animations` compare a source bone's rest against a destination
	bone's rest, and two bones with unrelated parent chains only agree on
	anything once both are expressed the same way. This is `animator_resolve`'s
	own hierarchy walk (parents before children, via `order`), run once over
	the rest pose alone with no animator and no palette -- the two are kept
	separate because one runs every frame for a playing character and the
	other runs once, at load, for a skeleton that may never be drawn.
*/
@(private)
skeleton_rest_globals :: proc(skeleton: Skeleton, allocator := context.allocator) -> []matrix[4, 4]f32 {
	globals := make([]matrix[4, 4]f32, len(skeleton.rest), allocator)

	for node in skeleton.order {
		local  := transform_matrix(skeleton.rest[node])
		parent := skeleton.parents[node]

		if parent < 0 {
			globals[node] = local
		} else {
			globals[node] = globals[parent] * local
		}
	}

	return globals
}

// A skeleton's own name lookup, the way `node_index` looks one up on a
// `Model`. Kept separate rather than reused because `Animation_Source` has
// no `Model` to hand `node_index` -- it is a skeleton and some clips, nothing
// else -- and duplicating seven lines was cheaper than giving `node_index` a
// second signature for one caller.
@(private)
skeleton_node_named :: proc(skeleton: Skeleton, name: string) -> (node: u32, found: bool) {
	if name == "" do return 0, false

	for n, i in skeleton.names {
		if n == name do return u32(i), true
	}
	return 0, false
}

/*
	How faithfully a retarget reproduces the source's pose on a rig built to
	different proportions.

	`.PROPORTIONS` is the zero value, and so the default: it is the one that
	survives a character picking something up with both hands, and it costs
	nothing anywhere else, because it declines to touch a limb that is not
	holding onto anything. See `Retarget_Options`.
*/
Retarget_Fit :: enum {
	/*
		Joint angles, then a second pass over the hands, restoring the distance
		between them where the source holds them together. Costs a hierarchy
		walk per keyframe at load and nothing per frame afterwards; leaves
		every pose that is not a contact exactly as the angles made it.

		Feet are deliberately not corrected -- see `HUMANOID_PAIRS` for the
		measurement that took them out, and `vrm.md` for what a foot actually
		needs instead.
	*/
	PROPORTIONS,

	/*
		Joint angles alone -- the conjugation and nothing else. Exact, in the
		sense that one source keyframe becomes one destination keyframe with
		its interpolation mode intact, and wrong wherever the pose depends on
		two limbs meeting: a narrower pair of shoulders brings both hands in
		with them and the grip between them opens up.
	*/
	ROTATION_ONLY,
}

/*
	What `retarget_animations` should do, for the callers who need to say.

	Both fields are meaningful at their zero value -- an empty `names` means
	the built-in table, and `.PROPORTIONS` is the fit worth having -- so
	`retarget_animations(&model, clips)` is the whole API for the common case
	and this struct only appears when something unusual is wanted.
*/
Retarget_Options :: struct {
	// The source rig's bone names. Empty means `UNREAL_BONE_NAMES`, which is
	// what Mesh2Motion and Quaternius's library both emit.
	names: []Vrm_Bone_Name,

	fit: Retarget_Fit,
}

// One humanoid role, resolved on both rigs at once. Built while the mapping
// is walked, because both numbers are already in hand there.
@(private)
Retarget_Nodes :: struct {
	src: u32,
	dst: u32,
}

// One two-bone limb, named by the role each joint plays rather than by node
// index, so the same table serves any rig the humanoid map can describe.
@(private)
Retarget_Limb :: struct {
	root: Vrm_Bone,
	mid:  Vrm_Bone,
	tip:  Vrm_Bone,
}

/*
	The two limbs of a pair, corrected together because what needs correcting
	is the relationship *between* them.

	**This is the whole of the design, and it took three attempts to find.**
	A rotation retarget reproduces each limb's pose relative to its own root
	exactly. What it cannot reproduce is where the two roots sit relative to
	each other, because that is proportions: measured, this VRM's shoulders
	are 9cm narrower than the source's, so both hands come inward with their
	own shoulder and the gap between them -- which is what a two-handed grip
	*is* -- comes out 5.6cm wrong, on the wrong side.

	So correct the gap, and nothing else. Each tip moves half the error, the
	pair ends up in the source's own relationship at the source's scale, and
	every pose that was not about contact is left as the angles had it.

	**The two anchors tried before this, and what each one broke.** Both
	measured the tip's offset from a point on the body and scaled it, which
	corrects the gap as a side effect -- and drags a great deal else along
	with it:

	  - **from the chest**: a bone's placement inside a torso is the rigger's
	    arbitrary choice and the two rigs disagree by 6cm vertically, so an
	    idle arm that should hang reached up and back for its target, bent,
	    hand behind the character
	  - **from the midpoint of the two limb roots**: fixes that, and still
	    carries the clavicle difference -- the source pulls its shoulder 5.4cm
	    back where this VRM's half-length clavicle manages 1cm, so the arm
	    reaches back to make up the distance the shoulder did not travel

	Neither error is visible in the numbers the pass was checked against,
	because both put the hand exactly where they were asked to. They are
	visible immediately on a running character, which is the argument for
	watching one.
*/
@(private)
Retarget_Pair :: struct {
	left:  Retarget_Limb,
	right: Retarget_Limb,
}

/*
	The one pair a humanoid has that this correction can name.

	**The legs were here and were wrong, and the reason is worth keeping.**
	They were included on the argument that the correction would be nearly
	nothing: the two rigs' hip spans agree to 4mm where their shoulder spans
	are 9cm apart, so there looked to be no error to correct. That checked the
	wrong joint. The pass is gated on the gap between the *feet*, not between
	the hips, and measured across every clip in the Mesh2Motion export that
	gap is off by a steady 0.27-0.39m -- because `scale` is the ratio of hip
	*heights*, and where the feet land is driven by leg length and stance
	angle, whose ratio is a different number. So `want` asked for a stance the
	angles never produced, all the time, in every clip.

	What that cost, measured: a foot moved up to 16.6cm (`Walk_Carry`), and up
	to 14.9cm *between two adjacent keyframes* (`Run_Stealth`). A 0.27-0.39m
	foot gap also lands in the middle of `contact_weight`'s leg band --
	0.231m to 0.576m on this rig -- so the weight was partial and swung as the
	stride opened and closed, which is what put a snap in every locomotion
	clip.

	**The deeper reason it cannot be rescued by fixing `scale`:** two hands on
	one weapon are a constraint the source actually holds, and reproducing it
	is the whole point. Two feet hold no constraint with *each other*. What a
	foot needs to meet is the ground, which is a different reference and a
	different subsystem -- see `vrm.md`'s "No ground contact pass".

	Fingers are not here. They are three-bone chains, and the pair that would
	matter is a finger against the *other hand's* prop, which is not a
	relationship this table can name.

	Correcting the clavicle itself was considered and left out: it is the bone
	most responsible for the error, and asking one at 0.48x the length to
	travel the whole difference reads as a shrug.
*/
@(private)
HUMANOID_PAIRS :: []Retarget_Pair{
	{
		{.LEFT_UPPER_ARM, .LEFT_LOWER_ARM, .LEFT_HAND},
		{.RIGHT_UPPER_ARM, .RIGHT_LOWER_ARM, .RIGHT_HAND},
	},
}

/*
	Copies every clip in `src` onto `dst`, rewriting each track to drive the
	bone playing the same humanoid role, and returns how many clips landed at
	least one track.

	**Why a track cannot just be pointed at a different node.** `sample_pose`
	assigns a track's value to its node outright rather than accumulating one
	on top of another (see that procedure's doc comment), so a rotation track
	copied verbatim would force the destination bone into the *source rig's*
	rest orientation instead of reproducing the source's motion. What
	transfers between two rigs is the motion relative to each one's own rest,
	not the raw numbers -- see `vrm.md`'s "The math, and why it is cheap here"
	for the derivation this implements:

		L_d(t) = [ G_d_parent_rest⁻¹ · G_s_parent_rest ] · L_s(t) · [ G_s_rest⁻¹ · G_d_rest ]

	Both bracketed terms are constants -- rest poses, not clips -- computed once
	per mapped bone below (`pre`, `post`) and then applied to every keyframe of
	every clip that touches that bone. No resampling and no per-frame hierarchy
	walk at bake time: a keyframe goes in, a keyframe comes out, at the same
	time and with the same interpolation mode it went in with.

	**Hips translation is its own case**, not a generalisation of the above.
	Position is not rotation-invariant the way a joint's own orientation is,
	and measured (see `vrm.md`), every translation track in a Mesh2Motion
	export sits on the pelvis alone -- so this handles exactly that node
	rather than building a general "retarget a translation track" path
	nothing else needs. The rotation the pelvis's own `pre` bracket already
	represents is reused to carry a position *delta* from the source rig's
	parent frame into the destination's, and a scale -- the ratio of the two
	rigs' hip rest heights -- absorbs the difference in how tall each
	character is. A destination with no hips mapped, or a source with no
	pelvis mapped, silently skips this case: nothing to translate without both
	ends.

	**What is dropped, and why that is the right degrade.** A destination bone
	with no source counterpart (every spring-bone joint, for instance) is
	never written and keeps its rest pose -- visible and still, not wrong. A
	source bone with no destination counterpart has its track dropped; so does
	a scale track, on any bone -- retargeting one would need a third case, and
	no source measured so far needs a character to grow or shrink mid-clip.
	Quaternius's rig carries scale (and non-hips translation) tracks on nearly
	every bone in every clip where the Mesh2Motion export this was first built
	against had none, which is why the drop counts are summed and logged once
	per call below rather than once per track -- see `vrm.md`.

	**Angles are the whole of a limb's pose and not the whole of a
	character's**, which is why `options.fit` defaults to `.PROPORTIONS` and a
	second pass follows the conjugation. Each limb comes out right relative to
	its own shoulder or hip; what the angles cannot carry is where those sit
	relative to *each other*, because that is proportions. Measured on
	`character.vrm`, whose shoulders are 9cm narrower than the source's: the
	pistol reload's supporting hand lands 5.6cm past the hand it is meant to
	sit under, on the wrong side of it. `correct_paired_limbs` puts it back,
	and touches nothing that is not a pair in contact. See `vrm.md`.
*/
retarget_animations :: proc(
	dst:     ^Model,
	src:     Animation_Source,
	options: Retarget_Options = {},
) -> (added: int) {
	if !is_model_skinned(dst^) || len(src.skeleton.rest) == 0 do return 0

	// Nil rather than `UNREAL_BONE_NAMES` as the field's default, because a
	// struct's zero value is what a caller writing `{fit = .ROTATION_ONLY}`
	// gets for every field they did not mention -- so the table has to be
	// chosen here, where an empty one still means "the built-in".
	names := options.names if len(options.names) > 0 else UNREAL_BONE_NAMES

	dst_globals := skeleton_rest_globals(dst.skeleton, context.temp_allocator)
	src_globals := skeleton_rest_globals(src.skeleton, context.temp_allocator)
	defer delete(dst_globals, context.temp_allocator)
	defer delete(src_globals, context.temp_allocator)

	src_to_dst := make(map[u32]u32, len(names), context.temp_allocator)
	pre        := make(map[u32]quaternion128, len(names), context.temp_allocator)
	post       := make(map[u32]quaternion128, len(names), context.temp_allocator)
	defer delete(src_to_dst)
	defer delete(pre)
	defer delete(post)

	// Which node plays each humanoid role, on each side. `src_to_dst` above
	// answers "where does this track go"; the proportion pass asks the other
	// question -- "which node is the left elbow" -- and a role-keyed map is
	// the direct way to ask it rather than a scan of `names` per limb.
	roles := make(map[Vrm_Bone]Retarget_Nodes, len(names), context.temp_allocator)
	defer delete(roles)

	hips_src_node: u32
	has_hips: bool
	hips_scale: f32 = 1

	for entry in names {
		src_node, found_src := skeleton_node_named(src.skeleton, entry.name)
		if !found_src do continue

		dst_node, found_dst := vrm_bone(dst^, entry.bone)
		if !found_dst do continue

		src_to_dst[src_node] = dst_node
		roles[entry.bone] = Retarget_Nodes{src = src_node, dst = dst_node}

		src_parent_rotation := linalg.QUATERNIONF32_IDENTITY
		if p := src.skeleton.parents[src_node]; p >= 0 {
			src_parent_rotation = transform_from_matrix(src_globals[p]).rotation
		}
		dst_parent_rotation := linalg.QUATERNIONF32_IDENTITY
		if p := dst.skeleton.parents[dst_node]; p >= 0 {
			dst_parent_rotation = transform_from_matrix(dst_globals[p]).rotation
		}

		src_rest_rotation := transform_from_matrix(src_globals[src_node]).rotation
		dst_rest_rotation := transform_from_matrix(dst_globals[dst_node]).rotation

		pre[src_node]  = linalg.quaternion_mul_quaternion(linalg.quaternion_inverse(dst_parent_rotation), src_parent_rotation)
		post[src_node] = linalg.quaternion_mul_quaternion(linalg.quaternion_inverse(src_rest_rotation), dst_rest_rotation)

		if entry.bone == .HIPS {
			hips_src_node = src_node
			has_hips = true

			src_height := src_globals[src_node][1, 3]
			dst_height := dst_globals[dst_node][1, 3]
			if src_height != 0 do hips_scale = dst_height / src_height
		}
	}

	result := make([dynamic]Model_Animation, 0, len(dst.animations) + len(src.animations))
	for clip in dst.animations do append(&result, clip)

	// Counted rather than logged inline: a rig with a scale track or a
	// non-hips translation track on most of its bones (Quaternius's Universal
	// Animation Library does, on nearly every bone, in every clip -- unlike
	// the Mesh2Motion export this was first measured against) turns one
	// warning per track into thousands of near-identical lines. One summary
	// per call says the same thing and stays legible.
	dropped_translation := 0
	dropped_scale        := 0

	for clip in src.animations {
		tracks := make([dynamic]Animation_Track, 0, len(clip.tracks))

		for track in clip.tracks {
			dst_node, mapped := src_to_dst[track.node]
			if !mapped do continue

			switch track.path {
			case .ROTATION:
				quats := make([]quaternion128, len(track.quats))
				for q, i in track.quats {
					quats[i] = linalg.quaternion_normalize(
						linalg.quaternion_mul_quaternion(
							linalg.quaternion_mul_quaternion(pre[track.node], q),
							post[track.node]))
				}
				append(&tracks, Animation_Track{
					node = dst_node, path = .ROTATION, interpolation = track.interpolation,
					times = clone_track_times(track.times), quats = quats,
				})

			case .TRANSLATION:
				if !has_hips || track.node != hips_src_node {
					dropped_translation += 1
					continue
				}

				src_rest_pos := src.skeleton.rest[track.node].position
				dst_rest_pos := dst.skeleton.rest[dst_node].position

				vectors := make([][3]f32, len(track.vectors))
				for v, i in track.vectors {
					delta := linalg.quaternion_mul_vector3(pre[track.node], v - src_rest_pos)
					vectors[i] = dst_rest_pos + delta * hips_scale
				}
				append(&tracks, Animation_Track{
					node = dst_node, path = .TRANSLATION, interpolation = track.interpolation,
					times = clone_track_times(track.times), vectors = vectors,
				})

			case .SCALE:
				dropped_scale += 1
				continue
			}
		}

		if len(tracks) == 0 {
			delete(tracks)
			continue
		}

		if options.fit == .PROPORTIONS {
			correct_paired_limbs(dst^, src, clip, &tracks, roles, hips_scale)
		}

		duration: f32 = 0
		for t in tracks do duration = max(duration, t.times[len(t.times) - 1])

		append(&result, Model_Animation{
			name     = strings.clone(clip.name),
			duration = duration,
			tracks   = tracks[:],
		})
		added += 1
	}

	if dropped_translation > 0 {
		log.warnf("retarget_animations: dropped %v translation track(s) on a node other than the mapped hips; only hips translation is retargeted", dropped_translation)
	}
	if dropped_scale > 0 {
		log.warnf("retarget_animations: dropped %v scale track(s); scale retargeting is not supported", dropped_scale)
	}

	delete(dst.animations)
	dst.animations = result[:]

	return added
}

// A real allocation, not a borrow of the source clip's own -- the retargeted
// clip owns its tracks independently, so `destroy_animation_source` on the
// source and `destroy_model` on the destination each free their own copy
// rather than one of them freeing memory the other still points at.
@(private)
clone_track_times :: proc(times: []f32) -> []f32 {
	out := make([]f32, len(times))
	copy(out, times)
	return out
}

// -----------------------------------------------------------------------
// Step 4 -- proportions
// -----------------------------------------------------------------------

/*
	Rewrites one retargeted clip's limb tracks so that where the source holds
	a pair of limbs in contact -- two hands on a weapon, hands clasped -- the
	destination holds them the same way at its own scale.

	**Why the conjugation is not enough**, as the measurement rather than the
	principle: a rotation track carries a joint angle, and each limb does come
	out right relative to its own root. What no angle carries is where the two
	roots sit relative to each other. Between `character.vrm` and a
	Mesh2Motion export the shoulders are 9cm apart in that sense -- and
	unevenly, clavicle 0.48x against upper arm 1.21x, so no single scale on
	the skeleton absorbs it. Both hands come inward with their own shoulder
	and the gap between them, which is what a two-handed grip *is*, ends up
	5.6cm wrong and on the wrong side.

	**So the gap is what gets corrected, and only the gap.** Each tip moves
	half the error, both limbs re-solved onto the result:

		error = scale * (tip_left_src - tip_right_src) - (tip_left_dst - tip_right_dst)

	That it can be written in world space at all, with no basis change between
	the rigs, is a property the conjugation already bought: the two rigs come
	out of the retarget with the same world orientation, `post` and its
	inverse cancelling, so a world-space offset means the same thing on both
	sides.

	**`scale` is the whole rig's** -- the ratio of hip rest heights, the same
	number the hips translation uses. A gap is a distance across the body
	rather than along a limb, so it belongs to the body's scale; and measured,
	the arm's own ratio is 1.118 against the body's 1.113, a millimetre over
	the length of an arm.

	**Two designs were tried before this one and both were wrong on screen
	while being right in the numbers**, which is the thing worth remembering.
	Each measured a tip's offset from some point on the body and scaled it --
	from the chest, then from the midpoint of the two limb roots -- and each
	put the hand exactly where it was told. Both reproduce a pose the
	destination's *skeleton* cannot hold honestly: the source pulls its
	shoulder back on a clavicle twice the length of this VRM's, so matching
	the hand makes the arm travel the distance the shoulder did not, and an
	idle that should hang reaches backwards, bent, with the hand behind the
	character. Correcting a relationship *between* limbs asks nothing of
	either limb's own shape.

	See `contact_weight` for why a pair with its hands apart is left alone
	entirely, and `bend_plane` for why the joint does not swing when a limb
	passes through straight. A target beyond a limb's reach clamps to the
	straight-limb pose, which after the contact fade is a case this has not
	been observed to reach: the correction is half a gap error, and a gap
	error large enough to outreach an arm belongs to two limbs that are not
	touching.
*/
@(private)
correct_paired_limbs :: proc(
	dst:       Model,
	src:       Animation_Source,
	src_clip:  Model_Animation,
	tracks:    ^[dynamic]Animation_Track,
	roles:     map[Vrm_Bone]Retarget_Nodes,
	scale:     f32,
) -> (corrected: int) {
	limb_mapped :: proc(roles: map[Vrm_Bone]Retarget_Nodes, limb: Retarget_Limb) -> bool {
		if _, has := roles[limb.root]; !has do return false
		if _, has := roles[limb.mid];  !has do return false
		if _, has := roles[limb.tip];  !has do return false
		return true
	}

	/*
		A limb this clip never animates is left entirely alone, rather than
		corrected into the source's rest pose. Both are defensible as "the
		pose the source has", and this one keeps a promise the other breaks: a
		clip that drives nothing below the chest still drives nothing below
		the chest after retargeting, so a caller layering it over a walk with
		`animation_mask_below` gets the same tracks it would have got before
		this pass existed.

		Both limbs of a pair have to be animated, not either: correcting a
		gap by moving a limb the clip is deliberately leaving alone is the
		same broken promise wearing the other shoe.
	*/
	limb_animated :: proc(roles: map[Vrm_Bone]Retarget_Nodes, clip: Model_Animation, limb: Retarget_Limb) -> bool {
		root := roles[limb.root]
		mid  := roles[limb.mid]

		for track in clip.tracks {
			if track.path != .ROTATION do continue
			if track.node == root.src || track.node == mid.src do return true
		}
		return false
	}

	pairs := make([dynamic]Retarget_Pair, 0, len(HUMANOID_PAIRS), context.temp_allocator)
	defer delete(pairs)

	for pair in HUMANOID_PAIRS {
		if !limb_mapped(roles, pair.left) || !limb_mapped(roles, pair.right) do continue
		if !limb_animated(roles, src_clip, pair.left) || !limb_animated(roles, src_clip, pair.right) do continue
		append(&pairs, pair)
	}

	if len(pairs) == 0 do return 0

	limbs := make([dynamic]Retarget_Limb, 0, 2 * len(pairs), context.temp_allocator)
	defer delete(limbs)

	for pair in pairs {
		append(&limbs, pair.left)
		append(&limbs, pair.right)
	}

	times := union_track_times(tracks[:], context.temp_allocator)
	defer delete(times, context.temp_allocator)
	if len(times) == 0 do return 0

	dst_locals  := make([]Transform, len(dst.skeleton.rest), context.temp_allocator)
	src_locals  := make([]Transform, len(src.skeleton.rest), context.temp_allocator)
	dst_globals := make([]matrix[4, 4]f32, len(dst.skeleton.rest), context.temp_allocator)
	src_globals := make([]matrix[4, 4]f32, len(src.skeleton.rest), context.temp_allocator)
	defer delete(dst_locals,  context.temp_allocator)
	defer delete(src_locals,  context.temp_allocator)
	defer delete(dst_globals, context.temp_allocator)
	defer delete(src_globals, context.temp_allocator)

	// Two keys per limb, root and mid, each the length of the sample times.
	// Filled in the time loop and handed to the tracks after it, because a
	// track cannot be rewritten while the pose it is being read from is still
	// being sampled.
	root_keys := make([][]quaternion128, len(limbs), context.temp_allocator)
	mid_keys  := make([][]quaternion128, len(limbs), context.temp_allocator)
	defer delete(root_keys, context.temp_allocator)
	defer delete(mid_keys,  context.temp_allocator)

	for i in 0 ..< len(limbs) {
		root_keys[i] = make([]quaternion128, len(times))
		mid_keys[i]  = make([]quaternion128, len(times))
	}

	// Last keyframe's shift per pair, so `rate_limit_shift` can see how fast
	// the correction is being asked to move. One per pair rather than per
	// limb: both limbs of a pair are moved by the same vector, opposite signs,
	// so limiting it once limits both consistently -- clamping each side
	// separately could let them disagree about how much of the gap was closed.
	prev_shift := make([][3]f32, len(pairs), context.temp_allocator)
	defer delete(prev_shift, context.temp_allocator)

	// Last keyframe's bend plane per limb, carried forward so a limb passing
	// through straight keeps its joint on the side it was already on. See
	// `bend_plane`.
	planes := make([][3]f32, len(limbs), context.temp_allocator)
	defer delete(planes, context.temp_allocator)

	// Whether any keyframe asked this pair for anything. A clip whose hands
	// are never near each other leaves with the tracks it arrived with --
	// same keys, same interpolation, same values -- rather than a re-baked
	// copy of itself on a denser time line.
	touched := make([]bool, len(pairs), context.temp_allocator)
	defer delete(touched, context.temp_allocator)

	for time, key in times {
		sample_clip_pose(src.skeleton, src_clip.tracks, time, src_locals)
		sample_clip_pose(dst.skeleton, tracks[:], time, dst_locals)
		pose_globals(src.skeleton, src_locals, src_globals)
		pose_globals(dst.skeleton, dst_locals, dst_globals)

		for pair, p in pairs {
			left_tip  := roles[pair.left.tip]
			right_tip := roles[pair.right.tip]

			/*
				Half the error each, faded out as the two tips separate. The
				gap the source holds between them, at this rig's scale,
				against the gap the angles produced -- and the two limbs split
				the difference, so neither is singled out as the one that was
				wrong. Nothing else about either limb's pose is touched.
			*/
			want := scale * (matrix_position(src_globals[left_tip.src]) - matrix_position(src_globals[right_tip.src]))
			have := matrix_position(dst_globals[left_tip.dst]) - matrix_position(dst_globals[right_tip.dst])

			reach := limb_reach(dst_globals, roles, pair.left)
			shift := 0.5 * contact_weight(linalg.length(want), reach) * (want - have)

			// The correction is not allowed to move faster than a hand
			// plausibly does. See `rate_limit_shift`.
			if key > 0 {
				shift = rate_limit_shift(prev_shift[p], shift, time - times[key - 1], reach)
			}
			prev_shift[p] = shift

			for limb, side in ([]Retarget_Limb{pair.left, pair.right}) {
				i := 2 * p + side

				root := roles[limb.root]
				mid  := roles[limb.mid]
				tip  := roles[limb.tip]

				/*
					Nothing to correct at this keyframe: keep what the angles
					said, to the bit. Re-solving a chain onto the place it
					already is looks like it should be free and is not -- a
					straight limb has no bend plane to read, so the solve
					would place its joint in whatever plane the fallback
					picked and move it by a fraction of a millimetre. Small,
					and still a pose nobody asked to change.
				*/
				if linalg.length(shift) <= 1e-7 {
					root_keys[i][key] = dst_locals[root.dst].rotation
					mid_keys[i][key]  = dst_locals[mid.dst].rotation

					/*
						The hint still has to keep up. Leaving `planes[i]` alone
						here lets it go stale across every uncorrected keyframe,
						so when a pair comes back into contact the solve is
						handed a plane from before the limb moved -- and if the
						chain happens to be straight at that moment,
						`bend_plane` has nothing of its own to read and uses
						that stale answer, putting the joint on the wrong side.
						That is the knee-swing this pass already fixed once; it
						came back through the door marked "nothing to do here".
					*/
					planes[i] = bend_plane(
						matrix_position(dst_globals[root.dst]),
						matrix_position(dst_globals[mid.dst]),
						matrix_position(dst_globals[tip.dst]),
						planes[i])
					continue
				}
				touched[p] = true

				target := matrix_position(dst_globals[tip.dst]) + (side == 0 ? shift : -shift)

				root_turn, mid_turn, plane := solve_two_bone(
					matrix_position(dst_globals[root.dst]),
					matrix_position(dst_globals[mid.dst]),
					matrix_position(dst_globals[tip.dst]),
					target,
					planes[i],
				)
				planes[i] = plane

				root_world := root_turn * transform_from_matrix(dst_globals[root.dst]).rotation
				mid_world  := mid_turn  * transform_from_matrix(dst_globals[mid.dst]).rotation

				/*
					Back to locals, and the mid bone's is taken against the
					root's *new* world rotation rather than the one just
					sampled. Turning the root has already carried the mid bone
					with it -- that is what a hierarchy does -- so measuring
					against the old parent applies the root's correction a
					second time. Off by exactly that much is not obviously
					wrong on screen, which is how it survives: the limb still
					reaches roughly where it should and misses by centimetres.
				*/
				parent_rotation := linalg.QUATERNIONF32_IDENTITY
				if parent := dst.skeleton.parents[root.dst]; parent >= 0 {
					parent_rotation = transform_from_matrix(dst_globals[parent]).rotation
				}

				root_keys[i][key] = linalg.quaternion_inverse(parent_rotation) * root_world
				mid_keys[i][key]  = linalg.quaternion_inverse(root_world) * mid_world
			}
		}
	}

	for pair, p in pairs {
		if !touched[p] {
			delete(root_keys[2 * p]);     delete(mid_keys[2 * p])
			delete(root_keys[2 * p + 1]); delete(mid_keys[2 * p + 1])
			continue
		}

		for limb, side in ([]Retarget_Limb{pair.left, pair.right}) {
			i := 2 * p + side
			write_rotation_track(tracks, roles[limb.root].dst, times, root_keys[i])
			write_rotation_track(tracks, roles[limb.mid].dst,  times, mid_keys[i])
		}
		corrected += 1
	}

	return corrected
}

/*
	Global-space turns for a two-bone chain that put `tip` on `target`,
	keeping the plane the chain is already bent in. The second turn includes
	the first, so each is applied to its bone's own world rotation and neither
	caller has to know the order.

	**Built by placing the joints and reading the rotations back off**, rather
	than by accumulating law-of-cosines angle deltas. The delta form needs a
	signed bend axis, which has to come from a cross product of the current
	pose -- and that flips sign between a left limb and a right one, or when a
	limb passes through straight mid-clip. Placing two points has no sign in
	it to get wrong. Measured against the arithmetic form on `Pistol_Reload`:
	0.00cm from the target on every frame, where the delta form sat 3.25cm out
	on average with the target well inside reach.

	Only swings are produced -- each bone is turned onto a new direction and
	not about its own length -- so the twist the conjugation put into the
	forearm and the hand survives this pass untouched.

	`hint` is the previous keyframe's bend plane, and `normal` hands this
	one's back for the next call. See `bend_plane` for what goes wrong
	without it.
*/
@(private)
solve_two_bone :: proc(root, mid, tip, target: [3]f32, hint: [3]f32 = {}) -> (root_turn, mid_turn: quaternion128, normal: [3]f32) {
	upper := linalg.length(mid - root)
	lower := linalg.length(tip - mid)
	if upper <= 0 || lower <= 0 do return linalg.QUATERNIONF32_IDENTITY, linalg.QUATERNIONF32_IDENTITY, hint

	reach := linalg.length(target - root)
	if reach <= 1e-6 do return linalg.QUATERNIONF32_IDENTITY, linalg.QUATERNIONF32_IDENTITY, hint

	// Outside these two bounds the triangle has no solution at all: further
	// than both bones laid end to end is out of reach, nearer than their
	// difference is inside the fold. Both clamp to the nearest pose the chain
	// can actually hold.
	span := clamp(reach, abs(upper - lower) + 1e-6, upper + lower - 1e-6)

	direction := (target - root) / reach

	normal = bend_plane(root, mid, tip, hint)
	if linalg.length(normal) <= 0 do return linalg.QUATERNIONF32_IDENTITY, linalg.QUATERNIONF32_IDENTITY, hint

	// In the bend plane, square to the target direction, pointing the way the
	// joint already sticks out.
	pole := linalg.cross(direction, normal)
	if linalg.length(pole) < 1e-6 do return linalg.QUATERNIONF32_IDENTITY, linalg.QUATERNIONF32_IDENTITY, normal
	pole = linalg.normalize(pole)

	cosine := clamp((upper * upper + span * span - lower * lower) / (2 * upper * span), -1, 1)
	sine   := math.sqrt(max(0, 1 - cosine * cosine))

	new_mid := root + upper * (cosine * direction + sine * pole)
	new_tip := root + span * direction

	root_turn = rotation_between(mid - root, new_mid - root)
	mid_turn  = rotation_between(
		linalg.quaternion_mul_vector3(root_turn, tip - mid),
		new_tip - new_mid,
	) * root_turn

	return root_turn, mid_turn, normal
}

/*
	How much of a pair's gap error to correct, given how far apart the source
	holds the two tips and how long the limb is.

	**This is the difference between fixing a grip and wrecking an idle.**
	What a rotation retarget gets wrong about a pair of limbs is their
	relationship, and that only *matters* where the relationship is contact --
	two hands on one weapon, hands clasped, a hand steadying the other wrist.
	Correcting it everywhere else does visible damage, because the arm is made
	to travel distance the shoulder should have: measured on this VRM's idle,
	whose source pulls its right shoulder 9cm back on a clavicle twice the
	length of the VRM's, forcing the hands to match reaches the arm 10cm
	backwards and reads exactly as "the right hand is behind the character".

	Contact is not a thing a glTF file records, so it is inferred from the one
	signal there is: how close the source holds them. Both thresholds are in
	units of the limb's own length, so they mean the same thing on a child
	model and on an ogre. Measured on the clips in hand, with a 0.435m arm:
	the pistol's two-handed hold sits at 0.07m and corrects fully; the same
	clip's reach for a magazine at 0.38m and the idle's hanging arms at 0.45m
	are left exactly as the angles made them.

	Smooth rather than a threshold, because the weight is evaluated per
	keyframe and a step in it is a step in the pose -- the hands would jump
	as they came together. `smoothstep`'s flat ends matter as much as its
	middle: a pose hovering near the boundary does not shimmer.
*/
@(private)
contact_weight :: proc(gap, limb_length: f32) -> f32 {
	if limb_length <= 0 do return 1

	near := 0.30 * limb_length
	far  := 0.75 * limb_length

	if gap <= near do return 1
	if gap >= far  do return 0

	t := (gap - near) / (far - near)
	return 1 - t * t * (3 - 2 * t)
}

/*
	How fast the pair correction may change, in limb lengths per second.

	**Picked from the gap in the measurements, not tuned.** `contact_weight`
	fades on how far apart the source holds the two tips, which is the right
	signal and says nothing about how fast that distance is allowed to change.
	Where a clip separates the hands quickly -- a reload, taking the support
	hand off the grip to reach for a magazine -- the weight falls most of the
	way inside one keyframe interval, and the correction that was holding the
	grip together lets go all at once. Measured on the arm pair, as the peak
	rate the correction was asked to move at:

		Pistol_Idle    0.02      Pistol_Shoot   0.50
		Walk_Carry     0.04      Pistol_Reload  5.69   <- 10.3cm in one interval

	Everything that is not spiking sits at or under 0.50; the one that is
	sits an order of magnitude above it. 1.0 has a factor of two of headroom
	over the highest honest clip and a factor of five under the spike, so it
	is a threshold with real space on both sides rather than a number fitted
	to one animation.

	In limb lengths rather than metres for `contact_weight`'s own reason: so
	it means the same thing on a child model and on an ogre.
*/
@(private)
SHIFT_RATE_LIMIT :: f32(1.0)

/*
	`wanted`, held back to a speed a limb could plausibly move at.

	Clamps the *change* rather than the shift itself, so a correction that is
	already large and steady -- a grip held for a whole clip -- is untouched,
	and only the moment it is asked to appear or vanish is spread out. The
	direction of the change is kept and only its length is cut, which means
	the correction still heads where the gap says it should; it just takes
	more than one keyframe to get there.

	Trailing by design: after a fast separation this keeps correcting for a
	few keyframes longer than `contact_weight` alone would. That is the
	trade, and it is the right way round -- a grip that releases slightly late
	reads as a hand lingering, where one that releases instantly reads as a
	snap.
*/
@(private)
rate_limit_shift :: proc(previous, wanted: [3]f32, dt, limb_length: f32) -> [3]f32 {
	if dt <= 0 || limb_length <= 0 do return wanted

	step     := wanted - previous
	distance := linalg.length(step)

	limit := SHIFT_RATE_LIMIT * limb_length * dt
	if distance <= limit do return wanted

	return previous + step * (limit / distance)
}

// A limb's length in the pose it is currently in, root to mid to tip. The
// yardstick `contact_weight` measures a gap against, so that "close" means
// the same thing whatever size the character is.
@(private)
limb_reach :: proc(globals: []matrix[4, 4]f32, roles: map[Vrm_Bone]Retarget_Nodes, limb: Retarget_Limb) -> f32 {
	root := matrix_position(globals[roles[limb.root].dst])
	mid  := matrix_position(globals[roles[limb.mid].dst])
	tip  := matrix_position(globals[roles[limb.tip].dst])
	return linalg.length(mid - root) + linalg.length(tip - mid)
}

/*
	The plane a two-bone chain is bent in, as its normal: which way the elbow
	or the knee points, which is the one thing about the original pose that a
	position target does not determine.

	**Taken from the chain's own geometry, not from its offset perpendicular
	to the target**, and this is the difference between a walk and a walk with
	a twitch in it. The perpendicular-offset form collapses whenever the
	target happens to line up with the upper bone -- which happens mid-stride,
	with the knee still properly bent -- and what is left is numerical noise
	with a direction. The foot stays put, because the foot is what is being
	solved for, and the knee swings around the leg. Measured on `Walk_Formal`:
	the knee moved 10.6cm between two adjacent keys where the source moved
	3.9cm, against 5.3cm for 5.4cm under the rotation-only path.

	`cross(upper, root_to_tip)` only collapses when the chain really is
	straight -- and a straight chain genuinely has no plane, so there is
	nothing to read and the previous keyframe's answer is carried forward
	instead. That keeps the joint where it was through the moment of
	straightness rather than letting it pick a new side on the way out, which
	is what continuity means here. Baking in time order is what makes the
	hint available; nothing else in this pass depends on the order.
*/
@(private)
bend_plane :: proc(root, mid, tip: [3]f32, hint: [3]f32) -> [3]f32 {
	upper  := mid - root
	span   := tip - root
	normal := linalg.cross(upper, span)

	// sin of the angle at the joint, so the test is "how straight is it" and
	// not "how long is it" -- an absolute length would call a small limb
	// straight and a large one bent at the same angle.
	scale := linalg.length(upper) * linalg.length(span)
	if scale > 0 && linalg.length(normal) / scale > 0.02 do return linalg.normalize(normal)

	if linalg.length(hint) > 0 do return hint

	// Nothing to go on at all: the first key of a clip that opens with a
	// straight limb. Any plane containing the limb will do, since a straight
	// chain looks the same in all of them -- and by the time it bends, the
	// bend itself will have taken over.
	fallback := linalg.cross(span, [3]f32{0, 0, 1})
	if linalg.length(fallback) < 1e-6 do fallback = linalg.cross(span, [3]f32{0, 1, 0})
	if linalg.length(fallback) < 1e-6 do return {}
	return linalg.normalize(fallback)
}

// The shortest turn taking `from`'s direction onto `to`'s. Odin's linalg has
// no such procedure in this version, and the antiparallel case is the reason
// to write it once here rather than inline: the cross product vanishes there,
// so the axis has to be picked rather than computed.
@(private)
rotation_between :: proc(from, to: [3]f32) -> quaternion128 {
	a := linalg.normalize0(from)
	b := linalg.normalize0(to)
	if linalg.length(a) <= 0 || linalg.length(b) <= 0 do return linalg.QUATERNIONF32_IDENTITY

	cosine := clamp(linalg.dot(a, b), -1, 1)
	if cosine > 0.999999 do return linalg.QUATERNIONF32_IDENTITY

	if cosine < -0.999999 {
		axis := linalg.cross(a, [3]f32{1, 0, 0})
		if linalg.length(axis) < 1e-6 do axis = linalg.cross(a, [3]f32{0, 1, 0})
		return transform_rotation(axis, math.PI)
	}

	return transform_rotation(linalg.cross(a, b), math.acos(cosine))
}

// A global matrix's translation, which is all the proportion pass wants from
// most of the poses it builds.
@(private)
matrix_position :: proc(m: matrix[4, 4]f32) -> [3]f32 {
	return {m[0, 3], m[1, 3], m[2, 3]}
}

// `sample_pose` for a clip that is not on a `Model` yet -- the source's, and
// the destination's part-built track list. Same rule: from the rest pose
// every time, so a joint no track touches stays where the file put it.
@(private)
sample_clip_pose :: proc(skeleton: Skeleton, clip_tracks: []Animation_Track, time: f32, into: []Transform) {
	copy(into, skeleton.rest)

	for track in clip_tracks {
		if int(track.node) >= len(into) do continue
		sample_track(track, time, &into[track.node])
	}
}

// `skeleton_rest_globals`' hierarchy walk over an arbitrary pose rather than
// the rest one, writing into a buffer the caller reuses across samples --
// this runs once per keyframe per clip, which is often enough that allocating
// per call would be the expensive part of the whole pass.
@(private)
pose_globals :: proc(skeleton: Skeleton, locals: []Transform, into: []matrix[4, 4]f32) {
	for node in skeleton.order {
		local  := transform_matrix(locals[node])
		parent := skeleton.parents[node]

		if parent < 0 {
			into[node] = local
		} else {
			into[node] = into[parent] * local
		}
	}
}

/*
	Every distinct time any of `tracks` has a key at, in order.

	The proportion pass needs a whole limb evaluated at one instant, so it
	needs a single time line rather than each track's own. Measured on the
	Mesh2Motion export, taking the union costs nothing: every clip in it has
	at most two distinct time arrays -- one dense LINEAR one for the bones
	that move, and a two-key STEP one for the bones that do not -- so the
	union is the dense array plus, at most, its own endpoints. A fixed-rate
	resample was the obvious alternative and would have thrown away exactly
	the fidelity this file did not need to lose.
*/
@(private)
union_track_times :: proc(tracks: []Animation_Track, allocator := context.allocator) -> []f32 {
	total := 0
	for track in tracks do total += len(track.times)

	gathered := make([dynamic]f32, 0, total, context.temp_allocator)
	defer delete(gathered)

	for track in tracks do append(&gathered, ..track.times)
	slice.sort(gathered[:])

	out := make([dynamic]f32, 0, len(gathered), allocator)
	for time in gathered {
		if len(out) > 0 && out[len(out) - 1] == time do continue
		append(&out, time)
	}

	return out[:]
}

// Puts `quats` on the track driving `node`'s rotation, replacing whatever was
// there. Replacing rather than appending because two rotation tracks on one
// node is not a blend -- `sample_pose` assigns, so the second would simply
// win, silently and depending on order.
@(private)
write_rotation_track :: proc(tracks: ^[dynamic]Animation_Track, node: u32, times: []f32, quats: []quaternion128) {
	for &track in tracks {
		if track.node != node || track.path != .ROTATION do continue

		delete(track.times)
		delete(track.quats)

		track.times         = clone_track_times(times)
		track.quats         = quats
		track.interpolation = .LINEAR
		return
	}

	append(tracks, Animation_Track{
		node = node, path = .ROTATION, interpolation = .LINEAR,
		times = clone_track_times(times), quats = quats,
	})
}
