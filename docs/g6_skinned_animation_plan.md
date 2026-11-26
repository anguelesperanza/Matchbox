# G6: skinned animation (plan)

Written 2026-11-26. Status: **stage 1, waiting for the user's approval of the public API and of the 3DS decision. No code in `matchbox/` yet.**
Source of truth for the phase: `render_plan.md`, "G6. Skinned animation" ("port main's animator logic; 3DS skinning on the CPU, or in the
vertex shader with a small bone limit; measure before choosing"). The plan format and check pattern are `docs/g4_billboards_plan.md`'s and
`docs/g5_render_targets_plan.md`'s. Camera conventions are `docs/g3_cameras_plan.md`'s.

## What this branch has now (vs. `main`)

| | `full-rewrite` (this branch) | `main` |
|---|---|---|
| `matchbox/animation.odin` | **Sprite animation only**: `Animation_Clip`, `Animated_Sprite`, `switch_animation`, `queue_animation`, `update_animation(&sprite, dt)`, `render_animated_sprite`. Nothing skeletal | the same file, plus `animation3d.odin` |
| Skeleton, clips, animator | none. `Model` is `{parts, textures, bounds_min, bounds_max}`; `Model_Part` is `{mesh, material, texture, color, blend, alpha_cutoff, cull}` | `Skeleton`, `Model_Skin`, `Model_Animation`, `Animation_Track`, `Animator`, `Animation_Blend`, `Animation_Pose`, `Animation_Playback`, `Animation_Layer` (1265 lines in `animation3d.odin`, loader in `model_skin_load.odin`) |
| glTF reading | `matchbox/gltf2` **already parses** `skins`, `animations`, node `skin`, and `JOINTS_0` / `WEIGHTS_0` (the vendored package is whole). `load_model` skips them on purpose (`model_load_windows.odin`: "Skipped rather than failed on: skins and animations (G6)") | `model_skin_load.odin` builds the skeleton and clips; `model_load.odin` reads joints and weights |
| Vertices | `Vertex` (36 B), `Lit_Vertex` (48 B, `Vertex` + normal). A `Mesh` holds `u16` indices | `Vertex3D_Skinned` (64 B: joints as `[4]u32`, weights as `[4]f32`) |
| Shaders | `mesh`, `mesh_lit`, `mesh_lit_opaque`, `mesh_vertex_lit` (`.mbs`, compiled by `mbsc` to HLSL, PICA + `.tev`, Cg) | `mesh_skinned.vert.hlsl` over a `StructuredBuffer<float4x4>` joint palette (`joint_offset` push constant) |
| Model file for the handhelds | `.mbm` version 2 (`model_file.odin`): `Lit_Vertex` per vertex, no skeleton | n/a (SDL3 reads glTF everywhere) |
| Test asset | `tools/testdata/models/test_crate.glb/.gltf` (made by `tools/make_test_model.py`): **no skin, no animation** | a VRoid and a Mesh2Motion export (not in this repo; `examples/walk-level` has only a cube) |

So G6 is a port plus two things `main` never had to solve: skinning on **three** targets with very different uniform budgets, and a
**model file** the 3DS and Vita can read (`.mbm` has to carry the skeleton and the clips, or the handhelds show a T-pose forever).

## What `main`'s animator does and how it maps

`main:matchbox/animation3d.odin`. What it does, in the order a frame runs:

1. **Data that never changes, on the `Model`:** `Skeleton{parents, rest (TRS per node), order (parents first), names, skins[]}`; each
   `Model_Skin{joints (node indices; a vertex's JOINTS_0 indexes this list, not the node list), inverse_bind}`; each
   `Model_Animation{name, duration, tracks[]}`; a track drives one node's translation, rotation or scale, `LINEAR`, `STEP` or `CUBIC` (all
   three are used in real exports: the VRoid walk mixes STEP and LINEAR in one clip).
2. **One `Animator` per character** (so two goblins share one `Model`): `Animation_Playback` embedded with `using` (`clip` index, `time`,
   `speed`, `looping`, `playing`), `Animation_Blend` (`enabled`, `duration` + state: `active`, `elapsed`, `from` playback), `Animation_Pose`
   (the working arrays: `locals`, `from`, `globals`, per-part `palettes`, per-layer scratch, the flat `joint_data`), and up to
   `MAX_ANIMATION_LAYERS` (2) masked `Animation_Layer`s.
