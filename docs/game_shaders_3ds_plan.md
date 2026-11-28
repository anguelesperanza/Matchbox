# Game shaders on the 3DS: plan

Status: **plan only, nothing built** (2026-11-27). Companion to `game_shaders_plan.md`, which did the PC side and left the
handhelds as panic stubs (`shader_3ds_freestanding_arm32.odin` and `shader_vita_freestanding_arm32.odin`). The Vita is not in this plan.

## Where things stand

- The 13 test shaders in `games/shaders/*` compile with mbsc for the 3DS, and each project's `build_shaders.bat` now writes
  `assets/3ds/shaders/<name>.3ds.v.pica`, `.3ds.tev`, `.3ds.refl` and `.3ds.shbin` (picasso accepts all of them, lava's
  vertex program included). Nothing reads those files.
- `matchbox/render_3ds_freestanding_arm32.odin` already draws everything from a `Render_Pipeline` that holds a program, a
  parsed TexEnv plan (`Tev_Plan`) and uniform locations, and `load_render_pipeline(pipeline, shbin_path, tev_text, lighting,
  skinned)` already builds one from a `.shbin` and a `.tev`. The five built-ins are loaded by it at `init`, with the `.tev`
  `#load`ed. **A game shader is the same thing loaded later, from romfs, by name.** That is why this is a modest job and not
  a new renderer.
- `set_shader` and `Render_Item.shader` are shared code and already work; `sort_render_queue` already groups by shader.

## What stops a game shader on the 3DS today

1. `load_render_pipeline` panics when a uniform the engine sets is missing (`render_tint`, `render_uv_rectangle`,
   `render_model`, `frame_view_projection`). A game shader only declares the ones it reads, so these must be optional
   (-1, and the set calls skip them). Note `use_render_pipeline` / `set_camera_uniforms` are the only places that set them.
2. The lighting mode is a parameter (`.PER_PIXEL`, `.PER_VERTEX`, nil) and the vertex layout follows it. For a game
   shader both come from the files: lit with the lighting unit if the `.tev` says `lighting diffuse|specular`; reads a normal
   (Lit_Vertex layout, attribute 3) if the `.3ds.refl` has `attribute normal`. hologram, shield and snow read the normal
   without using the unit, so "reads a normal" and "uses the lighting unit" must become two fields (PC has `reads_normal`).
3. **Game uniforms** (`heat`, `time`, `ripple_*`...) have no path: `ensure(stage.constant_uniform == "", ...)` and nothing
   implements `set_shader_value`. mbsc's PICA output declares them as ordinary vertex uniforms, found by name with
   `shaderInstanceGetUniformLocation` like the engine's.
4. **`frame_time`** is a uniform in several test shaders (lava) and the built-ins never read it, so the 3DS engine never
   sets it. Every `frame_*` / `render_*` field a custom shader may declare needs to be set by the engine; list them from
   `docs/shader_reflection.md` and set the ones the shader has.
5. Uniform registers are **shared by every program** (citro3d has one array per stage), which `set_camera_uniforms` already
   handles by setting them again after each switch. Game uniforms need the same: keep them in a CPU shadow per shader and
   upload the whole shadow at every bind, not only when `set_shader_value` was called.
6. Nothing copies the files to romfs; `3ds_build.bat` only assembles the five built-ins.
7. A game shader's `.tev` may use `constant <uniform>` or an alpha test uniform; both are `ensure`d off. The test shaders'
   plans use literal constants and `alphatest GEQUAL 0.9` (dissolve), so literal paths suffice for the first pass; uniform
   constants can wait unless a test shader needs one (check each `.3ds.tev`: grep `constant` for a name).

## Design

Same model as PC, so a game does not change: `load_shader("toon")`, `set_shader`, `set_shader_value(name, value, shader)`,
`destroy_shader`. Names resolve to `romfs/shaders/<name>.3ds.shbin` + `.3ds.tev` + `.3ds.refl` and, optionally,
`<name>_skinned.*`. Files are **read at run time, not `#load`ed**, so a game that does not name a shader carries none of it
(the point of the PC work).

`Shader.data` points at a `Shader_Data` like PC's: `plain` and `skinned` pipelines, `reads_normal`, the game-uniform shadow.
`choose_shader` follows the PC rules exactly (skinned mesh needs a `_skinned` variant; a shader that reads the normal draws
only lit meshes; otherwise the built-in), and the choice goes in `choose_render_pipeline` ahead of the built-in ones.
Because the PC and 3DS rules are identical, **move `choose_shader`'s decision into a shared file** (a small pure proc over
`has_plain`, `has_skinned`, `reads_normal`, mesh flags) so there is one copy, tested on PC.

