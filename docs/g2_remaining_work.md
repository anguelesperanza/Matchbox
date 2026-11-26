# G2 lighting: what is left, for the agents that finish it

Written 2026-11-25, at the end of the session that did G2 L4 and L5-0 to L5-3; updated the same day with the user's
new working rules and their answers to the open decisions. **This is the brief the next session's agents work
from.** The full history and every measurement is in `docs/3ds_fragment_lighting_plan.md` (the plan); house style is
`CLAUDE.md`; build and check commands are in `docs/next_session_handoff.md`. Read all three before starting.

---

## 1. Where things stand

**Committed:** G2 L0 to L4 (pushed, up to `1a8cea4`), and L5-0 to L5-3 with this file (committed after it, not
pushed). Lit models draw per pixel on PC, the 3DS and the Vita, and passed on the New 3DS LL and the real Vita.
Per-vertex lighting (L5) draws on all three, checked on PC and in Azahar and Vita3K only.
- **L5-0** (mbsc): shaders may declare `@(uniform = .LIGHTS) lights`; `LIGHT_SLOT_COUNT` is predeclared (64 on PC, 8
  on the handhelds).
- **L5-1**: `matchbox/shaders/mesh_vertex_lit.mbs`, generated for all three targets, checked against an f64 model.
- **L5-2** (API): `Lighting_Mode{PER_PIXEL, PER_VERTEX}`, `Lighting_Settings.mode` (the scene's default),
  `Material.lighting:Maybe(Lighting_Mode)` (nil follows the scene), `get_lighting_mode`.
- **L5-3**: the 3DS and the Vita draw per vertex.
- `tools/capture_window.ps1` captures a PC build's window for measuring (section 6).

**Nothing of L5 has run on hardware yet.**

---

## 2. How the agents work (the user's rules, 2026-11-25)

**The user is involved for three things only:**
1. **A change to the Matchbox API**, meaning what a game calls (public procedures, types and fields in
   `matchbox/`), not backend code. Show the change and wait for the user's approval before writing it.
2. **A hardware check**: anything only the real New 3DS LL or Vita can answer. Make the build (rule 6) and ask.
3. **A question the agent can't answer from this doc, the plan, the code or `main`.**

Everything else, backend files included (3DS and Vita render and backend files, build scripts), the agent does
without asking.

**Commits:** at the end of a task, once it is complete and nothing in it needs the user's attention. Don't push
unless asked. Never commit `fixes.md`; leave out files that show `M` with no content change (CRLF noise).

**Reporting a finished task:** only this, nothing more:

```
What changed: <one sentence>
Why it changed: <one sentence>
Where: <the files>
```

**Comments:** a procedure's comment is **one line**, one sentence: the user edits comments, so they need the gist
only. (This replaces the longer "explain why" comments in CLAUDE.md for new code.)

**Still in force:**
4. Emulators are the agent's to run (Azahar `C:\Program Files\Azahar\azahar.exe`, Vita3K
   `C:\Users\King-\Documents\vita3k\Vita3K.exe`); hardware is the user's. Never claim something runs on hardware
   until the user says so.
5. Verify by measuring (CLAUDE.md): pixel values against a value worked out by hand or in f64. When a test is new,
   break what it checks once and see it fail.
6. Hardware test builds get their own file name, their own on-console title (3DS `TARGET` in `3ds_build.bat`; Vita
   `TARGET`, `TITLE_ID`, `TITLE` in `vita_build.bat`, changed in a scratch copy), and a first printed line naming the
   test. Put them in `build/hardware/`.
7. House style (CLAUDE.md): action-then-thing names with `create_ / load_ / destroy_ / is_ / get_ / calculate_ /
   render_`; `Pascal_Snake_Case` types; `SCREAMING_CASE` enum values, one per line; no new package constants or
   globals (array sizes, colours, `#load` excepted); no callbacks; Matchbox code written `name:type`.
8. Don't touch `games/RunTeddyRun` or the farlite repo.
9. The Vita prints to `ux0:data/matchbox.log`; what is meant to be seen on screen uses `render_text`.
10. On the 3DS use Azahar, not Citra.

---

## 3. The user's decisions

**D1. Cheatsheet:** comes after the API has stabilised; not a concern now. Drop it from L6.

**D2. More lights than the target takes:** it crashes, as now, with a one-line message printed first saying why
(e.g. "set_lights: 9 lights given, this target takes 8"). On the handhelds that line must reach the print log (3DS
bottom screen, Vita log file) before the crash.

**D3. `Lights_Block` / `calculate_lights_block`:** private when a game can't or shouldn't call them; public when that
is unknown. Both are used only by the runtimes and tests (a game never fills a lights block), so: private.

