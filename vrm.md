# Importing a VRoid model directly -- VRM 0.0 and VRM 1.0

## Why

The pipeline for a VRoid character today is: export `.vrm` from VRoid Studio,
convert it to `.glb`, import that into Mesh2Motion to attach an animation set,
export again. That round trip is what damaged the character in
`games/third-person-game` -- the clothing/body clipping, and (measured below)
a rebuilt skeleton with different names, a different bone count, and the
spring-bone joints thrown away.

The goal is to stop converting: load the `.vrm` as it came out of VRoid, and
put an animation set on top of it. Then the model can be replaced whenever
without redoing the animation work, and nothing lossy sits between the
authoring tool and the game.

**A `.vrm` file's container is already a glTF Binary.** Checked directly
against `character.vrm`:

```
character.vrm: glTF binary model, version 2, length 10784996 bytes
00000000: 676c 5446 0200 0000 ...    glTF............
```

Both VRM 0.0 and VRM 1.0 mandate this -- a `.vrm` is a `.glb` with extra JSON
under `extensions`, never the JSON-plus-separate-buffers form of plain glTF.

## What was measured, not assumed

### The parser already reads a VRM file

`character.vrm` was renamed to `.glb` and loaded through `load_model`
**completely unmodified**, to find out whether the glTF parser tolerates a VRM
file's extra JSON or chokes on it. It loaded:

```
model: 124 nodes, 3 skin(s), 121 joints in the largest, 13 part(s)
no animations: the file has a skeleton but no clips to move it
```

Two things the pristine file has that the Mesh2Motion output does not:

- **The original VRoid bone names** -- `J_Bip_C_Hips`, `J_Bip_C_Spine`,
  `J_Bip_C_UpperChest` -- against the converted file's `pelvis`, `spine_01`,
  `spine_03`. 124 nodes against 80, and 3 skins against 13.
- **Spring-bone joints**, present as ordinary skeleton nodes: `J_Sec_Hair1_01`
  through `_14`, `J_Sec_L_Bust1`, `J_Sec_L_TopsUpperArmInside_01`. The
  conversion dropped every one.

And the gap this plan exists to close: **zero animation clips.** A `.vrm` does
not carry a clip set; that was Mesh2Motion's whole contribution.

`Extensions :: json.Value` (`gltf2/types.odin:137`) means VRM's data was
already reaching Matchbox as raw JSON on `data.extensions`. **Nothing in the
vendored `matchbox/gltf2` needs to change for any of this plan** -- no
`MATCHBOX PATCH`.

### The asset on hand

`games/third-person-game/assets/vroid/character.vrm` is **VRM 0.0**
(`extensions.VRM.specVersion == "0.0"`), carrying `humanoid`,
`blendShapeMaster`, `firstPerson`, `secondaryAnimation`, `materialProperties`
and `meta`. Its `humanBones` is the **array form**, 54 entries, camelCase
names, node indices straight into the node array:

```
[{"bone": "hips", "node": 1, "useDefaultValues": true},
 {"bone": "leftUpperLeg", "node": 101, ...}, ...]
```

Node 1 is `J_Bip_C_Hips`, which agrees with the skeleton dump. Its
`extensionsRequired` is empty, so this particular file would load even under a
strict reader.

**A VRM 1.0 file arrived after the work landed** -- `character1.vrm`, the same
character re-exported: `VRMC_vrm` at specVersion 1.0, `humanBones` in the
object form with 54 keys, 150 nodes, and `VRMC_springBone` /
`VRMC_materials_mtoon` alongside. Both versions were then checked through
`load_model` against raw values read out of the files independently, and the
pair make one discriminating test rather than two separate ones:

```
                       raw in file    what load_model reports
character.vrm  (0.0)     -0.1086            +0.1086   correction applied
character1.vrm (1.0)     +0.1086            +0.1086   correction not applied
```

That is `leftUpperArm`'s world X. The 0.0 file is turned and the 1.0 file is
left alone, and both land in the same place -- which is the whole point of
step 1, and would have failed loudly in one direction or the other if the
version check were inverted or missing. All nine probed humanoid bones
resolved on both files, from the array form and the object form respectively.

### The two skeletons do not share a rest pose

Global rest orientations of corresponding bones, pristine `.vrm` against the
Mesh2Motion `.glb`, and the same comparison with a 180-degree turn about Y
applied to the VRM side (the VRM 0.0 facing correction, see step 1):

