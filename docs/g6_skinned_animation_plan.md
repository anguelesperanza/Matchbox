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
  **What leaving layers out costs, exactly (agreed 2026-11-26).** A character plays one clip at a time (with a fade into the next). Lost: (1) two clips at once on different
  body parts, such as a walk on the legs and a wave on the arm; a game that wants that today has to author a combined clip. (2) Masks, so no "this clip drives only the
  upper body". (3) Additive clips (a flinch or a head turn laid over whatever is playing). Not lost: blending between two clips (the fade), several characters on one model
  (one `Animator` each), reading a joint's pose to attach something to it (`calculate_node_matrix`). The `Animator` is shaped so that layers are one field (a list of
  `Animation_Playback` with a weight and a mask) and one loop in `update_animator` that mixes each into `pose.locals` before `resolve_skeleton_pose`.
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

**Revisit later (the user's decision, 2026-11-26).** These three numbers are provisional. The user plans a separate, PC-only pass that raises the PC figure at the
cost of such models no longer compiling to the other targets. So the limit is a per-target settings field, `mbi.skin_settings.joint_limit` (`Skin_Settings`,
`matchbox/skin.odin`), written in each backend's `BACKEND_DEFAULTS`, never in shared code; the shaders' `JOINT_SLOT_COUNT` is the same number per target
(`tools/mbsc/lighting.odin`, `get_max_joints`), and a shader built for one limit is refused by an engine with another (`check_engine_blocks`). Raising the PC
limit is those two numbers, the `cbuffer` size (a constant buffer holds 4096 float4s: 1,365 joints at three rows each) and nothing else.

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

## Outcome (stage 2, 2026-11-26): what was built, and where it differs from the plan above

The approved answers: names as proposed; a skinned model with no animator draws its bind pose; GPU skinning on every target behind the 3DS hardware gate (the CPU fallback
only if the gate fails); joint limits 256 / 64 / 22 marked "revisit later" and kept as a per-target setting; layers left out; `.mbm` version 3; the small generated test asset.

**Where it differs from the proposal:**

- **The PC palette is a constant buffer, not a structured buffer.** `skin` is a `cbuffer` of three `float4[256]` arrays (12 KB, under D3D11's 64 KB), filled per draw from the
  frame's joint arena (`set_skin_constants`), not one upload per `camera_end`. A structured buffer would need a second shader form for the same shaders (the Cg and
  PICA backends have arrays of `float4` only), and the arrays are what lets one `.mbs` file build for all three targets. The cost is a 12 KB map per skinned draw.
- **The palette is three row arrays (`row0[]`, `row1[]`, `row2[]`), not one array of three-row groups.** The 3DS indexes with an address register (`mova`) and has no integer
  arithmetic to scale `joint * 3`; three arrays each indexed by the joint need none. Registers on the 3DS for `mesh_skinned_lit`: 66 palette + 14 uniforms + 6 constants = 86 of 96.
- **Per-vertex-lit skinned parts draw per pixel on every target.** There is no `mesh_skinned_vertex_lit.mbs`: the per-vertex lights block takes 41 of the 3DS's registers, so
  the joint limit would have fallen to 8. A skinned part that asks for `.PER_VERTEX` is shaded per pixel, the same on all three targets, so a model never differs between them
  by its rig. If a game needs per-vertex skinned lighting on the 3DS, that is its own shader and a limit of 8.
- **An unlit skinned shader was added** (`mesh_skinned.mbs`), drawn while lighting is off, so a skinned model never falls back to its bind pose when the lights go off (the plan
  had assumed `mesh_lit` with ambient 1).
- **The joint index is read from the vertex on each target its own way.** The 3DS and Vita load the joint byte as the number 0..255 (`UNSIGNED_BYTE` / `U8`). The PC cannot:
  a `UINT` vertex format reaches a `float` input as the integer's bits, which is a denormal that casts to 0 (every vertex followed joint 0; found on the first PC render and
  fixed), so the PC loads the byte as 0..1 (`UNORM`) and the shader scales by 255 under `when TARGET == .PC`.
- **`mbsc` gained** a `SKIN` engine block (`skin.row0/row1/row2`), the vertex attributes `joints` and `weights`, the constant `JOINT_SLOT_COUNT`, and on the PICA an inline
  `array[i32(<float>)]` read through the address register (`mova a0.x`), which is the one way a computed index is allowed (anything else is still `MBS-E10`).
- **`Skin_Settings` and `Skin_State` are in `mbi`**, as the "no new globals" rule asks; the joint arena is cleared at every `camera_end`.

