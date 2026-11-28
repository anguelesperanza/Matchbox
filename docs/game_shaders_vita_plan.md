# Game shaders on the Vita, and the order for both handhelds

Status: **plan only** (2026-11-27). Read with `game_shaders_3ds_plan.md` (3DS track; S8-1 is done) and `game_shaders_plan.md`
(PC, done).

## Can the Vita do custom shaders? Yes, and it is the easier of the two

Measured today, not assumed: I ran all 13 test shaders in `games/shaders` through `mbsc -target:vita --emit-cg` and then
the real `psp2cgc` (`../vito/tools/psp2cgc.exe`, vertex `sce_vp_psp2` and fragment `sce_fp_psp2`).

- **12 of 13 compile to `.gxp`** with no change to any shader: dissolve, haze, haze/lava, hologram, lava, shield, snow,
  dreamcast_water, sand, water (x2), toon. They take the PC code (the `else` of each `when TARGET == .PICA200`), so on the Vita
  they are the full effect, not the 3DS's per-vertex reduction.
- **1 fails: crt's fragment stage**, with `error D4463: expected an identifier but found keyword 'column'`. `column` is a Cg
  reserved word and mbsc writes the shader's own local name through. That is an mbsc bug (the 3DS generator already renames
  names that look like registers; the Cg one has no list of Cg keywords), not a Vita limit.
- Not measured: that any of the 12 runs, draws right or holds a frame rate on a Vita. dreamcast_water and snow have the
  biggest fragment programs (the lava vertex+fragment pair is 6.4 KB + 3.5 KB); Vita per-pixel lighting was accepted at about
  30 fps before, so budget is a real question for the heavy ones.

Why it is easier than the 3DS: the Vita has real vertex and fragment programs, so nothing has to be rewritten per vertex, and
`gfx.register_program(bytes)` already takes a `.gxp` from memory at run time. The built-ins use it with `#load`ed bytes; a game
shader is the same call with bytes read from the `.vpk` (`app0:/assets/shaders/`) by name.

## What stops a game shader on the Vita today

1. `load_shader` is a panic stub (`shader_handheld_freestanding_arm32.odin`, shared with the 3DS).
2. `load_render_pipeline` (Vita) panics if an engine uniform is missing. `psp2cgc` drops a uniform the program never reads
   (the file already says so), so a game shader that ignores the tint or the uv rectangle would stop. They must be optional.
3. Its vertex attributes come from `lighting != nil` and `skinned`. A game shader keeps whichever attributes it reads
   (`add` in the skinned path already skips a dropped one). Needs: normal present = Lit_Vertex layout, from the `.gxp`'s own
   parameters or the `.vita.refl` `attribute` lines.
4. Fragment programs are made one per `Blend_Mode` up front (GXM ties a fragment program to a blend mode); a game shader needs
   the same two.
5. The texture is looked up as `"tex"` (`gfx.texture_unit(fragment, "tex")`). Both test shaders that sample name it `tex`, but
   a game shader may not; read the unit from the `texture <name> <slot>` line of the reflection.
6. **Game uniforms:** nothing sets them. On the Vita it is cheap: `gfx.use_programs` hands back per-draw uniform buffers and
   every draw already writes every uniform, so the game's values are written from a CPU shadow each draw with
   `gfx.set_uniform(buffer, gfx.parameter(program, name), floats)`. Arrays and struct leaves are already single named
   parameters (`key_light.strength`, `lights[1].color`), so they are supported from the start, unlike the 3DS.
7. Engine **lights**: toon, shield, lava and others list `lights_*`, `render_shininess` and `render_specular_strength` in
   their reflection. The built-in lit path (`set_light_uniforms`) already knows how to fill them, per program. A game shader
   that has those parameters should get the same call, writing into whichever of its programs reads them.
8. No build step: `vita_build.bat` does not copy anything for a game shader into the `.vpk`.

## The shared work (do once, for both)

- One `Shader` model, already in place: `load_shader`, `load_shader_checked`, `set_shader`, `set_shader_value`,
  `destroy_shader`, names resolve to `<name>` plus optional `<name>_skinned`.