```
bone pair                                  raw   after Y180
J_Bip_C_Hips / pelvis                    16.5d       166.7d
J_Bip_C_Spine / spine_01                 13.5d       166.7d
J_Bip_C_UpperChest / spine_03            13.5d       166.7d
J_Bip_L_UpperArm / upperarm_l           161.1d       169.6d
J_Bip_L_Hand / hand_l                   170.9d       151.5d
J_Bip_L_LowerLeg / calf_l               178.1d       171.7d
raw:        max 178.1d   mean 101.6d
after Y180: max 177.3d   mean 162.9d
```

The rest poses disagree by 100-170 degrees per bone, and **no single global
correction fixes it** -- the residual is neither zero nor constant. The two
rigs use different per-bone axis conventions, which is ordinary: VRoid's bones
sit near world-axis-aligned, Unreal-style rigs point bones down their own
length.

The Y180 correction is still right, and the *positions* prove it: before it,
VRoid's left arm sits at x=-0.109 while the converted file's `upperarm_l` sits
at x=+0.156 -- opposite sides. After it, +0.109 against +0.156, and every
corresponding bone lands within 0.03-0.2 units, which is proportion
difference, not handedness.

**Conclusion: copying tracks across by index cannot work.** Step 3 needs
rest-pose-relative retargeting. Two further measurements make that cheap
rather than expensive:

- **The hierarchies correspond one-to-one.** Every chain checked matches in
  depth and in role:
  ```
  vrm: J_Bip_L_Hand <- J_Bip_L_LowerArm <- J_Bip_L_UpperArm <- J_Bip_L_Shoulder <- J_Bip_C_UpperChest
  glb: hand_l       <- lowerarm_l       <- upperarm_l       <- clavicle_l       <- spine_03
  vrm: J_Bip_C_Head <- J_Bip_C_Neck <- J_Bip_C_UpperChest <- J_Bip_C_Chest <- J_Bip_C_Spine <- J_Bip_C_Hips
  glb: head         <- neck_01     <- spine_03           <- spine_02      <- spine_01      <- pelvis
  ```
- **Almost everything is rotation.** Across all 31 clips: **2046 rotation
  channels, 31 translation channels, and every translation track is on
  `pelvis`.** No scale tracks at all. So the general case is rotation-only,
  and hips translation is one special case rather than a pervasive problem.

## Step 1 -- the container and the facing

**Accept `.vrm` as GLB.** `model_load.odin:71`'s
`is_glb := strings.equal_fold(filepath.ext(path), ".glb")` becomes true for
`.vrm` as well. Both VRM versions guarantee the binary form, so this reads a
spec promise rather than sniffing.

**Detect the version.** `data.extensions["VRM"]` means 0.0;
`data.extensions["VRMC_vrm"]` means 1.0; neither means an ordinary glTF file
and nothing else in this document applies. Read the parsed `extensions`
object, not `extensions_used`/`extensions_required` -- those are name lists
(`gltf2/types.odin:71-72`) and the data lives under `extensions`.

**The facing correction.** VRM 0.0 avatars face **+Z**; VRM 1.0 avatars face
**-Z**, matching plain glTF and everything else in this package
(`examples/third-person`: "Facing -pi/2 is along -z"). Uncorrected, a VRM 0.0
character stands backwards to every camera and `facing_rotation` in the
package -- and the measurement above shows it mirrored left-to-right against
the converted rig, which is the same fact seen from the side.

**Where the correction lands, and the trap.** A skinned mesh's vertices are
placed entirely by the joint palette, never by the mesh node's own transform
(`animator_resolve` divides that back out already). So for the ordinary case
-- one skinned character -- a 180-degree turn about Y baked into the
**skeleton's root rest transform** in `build_skeleton` is enough, and
`animator_resolve` carries it to everything below. A file with a static,
unskinned accessory additionally needs the same correction seeded into
`gather_node`'s initial parent matrix in `model_from_gltf` (currently
`linalg.MATRIX4F32_IDENTITY`). **Applying it to only one of the two paths is
the failure to test against**: a character whose skeleton faces one way and
whose static props face the other reads as "mostly working."