**D4. Point and spot lights:** follow `main` (`git show main:matchbox/light.odin`: `create_point_light`,
`create_spot_light` and how they fade), tweaked as needed for this branch. The tweaks are API changes, so show them.

**D5. Highlights on back faces (3DS):** culling hides them on single-sided parts; a two-sided part (culling `.NONE`,
from a double-sided glTF material) still shows them. Handled after everything else is done.

**D6. The light built-ins' names:** settled. `light_diffuse` and `light_specular` since L2, used and tested; the
plan's "revisited after L3" has no question left. Close it in the plan.

**D7. o3dx's `C3D_FVec` binding:** fix it so the fields are in citro3d's order (`w, z, y, x`, `c3d/types.h`). The fix
goes into the O3DX repo first (`C:\Users\King-\Documents\odin-projects\O3DX\`, `lib/c3d/types.odin`), then is
brought into Matchbox's copy (`matchbox/o3dx/`), and `create_citro3d_vector` in `render_3ds_freestanding_arm32.odin`
is dropped. In O3DX the fix goes on **a branch of its own, with its own PR** (the user's answer); ask the user which
branch the PR targets if it isn't clear (the repo is checked out on `bindings-complete`).

**D8. Light limits:** stay as they are: 64 on PC, 8 on the 3DS and the Vita. Target-specific limits may come later,
after more is stable and tested. Don't measure or change them now.

---

## 4. Workstreams

"Owns" lists the files a workstream changes; two running at once must not own the same file (section 5).

### W1. L5-4: model-check lit both ways, and hardware builds

- **Depends on:** nothing. First: it closes L5 and gives the user something to test.
- **Owns:** `examples/model-check/main.odin`, the plan's L5-4 entry.
- **Do:** a button that cycles the scene's `Lighting_Settings.mode` with the HUD naming it; one part whose material
  overrides the scene, so a frame mixes the pipelines; keep L4-6's lighting switch and cut-out board. Buttons are
  positions (`FACE_DOWN` is B on the 3DS, Cross on the Vita). Measure on PC and both emulators (section 6), then make
  hardware builds (rule 6) and ask the user for the hardware check.
- **Done when:** both modes and the mixed frame measured, recorded in the plan, and passed on hardware.

### W2. L7: lighting steps in the hardware check apps (DONE 2026-11-25, passed on hardware)

- **Depends on:** W1.
- **Owns:** `examples/render-check/main.odin` (3DS: reads the framebuffer back at chosen points),
  `examples/vita-check/main.odin` (Vita: on-screen steps).
- **Do:** render-check gains probes for a lit scene with values worked out by hand (per pixel and per vertex give the
  same diffuse on flat faces: (61, 93, 155) for a (0.4, 0.6, 1) face with L.N = 0.41 and 0.2 ambient), a lit cut-out,
  lighting off, a per-vertex face. vita-check gains a lighting step (per pixel, per vertex, off), each saying what it
  should look like.
- **Done when:** both pass in their emulators, and on hardware (ask the user).

### W3. L6: the API's remainder

- **Depends on:** nothing now (D1-D3 answered).
- **Owns:** `matchbox/light.odin`, `matchbox/light_test.odin`, the plan's L6 entry and open questions.
- **Do:** make `Lights_Block` and `calculate_lights_block` private (D3); give `set_lights` the one-line message
  before its crash on every target (D2); close D1 and D6 in the plan.
- **Done when:** tests and all target checks pass, and the message is seen in Azahar's print log and Vita3K's log
  file with a deliberate 9-light scene (a scratch example, deleted after).

### W4. Point and spot lights

- **Depends on:** W3 (same file). Large: write its steps into the plan first, as L4 and L5 were.
- **Owns:** `matchbox/light.odin`, `tools/mbsc/lighting.odin` and its tests, `matchbox/shaders/mesh_lit.mbs`,
  `mesh_vertex_lit.mbs` and their generated files, the three render files. Not alongside W6.
- **Do:**
  1. Read `main`'s point and spot lights (D4); show the user the API for this branch before writing it.
  2. **A 3DS hardware spike first**, as L0 was: a throwaway test (rule 6) proving a positional light (w = 1, the DA
     table) and a spot light (the SP table) on the real unit, one feature a step. The user runs it.
  3. The lights block grows what point and spot lights need per slot; `calculate_lights_block` turns positions into
     eye space with w = 1. Change mbsc's `LIGHT_UNIFORM_NAMES`, `LIGHTS_FIELDS`, `write_light_functions`, the f64
     model in `lighting_model_test.odin`, and the engine's `Lights_Block` layout check together; the stale-file
     guards name every generated file to regenerate.
  4. Per pixel on PC/Vita (generated functions) and the 3DS (the unit's positional lights, DA and SP), per vertex
     everywhere (the shader's loop). The 3DS vertex program has 16 temporaries and 512 instructions
     (`mesh_vertex_lit` is 271 now).
  5. Measure as L4/L5 did; model-check gains a point light; hardware builds.
- **Done when:** both kinds lit on all three targets in both modes, measured against an f64 model and in the
  emulators, and the spike and a model-check build passed on hardware.

### W5. Back faces on two-sided parts (3DS)

- **DONE 2026-11-25, no runtime change (the user's decision).** The hardware spike `light_test5` showed the 3DS already
  draws no highlight on a back face lit through the plane, as PC does; signed D0 and two-sided diffuse are not used. See
  the plan's L9.

### W6. mbsc: a liveness-based register allocator for the PICA backend

- **Depends on:** nothing; tools only.
- **Owns:** `tools/mbsc/pica*.odin` and their tests, the regenerated `*.3ds.v.pica`. Not alongside W4.
- **Why:** registers are freed when a block ends, not after a variable's last use, so `mesh_vertex_lit.mbs` had to be
  restructured by hand to fit 16 temporaries; point and spot lights will press harder.
- **Done when:** registers are freed after last use; every PICA test and `expect_pica_matches` passes; the
  per-vertex shader written the obvious way (the plan's L5-1 entry) fits; regenerated programs assemble and draw the
  same in Azahar (model-check per vertex measured before and after).

### W7. o3dx `C3D_FVec` (D7)

- **Depends on:** nothing; can start now.
- **Owns:** the O3DX repo's `lib/c3d/types.odin`, `matchbox/o3dx/c3d/types.odin`, `render_3ds_freestanding_arm32.odin`
  (drop `create_citro3d_vector`).
- **Do:** in O3DX, on a new branch, fix the field order (and any O3DX code or example that relied on the old order),
  commit, push and open its own PR; then copy the binding into Matchbox and use `C3D_FVec{x = ..., ...}` directly for
  light positions.
- **Done when:** model-check's lighting measures the same in Azahar before and after, and on hardware.

### W8. Small loose ends

- The `pica_safe_name` leak printed during `odin test tools/mbsc` (`pica.odin:167`).

---

## 5. Running agents side by side

| Workstream | Can start | Owns | Clashes with |
|---|---|---|---|
| W1 L5-4 | now | examples/model-check, plan | W2 (run W2 after) |
| W2 L7 | after W1 | examples/render-check, examples/vita-check | none |
| W3 L6 | now | light.odin, light_test.odin, plan | W4 |
| W4 point/spot | after W3 | light.odin, mbsc lighting, shaders, render files | W3, W6, W7 |
| W6 allocator | now | tools/mbsc/pica*.odin, *.3ds.v.pica | W4 |
| W7 C3D_FVec | now | O3DX types.odin (own branch and PR), matchbox/o3dx, 3DS render file | W4 |
| W8 leak | now | tools/mbsc/pica.odin | W6 (fold into W6) |
| W5 back faces | last | 3DS render, mbsc .tev lighting | all |

- Each agent works in its own git worktree and branch off `full-rewrite`. The plan file is shared: each agent adds
  only its own entry, so merges are additions.
- Generated shader files (`matchbox/shaders/*`) are regenerated, never hand-edited; two branches regenerating them
  conflict.
- One emulator run at a time per machine: close Azahar / Vita3K when done.

---

## 6. How to build, check and measure

**Checks** (repository root; `.bat` files run from PowerShell only, as `cmd /c ".\3ds_check.bat
examples\model-check"`):

```
odin check matchbox -no-entry-point
odin test matchbox
odin test tools/mbsc
odin build tools/mbsc -out:tools/mbsc/mbsc.exe
cmd /c ".\3ds_check.bat examples\model-check"      (also examples\handheld-boot, and no argument)
cmd /c ".\vita_check.bat examples\model-check"     (also examples\vita-check, examples\handheld-boot, none)
```

**Generating a shader** after editing an `.mbs` (or mbsc), for `<name>` in `mesh`, `mesh_lit`, `mesh_vertex_lit`:

```
mbsc matchbox/shaders/<name>.mbs -target:pc --emit-hlsl -o:matchbox/shaders/<name>.pc.hlsl
mbsc matchbox/shaders/<name>.mbs -target:pc --emit-reflection -o:matchbox/shaders/<name>.pc.refl
mbsc matchbox/shaders/<name>.mbs -target:vita --emit-cg -o:matchbox/shaders/<name>
mbsc matchbox/shaders/<name>.mbs -target:vita --emit-reflection -o:matchbox/shaders/<name>.vita.refl
mbsc matchbox/shaders/<name>.mbs -target:3ds --emit-pica -o:matchbox/shaders/<name>.3ds
../vito/tools/psp2cgc.exe -profile sce_vp_psp2 -W4 -nocolor -o matchbox/shaders/<name>_v.gxp matchbox/shaders/<name>_v.cg
../vito/tools/psp2cgc.exe -profile sce_fp_psp2 -W4 -nocolor -o matchbox/shaders/<name>_f.gxp matchbox/shaders/<name>_f.cg
```

psp2cgc doesn't reproduce a `.gxp` byte for byte: rebuild one only when its Cg's program changed.

**Building:** `cmd /c ".\3ds_build.bat examples\<x>"` writes `app.3dsx`; `cmd /c ".\vita_build.bat examples\<x>"`
writes `<TARGET>.vpk`. The 3DS build needs the untracked `tools/*.exe` (tritex, mp3towav, modelpack) and
`assets/models/test_crate.glb` (git-ignored; `python tools/make_test_model.py` writes it). In a fresh worktree, copy
both in, and convert the `.bat` files to CRLF (the worktree checks them out LF, which cmd can't run).

**Emulators:**
- Azahar: `Start-Process "C:\Program Files\Azahar\azahar.exe" -ArgumentList "<path>.3dsx"`. The 3DS's A is the `A`
  key, B is `S`; hold ~0.3 s. Prints show on the bottom screen.
- Vita3K: install with `Vita3K.exe -i "<path>.vpk"` (stop it after ~15 s), run with `Vita3K.exe -r <TITLE_ID>`.
  Dismiss its "update available" notice with OK. Cross is `X`.
- Screens are read with the computer-use screenshot and zoom tools.

**Measuring:**
- PC: `powershell -NoProfile -File tools/capture_window.ps1 -exe build/<x>.exe -out shot.png [-keys l]`, then
  read pixels with Python/PIL. **The PC framebuffer is sRGB**; the handhelds are linear.
- Emulators: zoom into the screen and read the saved JPEG; **take a median over an area**, as a scaled JPEG rings at
  sharp edges.
- Reference values (one sun from (1, 2, 1), 0.2 ambient, model-check's scene): cube front and right linear
  (61, 93, 155) / PC (135, 163, 205); cube top (102, 153, 255) / (170, 203, 255); floor (102, 102, 115) /
  (170, 170, 180); board white squares 155 / 206; sphere peak red per pixel 229 (PC, linear), 228 (Azahar), 230
  (Vita3K).

---

## 7. Traps found in G2

- `render_model(m, {x, y, z})` doesn't compile, on purpose (an untyped `{x, y, z}` also fits a `Transform`): write
  `[3]f32{x, y, z}`.
- The 3DS programs share citro3d's uniform registers; the runtime sets the camera's uniforms (and the per-vertex
  lights) again after every program switch (`use_render_pipeline` / `set_camera_uniforms`). Anything new a program
  reads from a register must be set there too.
- The 3DS vertex unit has 16 temporaries and 512 instructions; it passes one interpolated colour to the TexEnv
  stages, which is why per-vertex folds the highlight in before the texture.
- Real hardware rejects what Azahar accepts: a change to what the PICA is asked to do gets a hardware spike first.
- A highlight's alpha must stay 0, or cut-outs lose their holes.
- Shell heredocs mangle `\\n` in Python run from bash: write such scripts to a file and run the file.
- `FACE_DOWN` and the like are positions: B on the 3DS, Cross on the Vita, A on a PC pad.

---

## 8. After G2

Normal and bump maps, environment mapping, procedural textures and fog, each with its own steps and a hardware spike;
the plan's "What the same unit opens" has the notes. Stereoscopic 3D is deferred. The cheatsheet (D1) and
target-specific light limits (D8) once the API is stable.

**G2 is complete (2026-11-25).** W1 to W7 are done and W5 closed with no change. Deferred:
- Flip the normal for back faces on all three targets (`mesh_lit.mbs`; hardware `light_test5` S7 to S10 support it; changes what
  PC and the Vita draw, not the API).
- The cheatsheet (D1), once the API has stabilised.
- Target-specific light limits (D8).
- The Vita's per-pixel lighting with the two bulbs on: closed at about 36 fps (30 fps is the Vita's target for per-pixel lit 3D; per vertex is faster but looks different). See "L8-7 closed" in `docs/3ds_fragment_lighting_plan.md`.
- Normal and bump maps, environment mapping, procedural textures and fog (the plan's "What the same unit opens"); stereoscopic 3D.
- Lit billboards (added 2026-11-25, from G4): a lit quad mesh with its normal toward the camera, per target, so `render_billboard` can be shaded by the lights. G4 draws billboards unlit (the shared sprite quad); see `docs/g4_billboards_plan.md`.