3. **`update_animator`**: advance the fading-out clip and sample it into `pose.from`; advance the clip and sample into `pose.locals` (every
   sample starts from the rest pose, so a clip that moves only the arms leaves the legs where the file put them); mix `from` into `locals`
   with a smoothstep over `duration` (eased, because a linear ramp leaves a velocity step at the end of the fade); mix in each active layer
   through its mask; then `animator_resolve` walks `skeleton.order` to build global matrices and the palette
   `palette[j] = inverse(mesh node) * global[joint j] * inverse_bind[j]`, using each part's `joint_map` (the joints that part uses, so a
   part touching 37 of 66 joints carries 37 matrices).
4. **Draw**: `draw_model(model, animator, transform)` binds the animator's joint buffer; the skinned vertex shader blends four joint
   matrices by the vertex weights and moves position and normal with the result.
5. Extras: `node_index(model, name)` / `node_matrix` / `node_world_matrix` (hang a weapon on a bone), `play_animation(name)`,
   `play_animation_index`, `stop_animation`, layers with masks (`animation_mask_below`, `animation_mask_named`), `print_skeleton`,
   `print_animations`.

The mapping into this branch, kept deliberately close to `main` so a game ports with renames only:

| `main` | this branch | change |
|---|---|---|
| `Skeleton`, `Model_Skin`, `Model_Animation`, `Animation_Track`, `Animation_Path`, `Animation_Interpolation` | same names, in a new `matchbox/skeleton.odin` | none; `Transform` is the same type on both branches |
| `Animation_Playback`, `Animation_Blend`, `Animation_Pose`, `Animator`, `Animation_Layer` | same names, `animator.odin` | `Animation_Pose` drops the SDL GPU buffers (`joint_buffer`, `joint_transfer`); the palette stays CPU-side and the renderer copies it (see "Skinning per target") |
| `create_animator(model, blend := Animation_Blend{...})` | same | the defaulted settings struct stays as `main` has it, which is the CLAUDE.md pattern |
| `update_animator(&a, model, dt)` | **`update_animator`** (kept: `update_animation` is the sprite one and CLAUDE.md's "one verb per action" is about drawing) | none |
| `draw_model(model, animator, transform)` | `render_model(model, animator, transform)`, a fourth member of the existing `render_model` group | `draw_` -> `render_` |
| `play_animation`, `play_animation_index`, `stop_animation`, `node_index`, `node_matrix`, `node_world_matrix`, `animation_index`, `animation_names`, `node_names`, `print_*` | `play_animation`, `play_animation_index`, `stop_animation`, `get_node_index`, `calculate_node_matrix`, `calculate_node_world_matrix`, `get_animation_index`, `get_animation_names`, `get_node_names`, `print_skeleton`, `print_animations` | the `get_` / `calculate_` prefixes (CLAUDE.md, 2026-11-21) |
| `play_animation_layer`, `stop_animation_layer`, `set_animation_layer_weight`, `animation_mask_*` | **not in G6** (see "Left out") | |
| `is_model_skinned(model)` | `is_model_skinned` | none |

### Left out of G6, and why

- **Animation layers** (`MAX_ANIMATION_LAYERS`, masks). Layering is the one feature that adds a scratch pose per layer per animator and a
  second pass over every joint; on the 3DS's soft-float CPU that is the part of `update_animator` that costs, and the milestone ("a small
  third-person scene") needs one clip at a time with a fade. They are a clean addition later: `Animator` gets one field, `update_animator`
  one loop. Say so now if the user wants them in.
- **Morph targets / glTF `weights`**: skipped at parse on `main` and here.
- **Per-vertex joint count above 4** (`WEIGHTS_1`): read as 4 and renormalised at load, as `main` does (see "Weights").

## Proposed public API (needs the user's approval)

New files: `matchbox/skeleton.odin` (types, the maths that needs no GPU: sampling, hierarchy, palette), `matchbox/animator.odin`
(`Animator`, playback, blending, the `render_model` member), `matchbox/model_skin_load.odin` (glTF -> skeleton and clips, PC), and the tests.
`Model` and `Model_Part` gain fields. `animation.odin` is untouched (the sprite verbs keep `update_animation`).

```odin
// ---- what comes out of the file, on the Model, never changes ----
Animation_Path          :: enum { TRANSLATION, ROTATION, SCALE }      // one value per line in the source, as CLAUDE.md asks
Animation_Interpolation :: enum { LINEAR, STEP, CUBIC }
Animation_Track  :: struct { node:u32, path:Animation_Path, interpolation:Animation_Interpolation, times:[]f32, vectors:[][3]f32, quats:[]quaternion128 }
Model_Animation  :: struct { name:string, duration:f32, tracks:[]Animation_Track }   // one clip
Model_Skin       :: struct { joints:[]u32, inverse_bind:[]matrix[4,4]f32 }
Skeleton         :: struct { parents:[]i32, rest:[]Transform, order:[]u32, names:[]string, skins:[]Model_Skin }

Model :: struct {
	parts, textures, bounds_min, bounds_max,   // as today
	skeleton:Skeleton,                         // empty for a model with none: a crate
	animations:[]Model_Animation,
}
Model_Part :: struct {
	/* as today, plus */
	skin:int,             // -1 (the default of a loaded part: set by the loader) for an ordinary part
	joint_map:[]u32,      // which of the skin's joints this part's vertices use, in order; <= the target's joint limit
}

// ---- one character's playback ----
Animation_Playback :: struct { clip:int, time:f32, speed:f32, looping:bool, playing:bool }   // clip -1 = nothing
Animation_Blend    :: struct { enabled:bool, duration:f32, /* state: */ active:bool, elapsed:f32, from:Animation_Playback }
Animation_Pose     :: struct { locals, from:[]Transform, globals:[]matrix[4,4]f32, palettes:[][]matrix[4,4]f32 }   // CPU only
Animator           :: struct { using playback:Animation_Playback, blend:Animation_Blend, pose:Animation_Pose }

create_animator  :: proc(model:Model, blend := Animation_Blend{enabled = true, duration = 0.2}) -> Animator   // bind pose until the first update
destroy_animator :: proc(animator:^Animator)                                                                  // joins the `destroy` group; the Model is untouched

play_animation       :: proc(animator:^Animator, model:Model, name:string, looping := true) -> bool   // false: no clip by that name. Asking for the clip already playing changes only `looping`: safe every frame, like switch_animation
play_animation_index :: proc(animator:^Animator, model:Model, index:int, looping := true)
stop_animation       :: proc(animator:^Animator)
update_animator      :: proc(animator:^Animator, model:Model, delta_time:f32)                         // once a frame; works the pose out on the CPU

get_animation_index  :: proc(model:Model, name:string) -> (index:int, found:bool)
get_animation_names  :: proc(model:Model, allocator := context.temp_allocator) -> []string
get_node_index       :: proc(model:Model, name:string) -> (node:u32, found:bool)           // a NODE index, not a joint index (the classic bug: said in the comment)
calculate_node_matrix       :: proc(model:Model, animator:Animator, node:u32) -> matrix[4,4]f32   // the bone in the model's own space
calculate_node_world_matrix :: proc(model:Model, animator:Animator, node:u32, transform:Transform) -> matrix[4,4]f32   // on the bone, in the world: a weapon
is_model_skinned :: proc(model:Model) -> bool

// the fourth member of the render_model group: a skinned model, posed by an animator
render_model_animated :: proc(model:Model, animator:Animator, transform:Transform, tint := [4]f32{1,1,1,1})
```

Using it (the same shape as the sprite animation in `animation.odin`):

```odin
hero := mb.load_model("models/hero.glb")
animator := mb.create_animator(hero)
mb.play_animation(&animator, hero, "Walk")

for mb.is_running() {
	mb.render_start()
	if mb.is_key_pressed(.SPACE) do mb.play_animation(&animator, hero, "Attack", looping = false)   // fades from what was playing
	if !animator.playing do mb.play_animation(&animator, hero, "Idle")                              // a one-shot finished: poll, never a callback
	mb.update_animator(&animator, hero, mb.get_delta_time())
	mb.camera_start(camera)
		mb.render_model(hero, animator, mb.create_transform(position))
	mb.camera_end()
	mb.render_end()
}
```

Rules, each answering a question the user will ask:

- **Looping / finished.** `looping = true` is the default (a walk has no end). A one-shot stops on its last pose and sets `animator.playing = false`;
  the game polls `!animator.playing`, exactly as it polls `!sprite.playing`. **No callbacks, no `on_finished`.**
  `play_animation` on a clip that is already current does not restart it, so a state machine may call it every frame.
- **Blending.** On by default over 0.2 s, as on `main`; `Animation_Blend{enabled = false}` is the hard cut and `duration = 0` is a hard cut just once.
  The outgoing clip keeps advancing while it fades; a switch during a fade freezes the current mix and fades from that (`from.clip = -1`).
  The mix is eased (smoothstep). Per-joint: translation and scale lerp, rotation slerp (shortest arc).
- **A skinned `Model` is drawn only with an animator.** `render_model(model, transform)` on a skinned model draws its **bind pose** (a T-pose) rather than
  failing, so a skinned model still shows when a game forgets the animator; the doc comment says so. `render_model(model, animator, transform)`
  on an unskinned model draws it normally (an animator made for it is a zeroed one, as on `main`).
- **Two characters, one model**: one `Model`, one `Animator` each. The animator holds no GPU object (unlike `main`'s joint buffer), so
  `create_animator` is safe to call any time on any target, including mid-frame (this matters: a GPU object made mid-frame crashed the real 3DS in G5).
- **No new package-level constants or globals.** The per-target joint limit is a field of `mbi.skin_settings` (a `Skin_Settings` struct next to the
  renderer, filled where `mbi` is declared), not a constant. The one new array size is none: palettes are slices.
- **Names.** `render_model_animated` joins the `render_model` group, so the call is `render_model(model, animator, transform)`; the fixed
  parameter order `(model, animator, transform)` keeps it unambiguous with `(model, pivot, transform)` (an `Animator` is not a `[3]f32`).

## Skinning per target: design with numbers

### What is shared

- The CPU works out the **palette** (`calculate_palette`, tested against numpy) in `update_animator`: one `matrix[4,4]f32` per joint of each part's `joint_map`.
  The vertex shader's formula is `skin = sum(weight_i * palette[joint_i])` for four influences, then position, then normal (the skin matrix is
  applied to the normal before the model's, as `main` does; correct for a rig that does not scale a bone unevenly, said in the comment).
- **The queue holds the palette.** `render_model` only *records* a draw (render.odin) and the draw happens at `camera_end`, by which time the
  animator may have been updated again or a second character drawn from the same model. So `render_model(model, animator, ...)` copies each part's
  palette into a per-frame **joint arena** (one flat slice in `mbi`, emptied at `camera_end`; a `Render_Item` gets `joint_offset` and `joint_count`).
  No GPU objects are created per animator. The arena is the shape of `main`'s `joint_data`, minus the GPU buffer.
- **A skinned vertex** is `Skinned_Vertex`: `Lit_Vertex` whole (48 B, so the first 48 bytes are what the lit shaders already read), then
  `joints:[4]u8` and `weights:[4]u8` (255 = 1.0) = **56 bytes**. 8-bit joints cap a skin at 256 joints, far above any limit below; 8-bit weights quantise to 1/255 of a
  vertex's influence, which is under half a millimetre on a metre-tall character, and are renormalised to sum 255 at load (see "Weights").
  On PC a 4 x u8 element is `R8G8B8A8_UINT` / `_UNORM`; on the Vita `U8` / `U8N` attribute formats; on the 3DS `UBYTE` loaders.
  main used `[4]u32` and found D3D12 and Vulkan disagreeing about widening a 16-bit joint to a 32-bit shader input (the story in `Vertex3D_Skinned`'s comment). 8-bit unorm weights and
  integer-format joints sidestep it: PC reads `uint4` from `R8G8B8A8_UINT`, an exact match of width, and the Vita and PICA convert to float (exact for 0..255).
- **Weights.** Renormalised at load to sum to 1 (a file with `WEIGHTS_1` has vertices summing below 1 after the first four are kept; used unscaled they are dragged toward the origin:
  `main`'s `read_weights` comment). A vertex with no weight at all is pinned to joint 0 at full weight (a vertex a modeller forgot to skin stays on the body instead of collapsing).
- **`joint_map`** exists to meet each target's joint limit (below) and to keep palettes small, as on `main`. The loader splits a primitive into several `Model_Part`s,
  each using at most `limit` joints, with the triangle sort done once at load (greedy: add triangles while the union of their joints stays within the limit).
  A single triangle never needs more than 12 joints (3 vertices x 4), so the split always succeeds for a limit of at least 12. Each split costs one extra draw call for that part.

### Per-target joint limits and the budget behind each

| | **PC (D3D11)** | **Vita (GXM)** | **3DS (PICA200)** |
|---|---|---|---|
| Where the palette lives | one `StructuredBuffer<float4x4>` SRV (D3D11 has no 4 KB uniform sectioning; `main`'s storage buffer, kept for the same reason), uploaded once per `camera_end` from the arena | the vertex program's default uniform buffer, set as an array uniform per draw (`frame_*`, `render_*`, `lights_*` are global Cg `uniform`s already, `docs/shader_cg.md`) | the vertex shader's float registers, set per draw with `C3D_FVUnifSet` |
| Matrix stored as | 4x4 (64 B) | 4x4 (64 B), or 4x3 (48 B) if registers get tight | **4x3: three registers per joint** (`rows 0..2`; the bottom row of a skinning matrix is 0 0 0 1) |
| Budget | a 4 MB buffer holds 65,536 matrices; the limit is the arena | 64 KiB default uniform buffer per stage (`SCE_GXM_DEFAULT_UNIFORM_BUFFER_SIZE`, my recollection of the SDK; **to verify in `vito` before step G6-6**: `vito/sce/gxm.odin` has only `GXM_MAX_UNIFORM_BUFFERS = 14`). Existing uniforms use about 0.1 KB (`mesh_vertex_lit`: `frame` 128 B, `render` ~100 B, `lights` 8 x 5 x 16 = 640 B). 64 B per joint puts the ceiling over 900 joints | **96 float registers in total, constants included** (`docs/shader_pica.md`; `mbsc` refuses more). `mesh_lit` already uses 14 for its uniforms + 5 constants = 19; the skin adds its own constants (about 3) |
| **Joint limit per draw** | **256** (the u8 index; the arena is not the limit) | **64**, a round figure that matches `main`'s old limit and leaves 4 KB of the 64 KiB; raise later if hardware allows | **per-pixel lit: 22** ((96 - 19 - 3 constants - 6 spare) / 3 = 22.7); **per-vertex lit: 8**, because the `lights` block takes 41 registers there (`mesh_vertex_lit`), leaving (96 - 14 - 41 - ~12 constants) / 3 ~ 9, less one spare = 8 |
| Reading a joint by a vertex's index | `palette[joint_offset + j]`, integer | `palette[j]`, a Cg array indexed by a float cast to int | `mova a0.x, v_joint.i` (the vertex unit's address register): the one operand of an instruction that may index, and two address registers (`MBS-E10`) |
| Cost | negligible | 56 B vertex fetch; four 4x4 mad chains per vertex on a unit that already runs per-pixel lighting at ~30 fps | about 20 vertex instructions for the blend + about 20 for the normal, on top of the lit shader's ~70; 1,000 vertices x ~110 instructions ~ 110 k cycles ~ 0.4 ms at 268 MHz (arithmetic: 1 instruction per cycle; not measured) |

**What a limit means to a game:** a 3DS character's rig should have about 20 joints per *draw*, not per model: the loader splits a 60-joint rig into draws of
at most 22 joints. A humanoid with fingers is 60 to 80 joints and splits into 3 or 4 draws; a low-poly one (the target of a 3DS game) is 15 to 25 and splits into 1 or 2. The split is
the reason `joint_map` is per part. The honest consequence is draw calls: G4 and G5 both found that the 3DS's small command buffer overflows with hundreds of draws, and 3 to 4 per character
is fine but a crowd of fifty is not. The check example puts one character on the 3DS, and prints the draw count.

### The 3DS decision: vertex shader or CPU? (arithmetic; the plan says which, and where a measurement overrides it)

| | Vertex shader skinning (proposed) | CPU skinning into a dynamic vertex buffer |
|---|---|---|
| Per-frame CPU cost | the palette only: 22 joints x (a matrix multiply, ~64 multiply-adds) ~ 1,500 float ops. In soft float, with ~40 cycles per op ~ 60 k cycles ~ 0.07 ms on a New 3DS (804 MHz). Cheap | per vertex: a blended 4x3 matrix from four joints (4 x 12 multiply-adds), then the position (9) and normal (9) ~ 70 ops. ~ 2,800 cycles ~ 3.5 us per vertex on a New 3DS. **1,000 vertices ~ 3.5 ms; on an old 3DS at 268 MHz ~ 10 ms** of a 33 ms frame. And Phase H (hard-float) is later, so the cost is the soft-float cost today |
| Per-frame GPU cost | ~ 0.4 ms per 1,000 vertices | none extra (the ordinary lit shader) |
| Memory | none extra | each model needs its skinned `Lit_Vertex` array in **linear memory**, double-buffered (the GPU reads last frame's while the CPU writes this frame's): 2 x 48 B x vertices: 96 KB per 1,000 vertices, per character, allocated up front (an allocation failure killed the real 3DS in earlier phases, so nothing is allocated in a frame) |
| Joint limit | 22 per draw (8 with per-vertex lighting): a rig is split into several draws | none: all 256, one draw per part |
| Draw calls | 3 to 4 per humanoid (the split) | the same as an unskinned model |
| Lighting | normal skinned in the shader, then the existing per-pixel path | normal skinned on the CPU: same path, no shader change at all |
| New code | `mbsc`: two attribute tags (`joints`, `weights`) and an index read from a vertex attribute (`mova`) for **PICA**, `Skinned_Vertex` loaders, a per-draw palette upload, the part split; the new shader is **not exercised by the existing hardware-proven programs** (Azahar and the real 3DS have already disagreed once about what the vertex unit accepts: `docs/shader_pica.md` "written whole") | a CPU loop and a linear-memory buffer; no change to `mbsc`, shaders or the draw path. The risk is time, not correctness |
| Hardware risk | highest of the two: a new addressing mode in a generated shader, never run on the real GPU | low |

**Proposal: vertex shader skinning on all three targets, with a measurement gate before the 3DS commits to it.** Arithmetic says the GPU does 1,000 vertices in
0.4 ms against 3.5 to 10 ms on the CPU, and a CPU path would also spend linear memory and soft-float time that the 3DS does not have to spare once a scene has a
lit world and a HUD. The gate (step G6-5): a 3DS spike draws one skinned character with the vertex shader on Azahar, then on the user's hardware, with a **CPU fallback written
first only if** the vertex path fails there (hang, wrong picture) or if `mbsc` cannot express the indexed read inside the 96-register budget. If the CPU path is needed it is the
same `Skinned_Vertex` data and the same palette; only where the sum is taken changes. I have **not measured either** and say so: the figures above are arithmetic.

**Per-vertex-lit skinned models on the 3DS draw per pixel** (the vertex-lit shader leaves room for only 8 joints). On the PC and the Vita both lighting paths get a skinned variant;
this is the one place the 3DS differs, written in the doc comment of `Lighting_Mode`.

## Lighting (G2) with skinned models

- **Normals.** Skinned with the same blended matrix as the position, before the model's matrix. Both lit shaders (`mesh_lit`, `mesh_vertex_lit`) take `position` and
  `normal` from the vertex input, and the skinned variants change only the first lines: `position = skin * position`, `normal = skin * normal (w = 0)`. Everything after (eye-space
  normal quaternion for the 3DS's lighting unit, the per-vertex light loop) is the existing code: so a skinned model lights exactly as an unskinned one, and that is checked: **a model skinned
  with an identity palette must light identically to the same model unskinned** (a pixel/colour test on PC, and the TEV output on the 3DS).
- **Shader files** (all generated by `mbsc`, committed): `mesh_skinned_lit.mbs` and `mesh_skinned_vertex_lit.mbs`, from the existing two with a `#include`-style shared skin function in the same
  file (a procedure, inlined by `mbsc`). Unlit skinned: not needed (a model with no lights draws `mesh_lit` with ambient 1, as unlit models do today: confirm in G6-2).
- **Fresnel / alpha cut-out** behaviour on the 3DS (`lighting_fresnel secondary_alpha_zero`) comes with the lit `.tev` unchanged, since the fragment side is identical.

## Loading

- **PC** (`model_load_windows.odin` + new `model_skin_load.odin`): reads `skins`, node hierarchy, `animations`, `JOINTS_0`, `WEIGHTS_0`. A glTF file's rest pose is not its bind pose (a CLAUDE.md
  gotcha); the skeleton keeps both: `Skeleton.rest` is the node's own TRS, `Model_Skin.inverse_bind` is what takes a joint back to the pose the mesh was modelled in.
  `main`'s loader also divides out the mesh node's transform (glTF: a skinned mesh ignores its node's transform): ported.
- **Handhelds**: `.mbm` **version 3**. It adds, per model: the skeleton (parents, rest TRS, names, skins with inverse binds), the clips (tracks of times and values; `CUBIC` stored as given), and per part:
  `skin`, `joint_map`, vertices as `Skinned_Vertex`. Version 2 files are refused like version 1 (the build writes every `.mbm` fresh from its glTF, `model_file.odin`), so there is no
  migration. `tools/modelpack.odin` writes it; `read_model_file` reads it; the tests round-trip it, **including a skinned model and its clips**. File size: the animation tracks are the cost: a 2 s clip over 20
  joints at 30 keys is 20 x 30 x (4 + 16) B ~ 12 KB; fine in romfs.
- **Memory on the handhelds**: the tracks are read into the model (not streamed), a few tens of KB per character. Said here so it is not a surprise: the 3DS has no spare for a crowd.

## The test asset

There is no skinned glTF in the repo. Options: (a) a downloaded rig (untrusted data, licence and size questions, and not reproducible); (b) **a generated one**, as `tools/make_test_model.py` does for the crate.
**Proposed:** extend `make_test_model.py` (or a sibling `make_test_skinned_model.py`) to write `tools/testdata/models/test_arm.glb/.gltf`: an arm of **3 joints** (shoulder, elbow, wrist) and a
**16-segment tube** with 4 rings of vertices per joint segment, vertex weights that cross-fade over the two rings at each joint (so there are vertices with 2 influences), one clip `"Wave"` (2 s: the elbow
rotates 0 -> 90 deg -> 0, LINEAR with one STEP track and one CUBIC track so all three interpolations are exercised), a clip `"Idle"` (rest), and an `inverse_bind` for each joint.
It is also enough for the 3DS limit tests: a second **40-joint rope** variant (`test_rope.glb`) exercises the part split (limit 22 -> 2 parts, a vertex ring shared across the split).
Small (under 5 KB each), generated deterministically, committed in `tools/testdata/models/`, with the `.mbm` written by the build the way `test_crate` is.

## `mbsc` and the shader build workflow

- **New in `mbsc`:** two attribute tags, `joints` and `weights`, and their types (`[4]u8`, `[4]u8` normalised: the language has `f32`/vector only today; the tags carry the format). A uniform array
  indexed by a vertex attribute: HLSL and Cg are an integer cast; **PICA needs `mova`**, and `MBS-E10` today allows only constants, loop counters and the address registers. The extension is "an array
  index may be a vertex attribute cast to `i32`, once per instruction operand". New error entries in `docs/shader_errors.md` for the cases it must refuse (two index sources in one instruction;
  a palette longer than the budget: `MBS-E<n>`, rustc-style, naming the 96-register arithmetic above). `docs/shader_language.md` ("the engine's mesh format today is exactly these three... `bone_index` added with the first
  skinned shader" says it expected this) and `docs/shader_pica.md` are updated.
- **A palette constant** `JOINT_SLOT_COUNT` (like `LIGHT_SLOT_COUNT`, per target: 256 PC, 64 Vita, 22 3DS) so one `.mbs` is right on every target and the engine's `mbi.skin_settings.joint_limit` equals it. A compile-time constant of the
  shader language, not an Odin package constant (CLAUDE.md's rule is about the Odin package; mbsc's `LIGHT_SLOT_COUNT` is the precedent).
- **Generated files** (all committed, as the existing ones are; a change to one without the others is a broken build for somebody): `mesh_skinned_lit.{pc.hlsl,pc.refl,vita.refl,3ds.v.pica,3ds.tev}` + `mesh_skinned_lit_v.{cg,gxp}` + `_f.{cg,gxp}`, and the same for `mesh_skinned_vertex_lit`:
  about 20 new files. `build_shaders` on this branch is the existing workflow (`tools/mbsc`, `psp2cgc` for the Vita through `vito`, `picasso` for the 3DS), re-run after any `.mbs` edit; `odin test tools/mbsc`
  (120 tests today) gains tests that **assemble every new program with the real picasso and psp2cgc** and check the register totals and the 96-register ceiling.

## Tests that assert on numbers

- **Palette vs. numpy** (the CLAUDE.md case): a script `tools/check_skinning.py` (numpy, committed with its output) builds the arm and the rope, samples the "Wave" clip at t = 0, 0.5, 1, 1.5, 2 s, and writes the palettes and the skinned positions of 8 chosen vertices to a JSON.
  The Odin test **loads the same .glb**, runs `update_animator`, and asserts every palette matrix and the skinned positions equal numpy's within 1e-5 (LINEAR), 1e-5 (STEP) and 1e-4 (CUBIC).
- **A known pose against hand-worked positions** (no numpy needed): the elbow turned 90 degrees about Z moves a wrist vertex at `(1, 0, 0)` relative to it to a worked `(0, 1, 0)` + the elbow's position; weights 0.5/0.5 across the elbow land on the
  halfway rotation's chord. Written as numbers in the test.
- **Blending**: at `t = duration/2` the eased mix is exactly the average of the two poses (smoothstep(0.5) = 0.5), at 0 it is the old clip, at `duration` the new one, a switch mid-fade freezes the mix; a one-shot stops with `playing = false` on its last pose and `time = duration`; a `looping` clip's time wraps with `mod` through a delta of many durations.
- **The split**: a 40-joint rope with limit 22 makes 2 parts, each `joint_map` <= 22, the union covers all used joints, no triangle straddles a split (every triangle's joints are in its part's map), and the skinned positions equal the unsplit ones.
- **Weights**: renormalisation sums to 255 in `u8`; an unweighted vertex is pinned; five-influence vertex has the fifth dropped and the rest renormalised.
- **File round trip**: write a skinned `Model_Data` with clips as `.mbm` v3, read it back, equal field by field.
- **Lighting equality**: PC WARP device (as `render_target_windows_test.odin` does): the arm drawn skinned with an identity palette and with the same mesh unskinned produce the same pixels; the arm with the elbow at 90 degrees has its elbow-side normals turned (a lit pixel changes by the numbers the test works out).
- **mbsc**: the skinned shaders' PICA output is run on the vertex-unit model (`pica_machine_test.odin`) against `ir_eval_test.odin`'s evaluation for random palettes and weights; picasso assembles; the Cg compiles.
- **3DS / Vita on-target self-check** (`examples/animation-check`, light, the `billboard-check` pattern, `animation-check: N passed, M failed` printed and shown on the HUD): the pose of the arm at a fixed clip time is
  worked out on the CPU (the same `update_animator`), and **one** skinned vertex's screen position is computed from it by hand arithmetic in the example and compared with a read-back of the framebuffer (a coloured wrist marker's pixel);
  two characters on one model drawn with different clip times differ in the marker's position. One character, one rope variant, not a crowd (the command buffer).

## The example

`examples/animation-check`: the arm (and, on a key, the rope) lit by the scene's lights; `Left/Right` or D-pad picks the clip (Idle / Wave); a button toggles blending (watch the fade); a second animator on the same model runs a quarter-phase behind it
(proving the two-characters rule); a HUD line prints the clip, the time, `animator.playing`, the draw count and the part count, and on PC the per-frame update cost in microseconds, and on the handhelds the measured frame time.
Same layout as `model-check` (`examples/model-check/main.odin`).

## Steps

- [x] G6-1. Read the branch and `main`, write this plan.
- [ ] G6-2. **User approves the public API** (this file's "Proposed public API"), the 3DS decision (vertex shader, with the CPU fallback only if the gate fails), the joint limits (22 / 64 / 256), and whether layers are left out. Nothing below starts before.
- [ ] G6-3. Shared, no GPU: `skeleton.odin`, `animator.odin` (sampling, hierarchy, palette, blending, looping), the `Model` / `Model_Part` fields, `Skinned_Vertex`, the part split; the test asset generator and `tools/check_skinning.py`; the number tests above.
- [ ] G6-4. Loading: `model_skin_load.odin` (PC), `.mbm` v3 (`model_file.odin`, `tools/modelpack.odin`), round-trip tests, `load_model` fills `Model.skeleton` on all three targets.
- [ ] G6-5. `mbsc`: the attribute tags, the attribute-indexed palette read (PICA `mova`), the new `.mbs` files, generated shaders for all three, the tests that assemble them. **Gate:** Azahar draws a skinned vertex where the hand arithmetic says; then a hardware spike build (one character, one draw) before anything is built on it.
- [ ] G6-6. PC: the arena, the structured-buffer upload at `camera_end`, `render_model(model, animator, transform)`, the lighting-equality pixel test. Check on PC first, since it is the cheapest place to read pixels.
- [ ] G6-7. Vita: the uniform-array palette and the skinned vertex format; Vita3K. Verify the default uniform buffer size in `vito` (recollection above).
- [ ] G6-8. 3DS: the register palette, the part split, per-vertex-lit falls back to per-pixel; Azahar. If the gate fails on hardware, the CPU skinning path (same data) goes here instead.
- [ ] G6-9. `examples/animation-check` with the light self-check; `odin check` for matchbox and the examples; `odin test matchbox`; `odin test tools/mbsc`; `3ds_check.bat`, `vita_check.bat`; Azahar and Vita3K runs; frame-time numbers.
- [ ] G6-10. Hardware builds `animation_check_g6.3dsx` and `animation_check_g6.vpk` in the main checkout's `build\hardware\`, full paths reported. Commit, do not push. **Wait for the user's hardware check.**

## Open questions for the user

1. **API.** Names: `Animator`, `create_animator`, `update_animator` (kept, not `update_animation`, which is the sprite verb), `play_animation`, `render_model(model, animator, transform)`, the `get_` / `calculate_` renames of `main`'s `node_index`, `node_matrix`, `animation_names`. Right vocabulary?
2. **A skinned model without an animator** draws its bind pose (T-pose) instead of asserting. Right?
3. **3DS:** vertex-shader skinning with a 22-joint draw limit (8 with per-vertex lighting, which therefore falls back to per-pixel), behind a hardware gate that falls back to CPU skinning. Or CPU skinning from the start (no `mbsc` work, ~3.5 ms per 1,000 vertices soft-float, 96 KB linear memory per 1,000 vertices)?
4. **Joint limits** 256 (PC) / 64 (Vita) / 22 (3DS) per draw, with the loader splitting parts to fit. Acceptable? A 3DS character under 22 joints draws in one call.
5. **Layers** left out of G6 (a later addition). Agreed?
6. **Test asset** generated by `tools/make_test_skinned_model.py` (a 3-joint arm and a 40-joint rope), rather than a downloaded character. Agreed? If the user has a real rigged character in mind for the hardware pass, say where it is.
7. **`.mbm` version 3** (skeleton and clips in the file; version 2 refused). Agreed?

## Not verified

Nothing here has been run. The 3DS and Vita cost figures are arithmetic (instruction counts, 1 instruction per cycle on the PICA vertex unit, ~40 cycles per soft-float op, a recollection of the GXM uniform buffer size);
G6-5 and G6-7 replace them with measurements, and Azahar and Vita3K do not give hardware frame times (both sit at 60 fps vsync).