**Leave `extensionsRequired` unenforced.** The glTF spec says a loader should
refuse a file whose required extensions it does not implement; measured,
Matchbox parses that list and never checks it (`gltf2/gltf.odin:116-117`), and
VRM 1.0 normally lists `VRMC_vrm` as required. Staying permissive is the same
call already made for unrecognised material properties (D8) and is what makes
a best-effort import possible at all.

## Step 2 -- the humanoid bone map

A plain glTF file has no standard name for "the spine," which is why
`examples/animation-layers` hardcodes `UPPER_BODY_ROOT :: "spine_02"` with a
comment telling the next person to go and find out what their own file calls
it. A VRM file does have one: both versions carry a `humanoid` block mapping a
fixed, spec-defined vocabulary (`hips`, `spine`, `chest`, `upperChest`,
`neck`, `head`, `leftUpperArm`, `rightUpperLeg`, and the rest -- roughly
twenty structural bones plus optional fingers, eyes and jaw; the exact
required/optional split is a spec lookup at implementation time, not something
to freeze here) onto the node index that plays that role **in that file**.

**Two shapes to parse.** VRM 0.0 writes `humanoid.humanBones` as an array of
`{bone: "hips", node: 5}`; VRM 1.0 writes it as an object keyed by name,
`humanoid.humanBones.hips.node`. Same vocabulary, different container. A
`node` is a plain index into `data.nodes`, and `Skeleton.parents`/`rest`/
`names` are already indexed exactly that way (`build_skeleton` walks
`for node, i in data.nodes`), so no remapping is needed to turn a VRM bone
reference into a node index the rest of the package already understands.

```odin
Vrm_Bone :: enum {
	NONE,          // the zero value, so an unmapped entry is falsy
	HIPS,
	SPINE,
	CHEST,
	UPPER_CHEST,
	NECK,
	HEAD,
	LEFT_SHOULDER,
	LEFT_UPPER_ARM,
	// ... the rest of the spec's set
}

Vrm_Humanoid :: struct {
	bones: [Vrm_Bone]i32, // node index, or -1 where this file maps nothing
}
```

`Model` gains `vrm_humanoid: Vrm_Humanoid`, zeroed for a file that carries no
`humanoid` block -- the same way `skeleton` and `animations` are already
"empty unless the file had one." One accessor, shaped like `node_index` on
purpose:

```odin
vrm_bone :: proc(model: Model, bone: Vrm_Bone) -> (node: u32, found: bool)
```

## Step 3 -- animation from another file, retargeted

**What it is for.** The `.vrm` has no clips; a Mesh2Motion (or Mixamo, or any
other) export has clips authored against its own rebuilt skeleton. Step 3
copies those clips onto the VRM model, rewritten to drive the VRM's bones.
Once that is done the clips are ordinary `Model_Animation` data sitting on
`model.animations`, so `play_animation`, `animation_index`, the layer system
and the masks all keep working untouched -- no change to `update_animator`, no
new type threaded through the frame loop, no per-frame cost.

### The math, and why it is cheap here

A track stores an **absolute local rotation**, and `sample_pose` assigns it
outright rather than accumulating. So a source track cannot simply be pointed
at a different bone: it would force that bone into the *source rig's*
orientation instead of performing the source's *motion*.

What transfers is the motion relative to rest. Writing `G` for global rest
rotations and `L(t)` for the animated local rotation, the destination wants
its global to follow the source's delta from rest:

```
G_d(t) = [ G_s(t) · G_s_rest⁻¹ ] · G_d_rest
```

Expanding both sides into locals, and using that the destination bone's parent
is the mapped counterpart of the source bone's parent (**true here -- the
hierarchies were measured to correspond one-to-one**), everything
time-dependent cancels except the source's own local:

```
L_d(t) = [ G_d_parent_rest⁻¹ · G_s_parent_rest ] · L_s(t) · [ G_s_rest⁻¹ · G_d_rest ]
             \_______________  _______________/                \______  ______/
                             \/                                       \/
                      constant, per bone                       constant, per bone
```

Both brackets are **constants computed once from the two rest poses**. So
retargeting a rotation track is a fixed pre- and post-multiply applied to each
keyframe value. No resampling, no hierarchical evaluation at bake time, no
runtime cost: keyframe times and interpolation modes carry across exactly, one
source key to one destination key.

