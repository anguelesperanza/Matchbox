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
	document, and why" for each -- the short version is that spring bones and
	MToon are out of Matchbox's rendering-and-input scope per `refactor.md`,
	and the rest are blocked on subsystems (morph targets) this package does
	not have yet.
*/

import "core:encoding/json"
import "core:log"
import "core:math"
import "core:math/linalg"
import "core:path/filepath"
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
*/
retarget_animations :: proc(
	dst:   ^Model,
	src:   Animation_Source,
	names: []Vrm_Bone_Name = UNREAL_BONE_NAMES,
) -> (added: int) {
	if !is_model_skinned(dst^) || len(src.skeleton.rest) == 0 do return 0

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

	hips_src_node: u32
	has_hips: bool
	hips_scale: f32 = 1

	for entry in names {
		src_node, found_src := skeleton_node_named(src.skeleton, entry.name)
		if !found_src do continue

		dst_node, found_dst := vrm_bone(dst^, entry.bone)
		if !found_dst do continue

		src_to_dst[src_node] = dst_node

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