Game uniforms: the 3DS reflection lists each `uniform <name> <type> <registers>`. `set_shader_value` writes the value into
the shadow as whole vec4 registers (f32 -> {v,0,0,0}, [2] and [3] padded, [4] as is, matrix as four registers in the same
row order `set_matrix_uniform` uses, arrays and struct leaves by their dotted names), and the bind uploads the shadow with
`C3D_FVUnifSet`. The packing is pure, so **put it in a shared (untagged) file and test it on PC**, as the PC reflection
writer is tested.

**S8-2 to S8-5 done 2026-11-27, Azahar only.** Loader (`create_game_render_pipeline`), `load_shader` and friends
(`shader_3ds_freestanding_arm32.odin`, files read from romfs at run time), the `3ds_build.bat` romfs copy, and two examples:
`shader-3ds-check` and `shader-3ds-all` (all 12 distinct shaders load and draw with pixel facts, 0 failures; a mutation run
makes 6 checks fail). No register, temporary or instruction limit was hit in Azahar. Not verified: real hardware (lava's
512-instruction vertex program first), skinned variants, arrays and structs, frame times. The ten test games: crt and haze
stop at run time on a `set_shader_value` for a uniform the 3DS shader dropped (by design); all use `core:log`, which does not build
for the handhelds.

**Real New 3DS LL, first pass (2026-11-27, reported by the user).** All ten games draw their shaders as expected. Open:

- **Quitting (START) hangs or crashes on some games:** water and lava freeze, shield and styalized-water crash; the others quit
  cleanly. Azahar does not reproduce it. Unverified suspicion: `cleanup` frees meshes (`linearFree`) and game shader programs
  while the GPU may still be reading the last frame, and the 3DS path does not wait (the Vita calls `gfx.finish()` first), so the
  heavier scenes lose the race. A `c3d.FrameSync()` before those frees is the candidate fix. The crash-screen text or the o3dx
  SD log would confirm it.
- **styalized-water has no green and no white flecks on the 3DS. Expected:** colour is per-vertex there, and the 3DS
  `dreamcast_water` drops the caustic web and the white ripple flecks (the fragment stage cannot compute them).

## Steps (each ends in a check; stop and report after each)

