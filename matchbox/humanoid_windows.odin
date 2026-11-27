#+build windows

package matchbox

/*
	Humanoid bones (PC)
	===================
	Which node of a skeleton plays which role of a person: hips, left elbow, right foot. Retargeting
	(retarget_windows.odin) moves animation between two rigs through these roles, since the two
	rigs share nothing else: not node indices, not names, not proportions.

		humanoid, mapped := mb.map_humanoid_bones(model, mb.UNITY_BONE_NAMES)

	Windows only, like the retargeting it serves. A handheld plays clips baked into its model file and
	never retargets at runtime, so none of this is compiled for it.
*/

import "core:log"

/*
	One role in the humanoid vocabulary (VRM's, which Unity's and Unreal's mannequins also fit).
	**The three thumb bones are named the VRM 1.0 way**: `*_THUMB_METACARPAL` is the thumb's base joint
	and `*_THUMB_PROXIMAL` the middle one. Unity's `LeftThumbProximal` is the base joint, so a table written from
	Unity's enum by eye maps the whole thumb one joint out
*/
Humanoid_Bone :: enum {
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
	A model's map from humanoid role to the node playing it. The zero value has every role unmapped.
	`Maybe(u32)` rather than a `u32` with a sentinel: node 0 is a real, common index, and an untouched
	slot must not read as "node 0 plays this role". It is a value the game keeps beside its Model, not
	a field of it, because only a retargeting game has one and a Model is shared with the handhelds
*/
Humanoid_Map :: struct {
	nodes:[Humanoid_Bone]Maybe(u32),
}

/*One node name a rig uses and the role it plays. A table of these describes a naming convention*/
Humanoid_Bone_Name :: struct {
	name:string,
	bone:Humanoid_Bone,
}

/*
	The node playing `bone`, if the map has one. A **node index**, like get_node_index's, not a joint
	index: find it once at load and check `found` there, not every frame
*/
get_humanoid_node :: proc(humanoid:Humanoid_Map, bone:Humanoid_Bone) -> (node:u32, found:bool) {
	if bone == .NONE do return 0, false
	return humanoid.nodes[bone].?
}

/*
	Which of `model`'s nodes play which roles, found by matching node names against `names`. `mapped` is how many roles
	landed; 0 means the table and the rig have nothing to do with each other, which is the caller's to notice. A name the
	rig lacks is skipped and all of them are logged in one line, so a rig short a toe bone still retargets the rest.
	The first node of a name wins, as get_node_index does

	Why names and not a VRM `humanoid` block: only a VRM carries one, and a plain glTF character, the usual case, says
	the same thing in its node names. A role mapped is a claim about the rig, and retargeting does not care how it was made
*/
map_humanoid_bones :: proc(model:Model, names:[]Humanoid_Bone_Name = UNITY_BONE_NAMES) -> (humanoid:Humanoid_Map, mapped:int) {
	missing := make([dynamic]string, 0, len(names), context.temp_allocator)

	for entry in names {
		if entry.bone == .NONE do continue

		node, found := get_node_index(model, entry.name)
		if found == false {
			append(&missing, entry.name)
			continue
		}
		humanoid.nodes[entry.bone] = node
		mapped += 1
	}

	// Every missing name is the useful report for a table that mostly fits; for one that fits nothing it is the whole
	// table printed back, which says less than one sentence
	switch {
	case mapped == 0 && len(names) > 0:
		log.warnf("no humanoid roles mapped: the rig has none of the %v names in the table, %q among them", len(names), names[0].name)
	case len(missing) > 0:
		log.warnf("the rig has no node named %v, so %v of %v humanoid roles are unmapped", missing[:], len(missing), len(names))
	}
	return humanoid, mapped
}

/*
	Mesh2Motion's bone names, Unreal-style: `pelvis`, `spine_01`, `clavicle_l`, `upperarm_l`, `index_01_l`. Every name is a node
	the exported `retargeted_animations.glb` has. Quaternius's Universal Animation Library uses the same table
	(it capitalises `Head`, hence the second entry). The default source table of retarget_animations
*/
UNREAL_BONE_NAMES :: []Humanoid_Bone_Name{
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
	Unity's humanoid avatar names, the role's own name in PascalCase: `Hips`, `UpperChest`, `LeftUpperArm`. Every name is a node
	`psx_humanoid_male.glb` has. The usual destination table, as UNREAL_BONE_NAMES is the usual source one; either works at either end
	for a rig that carries the names. **No fingers**: the rig measured has none to check against, and the thumb is where a
	guess lands badly (see Humanoid_Bone)
*/
UNITY_BONE_NAMES :: []Humanoid_Bone_Name{
	{"Hips",       .HIPS},
	{"Spine",      .SPINE},
	{"Chest",      .CHEST},
	{"UpperChest", .UPPER_CHEST},
	{"Neck",       .NECK},
	{"Head",       .HEAD},

	{"LeftUpperLeg",  .LEFT_UPPER_LEG},
	{"LeftLowerLeg",  .LEFT_LOWER_LEG},
	{"LeftFoot",      .LEFT_FOOT},
	{"LeftToes",      .LEFT_TOES},
	{"RightUpperLeg", .RIGHT_UPPER_LEG},
	{"RightLowerLeg", .RIGHT_LOWER_LEG},
	{"RightFoot",     .RIGHT_FOOT},
	{"RightToes",     .RIGHT_TOES},

	{"LeftShoulder",  .LEFT_SHOULDER},
	{"LeftUpperArm",  .LEFT_UPPER_ARM},
	{"LeftLowerArm",  .LEFT_LOWER_ARM},
	{"LeftHand",      .LEFT_HAND},
	{"RightShoulder", .RIGHT_SHOULDER},
	{"RightUpperArm", .RIGHT_UPPER_ARM},
	{"RightLowerArm", .RIGHT_LOWER_ARM},
	{"RightHand",     .RIGHT_HAND},
}