This is worth stating plainly because the obvious alternative -- resample the
source hierarchy at some fixed rate and bake new keys -- is what a general
retargeter has to do, and it costs both fidelity and memory. The 1:1
correspondence measured above is what buys the cheap version.

### The cases that are not that

- **Hips translation.** Measured: every translation track in the source is on
  `pelvis`. Position is not rotation-invariant, so it needs the basis
  correction applied and a scale for the height difference between the two
  rigs (the hips sit at y=0.908 in the VRM and y=0.871 in the converted file;
  the ratio of hips rest height is the natural scale factor). Handle the hips
  as its own small case rather than trying to generalise translation.
- **Scale tracks.** None in the source. Drop them, and log if one appears.
- **A destination bone with no source counterpart** -- every spring-bone hair
  joint, for instance -- simply keeps its rest pose. That is the correct
  inert degrade: visible and still, not wrong.
- **A source bone with no destination counterpart** -- its track is dropped.

### Naming: where the correspondence comes from

The destination side is free once step 2 lands: the VRM humanoid block already
says which node is `leftUpperArm`. The source side is a plain glTF file with
no such block, so it needs a name table. Measured, Mesh2Motion emits
Unreal-style names -- `pelvis`, `spine_01/02/03`, `neck_01`, `clavicle_l`,
`upperarm_l`, `lowerarm_l`, `hand_l`, `thigh_l`, `calf_l`, `foot_l`, `ball_l`,
plus `index_01_l` style fingers.

Ship that table as the built-in default, since it is the pipeline actually in
use, and let a caller pass its own:

```odin
Vrm_Bone_Name :: struct { name: string, bone: Vrm_Bone }

// Unreal-style, which is what Mesh2Motion emits. Mixamo's "mixamorig:Hips"
// convention can be added the day something needs it.
UNREAL_BONE_NAMES :: []Vrm_Bone_Name{...}
```

### API

Loading a whole `Model` just to steal its clips would upload a mesh to the GPU
and immediately waste it, so the clips get their own entry point. The loader
already separates `build_skeleton`/`build_animations` from part gathering, so
this is a smaller change than it sounds.

```odin
// Clips and the skeleton they were authored against. No mesh, no GPU
// resources -- this exists to be retargeted onto a model, not drawn.
Animation_Source :: struct {
	skeleton:   Skeleton,
	animations: []Model_Animation,
}

load_animation_source :: proc(path: string) -> (Animation_Source, Error)

// Copies every clip in `src` onto `dst`, rewriting each track to drive the
// bone playing the same humanoid role. Returns how many clips landed.
retarget_animations :: proc(
	dst:   ^Model,
	src:   Animation_Source,
	names: []Vrm_Bone_Name = UNREAL_BONE_NAMES,
) -> (added: int)

destroy_animation_source :: proc(src: ^Animation_Source)
```

`destroy_animation_source` joins the `destroy` proc group in `destroy.odin`,
per `CLAUDE.md`. In use:

```odin
character, _ := mb.load_model("assets/character.vrm")
clips, _     := mb.load_animation_source("assets/animations.glb")
defer mb.destroy(&clips)

mb.retarget_animations(&character, clips)   // now character.animations is populated
mb.play_animation(&animator, character, "Walk_Formal")
```

## Not in this document, and why

- **Blend shapes / expressions** (`blendShapeMaster` in 0.0, `expressions` in
  1.0). Blocked on something more basic: Matchbox does not read morph targets
  at all -- `animation3d.odin` says so, and the parser skips glTF's `weights`
  path. VRM expressions are a named-preset layer over morph targets that do
  not exist here yet. That is its own subsystem and wants its own plan.
- **Spring bone physics** (`secondaryAnimation` in 0.0, `VRMC_springBone` in
  1.0). `refactor.md`'s scope section is explicit that Matchbox is rendering
  and input only, with physics arriving as a separate package. The joints are
  in the skeleton regardless and sit at rest until something drives them,
  which is the right degrade. Read the parameters into data the day something
  will simulate them, not before.
- **MToon materials.** A whole second material system (outlines, rim light,
  shading bands). Unsupported material properties already fall back rather
  than failing (D8), so a VRM's MToon materials draw through the existing
  flat/textured pipeline meanwhile.
- **`VRMC_node_constraint`** (VRM 1.0 roll/aim constraints). Small, could ride
  along with step 2 later, nothing needs it yet.