- `choose_shader_variant` (done in S8-1) is the one rule for which variant draws a mesh.
- Replace `shader_handheld_freestanding_arm32.odin` with one file per target (`shader_3ds_...`, `shader_vita_...`), each
  inside the `when VITA` / `when !VITA` split the other handheld files use.
- `find_asset(.SHADER)` equivalent for each target's file system (romfs on the 3DS, `app0:/assets/` on the Vita).
- `game_shaders_plan.md` and `shader.odin`'s "PC only for now" lines.

## Status (2026-11-27)

**V1 and V2 done.** V1: `tools/mbsc/cg.odin`'s reserved-word list gained the ~70 words `psp2cgc` rejects as a name (found by
trying each as a local; `column` and `row` are not on the Cg spec's list), with `names_psp2cgc_rejects_are_renamed`
(checks the rename and compiles with the real `psp2cgc`; deleting `column` from the list makes it fail). `odin test tools/mbsc`:
140 pass. All 13 test shaders now compile to `.gxp`; the other 12 produce Cg identical to before, only crt's changed.
V2: each project's `build_shaders.bat` writes `assets\vita\shaders\<name>_v.gxp`, `_f.gxp` and `.vita.refl` (the `.cg`
intermediates go to `build\vita_shaders`), finding `psp2cgc` through `PSP2CGC` or `..\..\..\vito\tools\psp2cgc.exe`;
`vita_build.bat` (the repo's and the ten projects' copies) stages `assets\vita\shaders` into the `.vpk` as `assets/shaders/`.
All ten projects build all three targets (exit 0). Not verified: a full `vita_build.bat` run to a `.vpk` (only the staging
`xcopy` was run on its own), and nothing reads these files yet. The per-project `tools\mbsc\mbsc.exe` copies had to be
replaced with the new build; a project with an old copy fails on crt's `column`.

**V4 and V5 done (2026-11-27, Vita3K only).** `create_game_render_pipeline` (render_vita_freestanding_arm32.odin) builds a pipeline from gxp bytes and reflection; `shader_vita_freestanding_arm32.odin` has `load_shader`, `load_shader_checked`, `set_shader_value`, `destroy_shader`, reading `app0:/assets/shaders/` at run time. `examples/shader-vita-check` loads shield, hologram, toon, lava, haze and crt in Vita3K: all load, all draw 150 frames, no crash, 0 failed checks; built-ins unchanged (`examples/vita-check`, 14 steps). Not seen: the pictures (no screen access), skinned variants, anything on a real Vita.

**V3-V6 done 2026-11-27, Vita3K only.** Shared reader (`shader_vita.odin`), loader (`render_vita_freestanding_arm32.odin`),
`load_shader` and friends (`shader_vita_freestanding_arm32.odin`, files read from the .vpk at run time) and `examples/shader-vita-check`
(38 checks, failures 0; all 13 shaders and the ten test games run in Vita3K with the expected pictures). Vita3K cannot say how
heavy dreamcast_water or snow are (vsync and the PC GPU hide it); that, the real-Vita attribute crash risk and skinned variants
are not verified. The ten test games do not compile for the Vita as written (`log.create_console_logger` is PC only) and have
no way to quit; see the report to the user.

**Real Vita, first pass (2026-11-27, reported by the user).** Eight of the eleven test games behaved as on the PC. Two findings:

- **Frame rate: styalized-water (dreamcast_water, sand), haze and lava run at very low FPS on the Vita.** These are the shaders with the
  heaviest fragment programs; the Vita takes the full PC code for them. Accepted for now as a cost of the language tests (D3);
  not measured with `get_gpu_times`. A `when TARGET == .VITA` reduction is the way out if one is wanted.
- **dissolve did not dissolve fully, fixed:** the burn came out as per-pixel static and the object never fully went. It was not
  the noise hash (the sine-free hash changed nothing). A diagnostic build with the same maths drew correctly, and a variant
  with `discard` moved to the end of `fragment_main` also did, so on a real Vita **a `discard` placed before the rest of the
  fragment's work gave wrong results; put it last**. Vita3K draws either order right, so it cannot catch this. The cause is
  not known (psp2cgc or the GPU); dissolve now has a `when TARGET == .VITA` fragment with the discard last, PC and 3DS output
  unchanged. Other shaders that discard early (none of the other test shaders do) may need the same.