**S8-1 status: done 2026-11-27, PC-tested only.** `matchbox/shader_pica.odin` (shared): `parse_pica_reflection`,
`pica_reads_normal`, `is_engine_uniform`, `Shader_Facts` / `choose_shader_variant` (PC's `choose_shader` now calls it),
`Pica_Game_Uniforms` with `create_`/`destroy_`/`set_pica_game_value`. 9 tests in `shader_pica_test.odin` (228 in the package,
all pass); three mutations (matrix by columns, skinned falling back to plain, engine uniforms counted as the game's) and a fourth
that found a real bug (a refused value wiped the old one) each fail a test. 3DS and Vita `odin check` give 0 errors. Not done:
arrays and structs (each leaf is its own uniform under its own name; untested), `f32`-only scalars (no i32/u32), uniforms read
only by the fragment stage (not in the 3DS reflection).

**S8-1 as planned. Shared pieces, tested on PC.** Pure procs: the shader-choice rule; the value -> vec4 register packing from a
parsed 3DS reflection (needs a reader for `.3ds.refl`: `uniform <name> <type> <registers>`, `attribute <name> <type> <n>`;
check `docs/shader_reflection.md` and whether `parse_reflection` already accepts `target 3ds` before writing one).
Check: new tests pass, including a mutation (break the packing, see it fail); `odin test matchbox` still green; the 3DS and
Vita `odin check` still 0 errors.

**S8-2. Make the pipeline loader take a game shader.** Optional engine uniforms; lighting and normal read from the files;
`frame_time` and the other declared `frame_*`/`render_*` fields set when present; the `ensure`s that guard the built-in
assumptions relaxed only for game shaders. Built-ins unchanged. Check: the built-in demo (`examples/shia-test`, `render-check`)
still builds and passes in Azahar exactly as before (21 probes, failures 0).

**S8-3. `load_shader` / `destroy_shader` / `choose_shader` / `set_shader_value` on the 3DS**, replacing the panic stubs. A
missing file is `ok = false` in `load_shader_checked` (as on PC), a plan the engine cannot honour is a stop with a message.
Game-uniform upload at bind. Check: a tiny example (`examples/` or a copy of the `crt` game) that loads one shader.

**S8-4. Build step.** `3ds_build.bat` copies the game's `assets\3ds\shaders\*.3ds.shbin|.tev|.refl` into `romfs\shaders\`
(a game without that folder builds as before). Check: build the example, `romfs` has the files, the `.3dsx` is not larger for
a game with none.

**S8-5. Run the 13 shaders in Azahar,** easiest first: haze, crt, hologram, shield (REPLACE / plain stages), then toon, water,
sand, dreamcast_water, snow, lava, dissolve (lit, alpha test, skinned not needed). Each with a unique build name and title
(memory: unique names for test builds), a screenshot per shader, and a comparison against its PC look read from the shader's
own comment on what was dropped. Azahar is not hardware: it drew a shader the real New 3DS LL hung on once (partial output
write, `docs/shader_pica.md`), so **the user's console run is the pass**, and the lava vertex program at the 512-instruction
limit is the first one to try there.

**S8-6. Docs and cheatsheet:** `docs/api.md` (3DS now supported), `game_shaders_plan.md` status, `shader.odin` comment that
says "PC only for now", `python tools/gen_cheatsheet.py`.

## Two catch-22s the test shaders hit on the 3DS (2026-11-27)

Both come from the 3DS having no fragment program, only six fixed TexEnv stages (docs/shader_pica.md, "The fragment stage"). They are
why crt and haze draw almost nothing of their effect there, and why the games had to stop setting their uniforms on the 3DS.

1. **Per-pixel maths cannot run, and a full-screen quad has four vertices to put it in.** crt (curvature, colour fringing,
   scanlines, phosphor mask, vignette) needs `dot`, `floor`, `cos`, `step` per pixel. mbsc reports these in a fragment shader
   as MBS-E2 and will not approximate. Moving the maths to the vertex stage does nothing for a post-process: its picture is
   one quad. The 3DS crt keeps only the flicker (texture times vertex colour). The way out is a baked scanline and mask
   texture drawn over the picture (a new asset), not a shader change.
2. **A computed texture coordinate cannot be sampled.** haze's heat shimmer is `sample(tex, uv + offset)` per pixel, which
   is MBS-E20. The same quad problem applies: a per-vertex offset on four vertices only sways the whole picture. The 3DS
   haze is a plain sample. The way out is a game change: draw the scene onto a subdivided grid (for instance 32 x 18) and
   offset the vertices, so the wobble is done in the vertex stage.

A consequence for games: a uniform the 3DS shader dropped is not in its reflection, so `set_shader_value` for it stops with
"the shader has no uniform called ...". On purpose: a wrong name must not be ignored. crt and haze skip those calls on the 3DS
with a `THREE_DS` constant (`ODIN_OS == .Freestanding && ODIN_ARCH == .arm32 && ODIN_MICROARCH_STRING == "mpcore"`).

## Not in this plan

Vita game shaders (needs vito/`.gxp` per game shader). A texture asset for the dropped effects (shield's hex grid wants a
64x64 L8 repeating texture, described in the shader's report). Subdividing quads in games so per-vertex effects look better.
More than one texture per draw (`ensure(tev.texture_count <= 1)` stays).

## Decisions for you

- **D1. Run-time files from romfs, not `#load`** (recommended; keeps optional shaders out of games that do not use them), or
  `#load` at build time (simpler, but every game carries every shader it names, and the name must be known at compile time).
- **D2. S8-5 order and screenshots** are mine to run in Azahar; the real-console pass is yours.
- **D3. First pass supports literal TexEnv constants only.** Measured from the 13 generated `.3ds.tev` files: none uses a
  uniform constant, and the only alpha test is the literal `GEQUAL 0.9` (dissolve). Uniform constants wait for a shader that needs one.

Measured from the 13 `.3ds.refl` files, the uniforms the engine must set beyond today's: `frame_time` (8 of 13 shaders),
`frame_view` (10) and `render_tint` (11) are optional in some, `render_uv_rectangle` appears in only 2. Game uniforms in
use: `wave_height` (2), `heat` (2), `snow_depth`, `snow_amount`, `progress`, `island`, `hit_a`, `hit_b`, `hit_c`, `glitch`:
all scalars or vectors, no arrays or structs, so the first packing pass needs only f32, [2..4]f32 (check each type in S8-1).

Not measured yet: the register/instruction headroom of any of these on hardware, and whether Azahar runs a `.shbin` loaded
at run time the same as one loaded at `init` (it should; same loader).