**Skeleton and clips of the user's models** (read with `tools/modelpack.exe` at each target's limit; none is committed: `assets/` is git-ignored and stays so):

| model | nodes | joints (all skins) | clips | vertices | parts at 256 / 64 / 22 | images | `.mbm` size |
|---|---|---|---|---|---|---|---|
| `arms_rig.glb` | 54 | 52 | 18 | 758 | 1 / 1 / 2 | 1 | 387 KB |
| `bodychan.glb` | 965 | 782 | 0 | 44,804 | 37 / 37 / 38 | 0 | 3.0 MB |
| `retargeted_animations.glb` | 80 | 858 (13 skins) | 31 | 18,572 | 13 / 13 / 14 | 13 | 2.1 MB |

What the loader does with them: it keeps every node (not only the joints), reads each skin's joint list and inverse bind matrices, reads every clip's tracks (LINEAR, STEP and
CUBICSPLINE; morph-target `weights` channels are skipped), cuts each skinned primitive into parts of at most the target's limit, and keeps weights as bytes that sum to 255.
`arms_rig` is the one that suits a handheld: 758 vertices, 1 draw on the Vita and 2 on the 3DS. **`bodychan` (a VRoid-style body) is too big for the handhelds as it is**: 44,804
vertices over 37 or 38 parts is 38 draws for one character on the 3DS, past what its small command buffer took in G4 and G5, and far over its vertex budget; it was not put on
the 3DS. On the Vita it is 37 draws of per-pixel-lit skinned meshes at a frame rate nobody measured here, so it is not claimed to run. It is a PC model.
`retargeted_animations.glb` (39 MB, 13 skins, an image for each) is the same story at a smaller size.

## Steps