- **VRM `meta`** (title, author, licence flags). Cheap to add and genuinely
  useful the day a game redistributes avatars, but not on the path to getting
  a character animating. Fold it in only if step 2 lands early.

## Decisions made deliberately

- **VRM logic lives in a new `matchbox/vrm.odin`, not in `matchbox/gltf2`.**
  `gltf2` is vendored and its patches are marked `MATCHBOX PATCH` so a refresh
  can find them. Since `Extensions` is already a raw `json.Value`, the
  vendored parser needs no changes at all -- `vrm.odin` reads
  `data.extensions` from outside, the way `model_load.odin` reads the rest.
- **No `load_vrm_model`.** `load_model` stays the single entry point, the way
  it already handles GLB-versus-glTF and skinned-versus-not without asking.
  VRM-ness is detected from the file's own `extensions`; a non-VRM file pays
  nothing.
- **Retarget at load, into ordinary clips** -- not at runtime inside
  `sample_pose`. The conjugation above makes baking exact rather than lossy,
  and it leaves the whole animation core, the layer system and every existing
  call site untouched.
- **`node_index`, `joint_map`, `animator_resolve` -- untouched.** `vrm_bone`
  is another way to *find* a node index, not a new kind of index.

## What can be tested without a VRM asset

Nearly all of it, which matters because the machine holding the assets is not
always the one doing the work.

- **Step 1's version detection**: `core:encoding/json` values can be built by
  hand (`Object :: distinct map[string]Value`), so a synthetic `extensions`
  object shaped like each version's asserts the right branch is taken.
- **Step 1's facing correction**: build a two-node synthetic skeleton, run it
  through the correction, and assert the root's rest rotation composes to the
  180-degree turn and that a child's global comes out mirrored in X and Z.
- **Step 2's humanoid parsing**: construct both the 0.0 array shape and the
  1.0 object shape by hand and assert they parse to the same `Vrm_Humanoid`.
- **Step 3's retargeting math, which is the part most worth pinning**: build
  two synthetic skeletons with *deliberately different* rest orientations and
  a known 1:1 correspondence, retarget a one-key rotation track, and assert
  the destination bone's resulting **global** orientation matches the source's
  delta-from-rest. That is the property the conjugation exists to guarantee,
  and it fails loudly if either bracket is transposed or applied on the wrong
  side. Also worth a test: a destination bone with no counterpart keeps its
  rest pose, and keyframe times survive the copy exactly.

**What needs the real files and the eye:** whether the corrected VRM 0.0
character faces the same way a native-facing model does; whether the
retargeted clips actually read as the same motion on the new rig rather than
merely being mathematically defensible; and whether the pristine `.vrm`
resolves the clothing clipping, which is a question about the source asset,
not about this loader.

## Steps

Same gate as the rest of the package: `odin check matchbox -no-entry-point`,
every example, `odin test matchbox`, and `python tools/gen_cheatsheet.py`
whenever the public API moves.

1. **Container and facing.** `.vrm` accepted as GLB, version detection, the
   0.0 root correction applied consistently to skeleton and static mesh paths.
2. **Humanoid bone map.** `Vrm_Bone`, `Vrm_Humanoid`, `vrm_bone`, both JSON
   shapes.
3. **Retargeting.** `Animation_Source`, `load_animation_source`,
   `retarget_animations`, `destroy_animation_source`, the Unreal-style name
   table, the conjugation, the hips translation case.
4. **Optional, once 1-3 land:** point `examples/animation-layers` at a `.vrm`
   plus a retargeted clip set, and replace its `UPPER_BODY_ROOT :: "spine_02"`
   with `vrm_bone(model, .CHEST)` -- the demonstration that this was worth
   doing rather than a parser exercise.

## Related

- `refactor.md`'s "Scope: Matchbox is rendering + input only" -- why spring
  bones and MToon are named and set aside rather than quietly deferred.
- `animation3d.md` -- `Model_Part.joint_map`/`joint_offset`, `node_index`, and
  the `Model` versus `Animator` split this slots into. `vrm_humanoid` is more
  "what came out of the file," the same shelf as `skeleton` and `animations`.
- `CLAUDE.md` -- `load_x` imports a thing that already exists whole, which is
  why `load_model` stays the one entry point and why
  `destroy_animation_source` joins the `destroy` group.