## Steps, Vita track (V1-V6; each ends in a check and a report)

**V1. mbsc: rename Cg keywords.** Reserved words (`column`, `row`, `half`, `fixed`, `sampler`, `texture`... the list from the
Cg spec, checked against what psp2cgc rejects) are renamed in the Cg output the way the 3DS output renames register-like
names. Test: a shader using each as a local, compiled with the real `psp2cgc` (the existing `cg_compile_test.odin` skips
without it). Check: crt compiles to `.gxp`, all other outputs byte-identical to before, `odin test tools/mbsc` green.

**V2. Build step.** Each project's `build_shaders.bat` also writes `assets\vita\shaders\<name>.vita.refl`, `<name>_v.gxp` and
`<name>_f.gxp` (mbsc then psp2cgc, found through `PSP2CGC` or `..\vito\tools\psp2cgc.exe`, as the tests do), and `vita_build.bat`
stages that folder into the `.vpk` as `assets/shaders/`. Check: all 13 build; a game with no such folder builds as before.

**V3. Vita reflection reader (shared, PC-tested).** `shader_vita.odin`: `uniform <name> <type> <count>`, `attribute`, `texture`
lines (docs/shader_cg.md, "Vita reflection"), and the game-uniform shadow: names, float counts and offsets, value -> floats,
using the same any->value conversion rules as `set_pica_game_value` (move the common part into one shared proc rather than
copy it). Check: tests against real mbsc output from the 13 shaders, mutation-checked, as S8-1 was.

**V4. Loader.** Optional engine uniforms, attributes by what the program kept, texture unit from the reflection, a second
variant for skinned, both blend-mode fragment programs, lights written when the program has `lights_*`. Built-ins unchanged.
Check: Vita3K still runs `examples/render-check` (all probes pass, as before) before anything of a game shader is tried.

**V5. `load_shader` / `set_shader_value` / `destroy_shader` on the Vita, and the per-draw game-uniform write.** Check: a small
example that loads `shield` (REPLACE-like, few uniforms) and draws it in Vita3K.

**V6. Run all 13 in Vita3K,** hologram, shield, haze, crt first, then lit and heavy ones. A screenshot each, and the frame
time (`get_gpu_times`) for dreamcast_water and snow. Vita3K is not hardware: the real Vita crashed once on two attributes
sharing a register that Vita3K accepted (see `add` in the skinned path), so **the user's run on a real Vita is the pass**, and
the first thing to try there is one shader per run with a log file (memory: Vita prints to a log file).

## Order and who does what

1. 3DS track S8-2 to S8-4 (loader, `load_shader` stubs replaced, romfs copy), already planned.
2. Vita V1 and V2 can start at once: they touch `tools/mbsc` and the `.bat` files, not the renderer, so they do not collide
   with the 3DS loader. V3 touches only new shared files.
3. Vita V4 and V5 touch `render_vita_freestanding_arm32.odin` and the new Vita shader file; the 3DS loader touches
   `render_3ds_...`. Different files, so the two runtimes can be built by two agents at once, each in its own file, after the
   shared split of `shader_handheld_freestanding_arm32.odin` is done by one of them first.
4. Both hardware runs are yours; I run Azahar and Vita3K.

## Decisions for you

- **D1. Vita first or 3DS first for the first picture on a console?** Recommended: keep the 3DS S8-2..S8-4 going and run
  V1/V2 beside them; the Vita runtime (V4-V5) is smaller and gets all 13 effects at full quality, so it gives the quickest
  look at the real shaders.
- **D2. Vita game-shader files read at run time from the `.vpk`, not `#load`ed** (same reasoning as the 3DS: a game that
  names no shader carries none).
- **D3. Heavy shaders.** If dreamcast_water or snow run too slowly on the Vita, do we accept the cost (they are tests of the
  language), or add a `when TARGET == .VITA` reduction as was done for the 3DS? Decide after V6 measures it.