- [x] G6-1. Read the branch and `main`, write this plan.
- [x] G6-2. The user approves the API, the 3DS decision, the limits (marked "revisit later"), and that layers are left out. 2026-11-26.
- [x] G6-3. Shared: `skeleton.odin`, `animator.odin`, `skin.odin`, `model_skin_split.odin`; the test asset generator (`tools/make_test_skinned_model.py`, which also prints the numpy palettes the tests assert on); the number tests (`skeleton_windows_test.odin`).
- [x] G6-4. Loading: `model_skin_load.odin` (PC), `.mbm` version 3, `tools/modelpack.odin` takes the joint limit, round-trip test.
- [x] G6-5. `mbsc`: the block, the attributes, the constant, PICA relative addressing, `mesh_skinned.mbs` and `mesh_skinned_lit.mbs` generated for all three targets (picasso and psp2cgc assemble them).
- [x] G6-6. PC runtime; checked by screenshots on a real D3D11 device and by the palette numbers.
- [x] G6-7. Vita runtime; run in Vita3K.
- [x] G6-8. 3DS runtime; run in Azahar. The hardware gate (the vertex shader's `mova` indexing on a real New 3DS LL) is the user's: `animation_check_g6_gate.3dsx`.
- [x] G6-9. `examples/animation-check`; checks and tests green.
- [x] G6-10a. **3DS hardware check passed** (2026-11-26, the user: "everything works on 3DS"). The vertex shader's `mova` indexing and the `UNSIGNED_BYTE` loaders work on the real New 3DS LL, so GPU skinning stays on the 3DS and the CPU fallback is not needed. Which of `animation_check_g6_gate` / `animation_check_g6` / `animation_check_g6_arms` the user ran was not said.
- [ ] G6-10b. **Real Vita: the animation-check build crashed** (the user did not say which build or when). Vita3K runs it fine. The first suspect, found by reading the program parameters of the generated `.gxp` files, is below; `animation_check_g6_v1/v2/v3.vpk` are the bisect builds.

## Not verified

- Nothing has run on a real New 3DS LL or a real Vita. The 3DS vertex shader's `mova a0.x` indexing and the `UNSIGNED_BYTE` attribute loaders are exactly what the gate build checks:
  Azahar accepted them and drew the pose the numbers say, and Azahar has accepted shaders the real GPU hung on before (`docs/shader_pica.md`).
- The PC render was checked against screenshots and the palettes by the unit tests (against numpy); there is no pixel-level test that a skinned draw with the identity palette lights
  identically to an unskinned one. The bug that test would have caught (joints reaching the shader as denormals) was found by the first render instead.
- The 3DS and Vita cost figures in this plan are still arithmetic; no frame times were measured on hardware. Azahar and Vita3K sit at 60 fps vsync.

## Addendum: animation layers are in G6 (proposed API, needs the user's approval before any of it is coded)

**Scope change (2026-11-26, the user):** layers are part of G6, not deferred, because a game the user plans needs them. This **supersedes** the "layers left out" text above
(the bullet "What leaving layers out costs", the approved answer "layers left out", and the Outcome line that says the same). The joint limits stay a per-target `Skin_Settings` field, as already built.

### What `main` has (read from `main:matchbox/animation3d.odin`)

- `MAX_ANIMATION_LAYERS :: 2`, an array size. `Animator.layers: [2]Animation_Layer`; `Animation_Pose.layer_locals: [2][]Transform` is one scratch pose per layer.
- `Animation_Layer` = a playback (`using`), `mask: []bool` (one bool per skeleton node, a copy the layer owns), `weight` (0..1, set by the game), `active`.
- `animation_mask_below(model, root)` (a node and everything under it) and `animation_mask_named(model, names)` build masks.
- `play_animation_layer(animator, model, layer, name, mask, looping)` (idempotent for the clip already playing), `stop_animation_layer`, `set_animation_layer_weight`.
- `update_animator`: after the base clip and its fade have settled into `locals`, each active layer with weight > 0 advances its clock, samples into its own scratch pose, and for every masked node
  mixes `locals[n] = mix(locals[n], layer_locals[n], weight)` (slerp / lerp). Layers run in index order, later ones on top. An unused layer costs nothing.
- **Not in `main`:** additive clips, per-joint mask weights (a mask is on or off), automatic fade in or out of a layer (the game ramps `weight` itself), a crossfade between two clips on one layer (a switch snaps).

### Proposed here, in this branch's style

**Types** (in `animator.odin`):

```odin
MAX_ANIMATION_LAYERS :: 4 // an array size, the one exception CLAUDE.md allows: Animator holds a fixed array of layers, so no heap list and nothing new to destroy

Animation_Layer_Mode :: enum {
	REPLACE,  // the layer's pose takes over its masked joints, mixed by strength: an upper-body clip over a walk
	ADDITIVE, // the layer's pose minus its clip's own first frame is laid on top: a flinch, a head turn, breathing
}

Animation_Layer_Fade :: struct {
	duration:  f32, // seconds to ease in on play and out on stop or finish; 0 snaps. Default 0.2, as the base clip's fade
	level:     f32, // 0..1, where the fade is now: the layer's strength is weight * level
	direction: int, // +1 in, -1 out, 0 steady
}

Animation_Layer :: struct {
	using playback: Animation_Playback, // clip, time, speed, looping, playing: a game polls `layer.playing` to see a one-shot finish
	mode:   Animation_Layer_Mode,
	mask:   []f32, // one weight 0..1 per skeleton node, a copy owned by the animator; 0 = the layer does not touch that node
	weight: f32,   // the game's strength, 0..1
	fade:   Animation_Layer_Fade,
	active: bool,  // contributing to the pose: from play until the fade-out ends
}
```

`Animator` gets `layers: [MAX_ANIMATION_LAYERS]Animation_Layer`; `Animation_Pose` gets one scratch `[]Transform` per layer, and each layer a mask of node-count floats. All of it is allocated in `create_animator` and freed
by `destroy_animator`: the same single allocate and single free the animator already has, nothing mid-frame. Slots at or above `mbi.skin_settings.layer_limit` allocate nothing and refuse a play.

**Why the layer count is a constant:** a fixed array is what keeps the animator one allocation with no list to grow or destroy. The constant is the array's size (the exception CLAUDE.md names), and the limit that
actually applies on each target is a settings field (below), so the constant only has to cover the largest target.

**Why a mask of weights, not `main`'s bools:** an upper-body mask with a hard edge at the spine shows a seam where the layer's pose meets the walk's. A ramp (spine 0.3, chest 0.6, shoulders 1) hides it, and a bool mask is the 0-or-1 case of the same thing, so nothing is lost.

**Procedures** (one verb per action; layers are numbered from 0, a higher one draws over a lower one):

| Procedure | Does |
|---|---|
| `play_animation_layer(animator, model, layer, name, mask, mode := .REPLACE, looping := true) -> bool` | starts the clip on a layer (false and a log line for a bad layer, name or mask length). The clip already playing only updates `looping`, `mode` and the mask, so a state machine may call it every frame. A *different* clip on a playing layer snaps to it (as `main`) and keeps the fade level. Fades in over `fade.duration` |
| `play_animation_layer_index(animator, model, layer, index, mask, mode, looping) -> bool` | the same by clip index |
| `stop_animation_layer(animator, layer)` | fades the layer out over `fade.duration`, then clears `active`; with a duration of 0 it is gone at once and the masked joints return to the base |
| `set_animation_layer_weight(animator, layer, weight)` | sets `weight` (clamped 0..1); the game may animate it itself |
| `set_animation_layer_mask(animator, layer, mask) -> bool` | replaces the mask without touching the clip (false for a wrong length) |
| `calculate_animation_mask_below(model, root, falloff := 0, allocator := context.temp_allocator) -> []f32` | the node `root` and everything under it at 1; `falloff` > 0 also gives that many ancestors a ramp (3 gives 0.25, 0.5, 0.75 up the spine) |
| `calculate_animation_mask_named(model, names, allocator := context.temp_allocator) -> []f32` | exactly the named nodes at 1 (an unknown name logs an error and is left out) |

The mask builders are `calculate_` because they work the answer out of the skeleton on each call; they return temp memory by default because `play_animation_layer` copies the mask in, so a game never frees one.

**Finished is polled, never called back.** A non-looping layer clip that reaches its end sets `layer.playing = false`, then fades out on its own over `fade.duration` and clears `layer.active`. A game reads
`animator.layers[1].playing` (the one-shot ended) or `.active` (it has left the pose entirely). No `on_finished`.

**How `update_animator` composes** (after the base clip and its fade have settled into `pose.locals`, before `resolve_skeleton_pose`): for each layer from 0 up that is `active` with strength `weight * fade.level` above 0:
advance its clock; sample **only the nodes whose mask weight is above 0** into its scratch pose; then for each such node, with `s = strength * mask[n]`:

- `REPLACE` mixes `locals[n]` towards the layer's pose by `s` (slerp for rotation, lerp for translation and scale).
- `ADDITIVE` takes the layer's sampled pose against its clip's own first frame (translation and scale as a difference, rotation as `layer * inverse(first)`) and applies that scaled by `s`: translation and scale added, rotation slerped from identity by `s` and multiplied in.
  The first frame is sampled once, when the clip starts. A clip that is meant to be additive should be authored so its first frame is its rest.

An inactive layer, or a strength of 0, costs nothing and does not advance its clock.

**Additive is proposed even though `main` has none:** the game the user plans will want a hit reaction or a breathing loop over whatever the base is doing, which a replace layer cannot do without the base clip's pose being known. It costs one extra multiply per node and a stored first frame, and leaving it out later would be an API break.

### Cost, and the per-target limit

`layer_limit` joins `Skin_Settings` (per target in each backend's defaults, "revisit later" like the joint limit): **4 on PC, 2 on the Vita, 2 on the 3DS**. `MAX_ANIMATION_LAYERS` is 4 only because the array is sized for the largest target.

Per update, per layer, as arithmetic (nothing measured, the same basis as the 3DS figures above): per masked node a layer samples its tracks (a bisect and an interpolation, one of them a slerp) and mixes into the pose (another slerp and two lerps).
With soft-float at about 40 cycles an operation and `acos` and `sin` at about 1,000 cycles each in a slerp, that is on the order of **14,000 cycles a node: about 17 microseconds on a New 3DS (804 MHz), about 50 on an old 3DS (268 MHz)**.
A layer masked to the 20 joints of an upper body is about 0.35 ms on a New 3DS; the same layer over a 60-joint skeleton is about 1 ms, which roughly doubles the base pass.
Hence: the pass runs over masked nodes only, a zero-strength layer is free, and two layers is the sensible handheld ceiling. The palette work is **not** multiplied by layers: it runs once, after all of them. `ADDITIVE` costs the same as `REPLACE` plus one rotation multiply a node.

### Tests that assert on numbers (written with the layer code)

- `tools/make_test_skinned_model.py` gains a third clip on the test arm, `"Nod"` (J2 rotating LINEAR 0 to 30 degrees about Z over one second), and prints numpy palettes, from the glTF spec's formulas and no Matchbox code, for each case below.
- **Upper-body over base, worked by hand:** base "Wave" at t = 1 with layer "Bend" (a fixed 45 degree bend at J1) masked to J1 and below at weight 1: J1 is 45 degrees and J0 is still the base's (the mask leaves it alone). At weight 0.5: J1 is the half-way
  mix of the two rotations. With a mask of 0.5 on J1 and weight 1: the same half-way mix. A mask of zero everywhere: the base pose exactly.
- **Additive:** "Nod" over "Wave" at t = 1 (layer at t = 1 too): J1 as the base, J2 turned a further 30 degrees; at layer weight 0.5, 15 degrees.
- **Fades and polling:** a one-shot layer's `playing` goes false at its end and `active` false a fade later; `stop_animation_layer` with a fade of 0.2 is at half strength after 0.1 s (eased as the base fade is); an inactive layer does not advance its clock.
- Two animators on one model with different layers do not touch each other; `calculate_animation_mask_below` against a hand-counted subtree of the arm and the rope; a wrong-length mask is refused; a layer at or over `layer_limit` is refused.

### The example

`examples/animation-check` gains a layer: the right ribbon's base clip plays "Wave" and a layer plays "Bend" masked to J1 and below (with `-define:MODEL=arms_rig.glb`, a base clip plus an upper-body clip on a layer masked below a node named by a `#config`).
The top face button (X on the 3DS, Triangle on the Vita, K on the PC) turns the layer on and off to show the fade; the HUD gains a line with the layer's clip, `playing` and `active`.

### Open questions for the user (the layer part only)

1. **Names and shape** as above: `play_animation_layer`, `stop_animation_layer`, `set_animation_layer_weight`, `set_animation_layer_mask`, `calculate_animation_mask_below` and `_named`, `Animation_Layer`, `Animation_Layer_Mode`. Right?
2. **Mask as per-node weights** (a ramp for a soft shoulder) rather than `main`'s bool per node. Agreed?
3. **Additive mode**, which `main` does not have. In, as proposed, or left out?
4. **Automatic fade in and out of a layer** (`main` leaves it to the game); in as proposed, with `fade.duration` 0 turning it off?
5. **Layer counts:** an array of 4, limits 4 PC / 2 Vita / 2 3DS. Acceptable (all three "revisit later", measured on hardware)?

## Vita crash on real hardware (2026-11-26)

**Found by reading, not yet confirmed on the console:** the unlit skinned vertex program (`mesh_skinned_v.gxp`) has no `a_normal`: psp2cgc drops an input the shader never reads, and
`strings` on the `.gxp` shows `a_position a_texcoord a_color a_joints a_weights` only. The Vita backend built the attribute list with all six names and `gfx.attribute` gives a missing
parameter register index 0, so `a_normal` sat on `a_position`'s register: two attributes on one register. Vita3K accepts that; real GXM may refuse it or fault. `init` makes both skinned pipelines
whatever the lighting, so a build would fail at launch, before the first frame. **Fix:** the attribute list now leaves out an input the program does not have (`render_vita_freestanding_arm32.odin`).
The unskinned unlit mesh never had this: its list is the three inputs it reads.

**Ruled out by reading:** the vertex uniform buffer (the palette is 3 x 64 x 16 = 3 KiB plus the other uniforms, a draw reserves it from the 2 MiB vertex ring buffer, `GXM_DEFAULT_VERTEX_RING_BUFFER_SIZE`; the
64 KiB in this plan was a recollection and is not a limit that is near), the stream stride (56 is a multiple of 4), the attribute offsets (joints at 48, weights at 52), the index alignment
(the indices follow a vertex block that is a multiple of 4 bytes), and mesh size (6 vertices for the test ribbon, 758 for `arms_rig`, far from the 65,536 a 16-bit index allows).
**Not ruled out:** that a raw `U8` attribute (not normalised) reaches a `float4` input as 0..255 on the real GPU (Vita3K does it that way; no source here says otherwise); the integer indexing of a Cg array
by a float cast; the real `sceGxmSetUniformDataF` on a 64-element array parameter.

**Builds, one change apart** (all `examples/animation-check` with `test_arm.glb`, in `build/hardware/`, each writes lines to `ux0:data/matchbox.log` before each stage: `stage 1: init`, `2: init done`, `3: model loaded`,
`4: animators made`, `5: frame n start`, `6: frame n drawn`, and `pipelines: ...` lines in `init`; the last line says how far it got):

| build | title (id) | differs from the one above by |
|---|---|---|
| `animation_check_g6_v1.vpk` | AnimCheck G6 v1 (MBOX00064) | the `a_normal` fix, plus the stage prints. Everything else as `animation_check_g6.vpk` |
| `animation_check_g6_v2.vpk` | AnimCheck G6 v2 (MBOX00065) | v1 without the palette upload (`set_uniform` of the three row arrays): a skinned part draws with whatever the uniform buffer holds |
| `animation_check_g6_v3.vpk` | AnimCheck G6 v3 (MBOX00066) | v1 without drawing any skinned item: pipelines and models load, nothing skinned is issued |

Reading the result: v1 runs, done. v1 crashes and v3 runs: the draw is the problem (vertex format or palette upload), and v2 says which. v3 crashes too: it is pipeline creation, and the last printed line says which.
**To get the log:** after a crash open `ux0:data/matchbox.log` with VitaShell (or FTP) and send the last lines; a crash screen or a `C2-xxxx-x` code is also worth writing down.
