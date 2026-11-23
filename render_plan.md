# Matchbox: 3D-first rendering plan

Status: proposed 2026-11-12, branch `full-rewrite`. Updated 2026-11-12 with
the A1 results (3DS float maths) and Phase H (hard-float, later). Updated
2026-11-14 for commits 763b3a3 and a0d559f: `matchbox/vito` added, build
scripts renamed to `3ds_*.bat` / `vita_*.bat`, and the o3dx runtime and libm
rename (new step A0; revised "3DS float rules"; shorter Phase H and I).
Updated 2026-11-14 (later): **the Vita is now a core target.** Targets are PC
(D3D11), 3DS (citro3d) and Vita (GXM, through `matchbox/vito`). The Vita's
specifics are settled up front (section "The three targets", step A0b, and the
new Phase V), and every later step is "done" only when it works on all three.
The old Phase H (Vita, late) is gone; the hard-float phase is now Phase H.
Updated 2026-11-18: D1 to D3, E1 to E7 (PC), F1 to F4 are done on PC. The handheld
halves of D4, E7 and F1 wait for the handheld phases (A0/A0b, C, V).
Updated 2026-11-21: Phase S steps S0 to S7 are done. S4 (Vita Cg), S5 (3DS vertex) and S6 (3DS TexEnv plan) were checked on
emulators only (Vita3K, Azahar) and still need real hardware; no runtime reads the `.tev` plan yet. S8 is split into S8a
(`.shbin`) and S8b (`.gxp`). A reference for the next session is `docs/next_session_handoff.md`.
Updated 2026-11-21 (later): A0b is rewritten. Its `#config` catch was tested and works, it adds a backend contract so shared files are
written once, and its steps are T0 to T4. Claude writes the handheld backends, and the user reviews and approves every file before it changes. Audio is stubbed on all three targets.
Updated 2026-11-21 (end of day): **A0b T0-T4 done.**
- `examples/handheld-boot` boots in Citra and Vita3K.
- The demo builds unchanged on all three targets.
- The checks to run are in `docs/next_session_handoff.md`, "Check everything".
- Phases C and V start from here.
Updated 2026-11-22: **Phase C, C0 to C4 done, checked in Azahar only.**
- The 3DS draws the shared render queue with the mbsc-generated shader and `.tev` plan.
- `examples/render-check` reads the framebuffer back, and all ten probes pass.
- C5 waits on B8, and C6 is optional. The Phase C gate (the cube scene, real hardware) is not met yet; see "Phase C: status".
- **Citra's 2024 nightly is not used for 3DS checks any more.** It hangs on `C3D_DrawElements` and ignores vertex
  uniforms, where Azahar draws the same build correctly. Azahar replaces it wherever this plan says Citra.
Updated 2026-11-22 (later): **Phase D on the 3DS done (D1, D2, D4), checked in Azahar only.** See "Phase D: status".
The user also settled the other handheld gaps:
- **Text (F2):** each target uses its own native text: stb on PC, the system font on the 3DS, and the Vita's font system.
  A shared font framework may come later.
- **The 3DS bottom screen:** `print` output becomes text drawn on the bottom screen, in place of the ctru console.
- **Touch** gets implemented. Done on the 3DS: the stylus is the mouse (see F3).
- **Audio** stays stubbed. The user writes it.
- **The handheld halves of E and F** get implemented.
- **The small loose ends** wait for a tidy-up at the end.
Updated 2026-11-22 (later still): **F2 on the 3DS done: text uses the console's system font**, checked in Azahar only.
See "F2: status (3DS)".
Updated 2026-11-22 (later still): **the 3DS bottom screen draws** (its own render target), and `print` is drawn on it in
place of the ctru console. Checked in Azahar only. See "Bottom screen: status (3DS)" in Phase F.

## The decision

Everything Matchbox draws is 3D. A 2D game is a 3D scene seen through an
**orthographic** camera, and a 3D game uses a **perspective** camera. Sprites
are textured quads at a depth, and the HUD is drawn by a second orthographic
camera for screen space.

**Rejected alternatives:**
- A separate 2D renderer in pixels, as main has. Resolution and aspect ratio
  get solved twice, and 2D and 3D share nothing.
- Pixels with a CPU `to_pixels` transform. It works, but a 3D renderer would
  still have to come later and redo everything.

**Correction to the original idea:** 2D is a projection change, *not* a
perspective camera locked to an axis. A locked perspective camera is 2.5D:
size changes with depth. That is still available as a mode, since it gives
free parallax.

## What carries over unchanged

- Input, audio, events, logger, the asset lookup (`get_asset`) and the build
  scripts. `3ds_build.bat` gains a shader step in Phase C, and the empty
  `vita_build.bat` / `vita_check.bat` are filled in at A0b and V0.
- Everything decided for resolution independence:
  - Units, not pixels.
  - One axis fixed, plus a fit policy: letterbox, overscan (with a cap),
    expand, and an integer option.
  - The visible rect plus `calculate_anchor_position` for the HUD.
  - Sprite size from pixels-per-unit (PPU) metadata.
  - Frames by index, not by pixel rect.
  - The shia-test minimum feature set for animation.
- The 3DS lessons:
  - Textures must stay at a stable address while a draw is pending.
  - Vertex buffers need a write cursor, because draws run at `FrameEnd`.
  - Float *parameters* of calls into citro3d / citro2d / libctru go through
    `uint32_t` bridges. Odin's own libm calls do not (see below).
  - The framebuffer is portrait, so x and y swap.

## 3DS float rules (updated 2026-11-14)

Odin calls C with the soft-float convention (floats in `r` registers), while
devkitARM's libraries are hard-float (floats in `s` registers). A mismatched
call links fine and returns garbage. There are now two separate cases.

**1. Calls Odin itself emits (libm and libgcc helpers): handled at link time.**
`3ds_build.bat` runs `objcopy --redefine-syms` with `o3dx/libm/redefine.syms`
on the Odin object, which renames every libm call (`sinf`, `fmaf`, `__fixdfdi`,
...) to a wrapper in `o3dx/libm/bridge.c` that fixes the registers. So
`core:math`, `core:math/linalg`, matrix `*` and `core:fmt` float printing are
**correct** on the 3DS. A libm function that has no wrapper fails the link with
`undefined reference to o3dx_<name>`, so it can't misbehave silently.
- This depends on that `objcopy` step and on `-microarch:mpcore` (FPU on). If
  either is dropped, the same code returns garbage without an error.
- **Speed is the remaining problem.** Odin's matrix `*` lowers to 64 `fmaf`
  calls per 4x4 multiply. VFPv2 has no fused multiply-add, and each call goes
  through two wrapper layers. Use the hand-written `mat4_mul`, `mat4_mul_vec4`
  and `quat_mul` from A1 for anything per-draw or per-vertex; use `linalg`
  freely for one-off work (building a camera, an inverse, a projection).
- Plain arithmetic, comparisons, `min`/`max` and `math.sqrt` compile to VFP
  instructions (no call at all).

**2. Calls into C libraries that take floats (citro3d, citro2d, libctru):
still need bridges.** Odin passes the float in `r0`; the library reads `s0`.
The o3dx bindings declare these as `u32` and bridge them in each `bridge.c`.
New bindings need the same.

**Check after a 3DS build:** the link succeeds, and
`arm-none-eabi-nm -u build\<odin object>.o` lists only `o3dx_*` for float
maths (a bare `sinf`, `fmaf` or `__*sf3` there means the rename step didn't run).

## 3DS runtime (o3dx), new 2026-11-14

`matchbox/o3dx/o3dx` supplies what `freestanding_arm32` lacks: a heap
allocator on newlib `malloc`, a per-frame temp arena (1 MB, grows by blocks), a
logger, an assertion handler that prints and logs to `sdmc:/o3dx_panic.log`,
and `print` helpers. With it, `new`, `make`, `append`, `map`, `delete`,
`strings.*`, `fmt.tprintf`, `slice.sort_by` and `core:log` work on the 3DS.
**Without it they silently do nothing** (the default allocator is the nil
allocator), and a failed `assert` traps with no message.

**It is not switched on yet.** Nothing in Matchbox imports it:
`3ds_entry_point_freestanding_arm32.odin` still uses
`runtime.default_context()`. See step A0.

What this changes in the plan:
- **Shared code can use `[dynamic]`, slices and maps.** The render queue (B7,
  C4), mesh generators (B6), sheet and `.meta` parsing (D2), and the animation
  clip tables (E6) are written once, in shared files, with no fixed-size arrays
  or 3DS-only variants.
- **Per-frame data goes in `context.temp_allocator`,** freed once per frame with
  `free_all(context.temp_allocator)`. Matchbox does it at the start or end of the
  frame, so games don't have to.
- **Long-lived data (textures, meshes, sheets)** uses the heap, and GPU data
  still uses linear memory (`linearAlloc`). The heap and the linear heap split
  the application's memory (`__ctru_heap_size`, `__ctru_linear_heap_size` in
  `main.c`), so watch both on a real console.
- **The two 3DS utility files can shrink.** `get_asset` and `print` in
  `util_3ds_*.odin` use fixed buffers because there was no allocator; they can
  match the PC versions (`strings.concatenate`, `fmt`).
- **Use `assert` freely** for invariants (matrix inverse, mesh index ranges,
  queue overflow). It now reports on the 3DS.
- Bounds-check and nil-dereference failures still trap with no message. They
  don't go through the assertion handler.

## The three targets (Vita specifics, settled 2026-11-14)

The Vita is built like the 3DS (arm32, freestanding, Odin assembly compiled by
a GCC from the vendor SDK) but its GPU is nothing like the 3DS's. This is what
differs, so every shared design choice below accounts for it.

| | PC | 3DS | Vita |
|---|---|---|---|
| Odin target | `windows_amd64` | `freestanding_arm32`, `-microarch:mpcore` | `freestanding_arm32`, `-microarch:cortex-a9` |
| Toolchain | `odin build` | devkitARM, `3ds_build.bat` | VitaSDK (`C:\vitasdk`), `vita_build.bat` |
| GPU API | D3D11 | citro3d (PICA200) | SceGxm (`vito/gfx`, `vito/sce/gxm.odin`) |
| Shaders | HLSL, compiled at runtime | PICA `.v.pica` (picasso) to `.shbin` | Cg `.cg` to `.gxp` (`psp2cgc`, `tools/build_shaders.py`) |
| Clip-space depth | 0..1 | citro3d's own helpers | -1..1 (OpenGL style) |
| Matrix in shader | `mul(M, v)` | PICA uniforms: 4 rows, tilt helper | Cg `mul(v, M)`, Odin matrix passed as-is |
| Screens | 1 window, any size | 400x240 top plus 320x240 bottom | 960x544, fixed |
| GPU memory | D3D owns it | `linearAlloc` | `gfx.alloc` only (CDRAM / mapped) |
| Float calls to C | no issue | `u32` bridges plus libm rename | `u32` bridges (`vito/sce/bridge.c`) plus libm rename (`vito/libm`) |
| Runtime | normal | `o3dx.init()` | `vito.init()` (same shape) |
| Touch | mouse | bottom screen, 320x240 | front panel (and rear), own coordinate range |
| Assets | `assets/` | romfs `.t3x` | `assets/` packed into the `.vpk` as `app0:/assets/` |

Shared code assumes none of the left-hand column. Each backend owns its
GPU memory, its shader, its projection depth and its input mapping.

**Vita rules that shape the shared design** (from `vito/gfx/gfx.odin`):
- **GPU memory:** anything the GPU reads (vertices, indices, textures) comes from
  `gfx.alloc`, never `new` / `make`. So the render queue's *CPU-side* arrays use
  the temp allocator, and only the final vertex upload goes to GPU memory.
- **No overwrite while in flight:** a frame can still be rendering while the CPU
  writes the next one. Dynamic quad buffers are a ring of 3 (one per display
  buffer), and nothing GPU-visible is freed without `gfx.finish()`. This is the
  same rule as the 3DS write cursor, in a different shape; write the quad
  batcher with a per-frame buffer index so both backends use it.
- **Depth is reset every scene,** so `gfx.clear` doesn't touch it, but it leaves
  depth test `LESS_EQUAL` with writes on and culling off. The backend sets its
  own state per draw (B5's table) and doesn't rely on defaults.
- **Fixed 960x544 surface** (`STRIDE` 960, 3 display buffers, optional 4x MSAA
  through `gfx.Config`). No resize event, so there is no "recreate on resize"
  step like B1; it is only a fit input.
- **Matrices:** the Cg vertex shader uses `mul(vector, matrix)` and the uniform
  is written with `gfx.set_uniform_matrix(buffer, param, &m)` using the same
  `matrix[4,4]f32` as PC. If something draws mirrored or at the origin, the
  multiplication order in the `.cg` file is the first suspect, not the matrix.
- **Shader toolchain** is proprietary-ish: `psp2cgc.exe` is not in the Matchbox
  repo (it lives in the separate `vito` repo's `tools/`). Commit the compiled
  `.gxp` files next to the `.cg` sources, as `vito/gfx/shaders/` does, and keep
  the compile step optional in `vita_build.bat`, so a clean checkout builds
  without the tool.

**Selecting the target's files** (tried 2026-11-14 on scratchpad packages; the open catch was tested
2026-11-21 with Odin dev-2026-11 e28f5d1ff; not yet used in Matchbox). The 3DS and Vita are both
`freestanding_arm32`, so the `_3ds_freestanding_arm32` suffix and `#+build freestanding arm32` match both.
What was tried:
- **`odin build -file`: does not work.** `-file` builds one file as its own package, and several files are
  rejected ("takes a package/directory").
- **A microarch build tag (`#+build mpcore`): does not exist.** Odin's tags are OS and architecture only.
- **`when ODIN_MICROARCH_STRING == "cortex-a9"`: works for `odin build`,** but `odin check` has no `-microarch`
  flag (still true 2026-11-21) and always sees the default (`arm1176jzf-s`), so the Vita check couldn't check
  Vita code.
- **`#config` with `-define:MATCHBOX_VITA=true`: works for both `check` and `build`. This is the chosen
  mechanism.**
  - `VITA :: #config(MATCHBOX_VITA, false)` goes once in a shared file.
  - `when !VITA { ... }` wraps the contents of each 3DS file, and `when VITA { ... }` each Vita file.
  - `vita_build.bat` and `vita_check.bat` pass `-define:MATCHBOX_VITA=true`.
- **The catch, tested 2026-11-21: it is not a problem.** `import` is a syntax error inside `when`, so each target
  file imports its packages at the top, unconditionally. A scratch package was built the way Matchbox would be:
  one file importing the real `o3dx/o3dx` and `o3dx/c3d`, one importing `vito/vito` and `vito/gfx`, and both
  defining the same procedures inside `when`.
  - Both checks pass, with and without the define.
  - Both `-build-mode:asm` builds pass:
    - the 3DS: `.cpu mpcore`, `.fpu vfpv2`
    - the Vita: `.cpu cortex-a9`, `.fpu neon-fp16`
  - **Nothing of the unused console reaches the assembly.**
    - The 3DS `.S` has no `vito` or `sce*` symbol, and the Vita `.S` has no `o3dx`.
    - Odin emits only what is reached. An `@(init)` proc or an initialised global *would* be emitted, and
      neither `o3dx` nor `vito` has one; keep it that way, or wrap them in `when`.
    - `foreign import`s don't matter, because asm mode doesn't link and the `.bat` chooses the libraries.
  - **Not tested yet:** linking with the real toolchains, booting either console, and the full Matchbox
    package. Steps T2 and T3 of A0b cover these.
- **A script that forgets the define** would compile 3DS code for the Vita's CPU and fail at the link, far from
  the cause. Two asserts in the shared file catch it. Tested: `-microarch:cortex-a9` without the define stops
  with the message, and both checks still pass, because `check` sees the default microarch, which is neither.

  ```odin
  #assert(!(VITA && ODIN_MICROARCH_STRING == "mpcore"), "Vita build with the 3DS microarch")
  #assert(!(!VITA && ODIN_MICROARCH_STRING == "cortex-a9"), "3DS build with the Vita microarch: pass -define:MATCHBOX_VITA=true")
  ```
- **Rejected: one package per backend, chosen with `-collection:backend=...`.** That selects imports cleanly, but
  a backend in its own package can't reach `mbi` or the render queue unless they are made public.
- **Longer term:** Farlite's patched Odin (Phase H) could add `3ds` and `vita` subtargets, and the `when` blocks
  then become `#+build` lines. `-subtarget` already exists for `freestanding_arm32`, with `playdate` as its only
  value.

**File layout:** a module with per-target code gets one file per target:
`window_windows.odin`, `window_3ds_freestanding_arm32.odin` (wrapped in
`when !VITA`) and `window_vita_freestanding_arm32.odin` (wrapped in `when
VITA`). The `_vita_` part isn't a known OS name, so Odin treats it as an
ordinary name and the arch suffix still selects arm32. Shared files stay
unsuffixed.

---

## Conventions (decide before Phase A ends)

These shape every matrix written afterwards, so settle them once and write
them at the top of the shared math file.

| Item | Recommendation | Why |
|---|---|---|
| Handedness and up | Right-handed, **+Y up**, camera looks down **-Z** | Matches glTF, which main already loads, and most 3D tutorials. |
| 2D y direction | Also +Y up | One world, one rule. Unity, Bevy and Godot 3D do this. 2D code written y-down needs flipping (demo, shia-test). |
| Angles | Radians | Already the case in `render_sprite`. |
| Matrix layout | Store as Odin `matrix[4,4]f32` (column-major, column vectors). Use `mat4_mul` / `mat4_mul_vec4` for per-draw and per-vertex work | Odin's native layout, uploadable as-is. The `*` operator is correct on the 3DS now but slow (see 3DS float rules). Watch HLSL packing in B4. |
| Depth range | Per backend | D3D uses 0..1. citro3d's own helpers build its range. The Vita's GXM clip space is OpenGL's, -1..1 (per `vito/gfx/gfx.odin`), so A1 also has `mat4_perspective_gl` and `mat4_ortho_gl`. Shared code describes the camera, and each backend builds the projection matrix. |
| Screen and pixel units | Fit works on any surface size | PC: any size. 3DS: 400x240. Vita: 960x544 (aspect 1.765). All three are inputs to A4. | Don't hard-code 400x240; the design aspect should be chosen with all three screens in mind (16:9 designs letterbox slightly on both handhelds). |
| Units | 3D: 1 unit = 1 metre. 2D: the game picks its ortho view height. With PPU 1, one unit is one art pixel at 1x. | Keeps 2D numbers familiar. |
| Sprite pivot | `{0.5, 0.5}` = centre is the position | Opposite of main. Main's comment calls its own convention surprising. |

## Milestones (replaces README "Milestones")

```
[x] POC
[-] Renderer core: 3D pipeline on PC, 3DS, Vita    (Phases A, B, C, V)
[ ] 2D: 2D as an orthographic projection           (Phases D, E, F; all three targets)
[ ] 3D: 3D games                                   (Phase G; all three targets)
[ ] Shader language: one source, three targets     (Phase S; PC first, handheld backends with C and V)
[ ] Improved build system                          (shader steps land in Phases C, V and S)
[ ] Hard-float on the handhelds (performance)      (Phase H, via Farlite, late)
```

2D can't come first, because it is built on the 3D pipeline. The 2D milestone
still comes before 3D games, because it needs only the core, not lighting,
models or skinning.

## How to work through it

- **PC first, then the same step on the 3DS and the Vita before moving on.**
  Don't let either handheld fall more than one step behind; the bugs found so
  far all came from differences between the targets. Phases B, C and V are
  one core phase done three times: each B step has a C step and a V step, and
  they're listed together in the table at the start of Phase B.
- **Hammer out each target's specifics at the step that first touches them,**
  not later. That is why the Vita's build, entry point and depth rules are in
  Phase A, before any rendering.
- **No legacy 2D path is kept (decided 2026-11-14).** The old pixel-space 2D
  renderer is deleted from a target at the start of that target's core phase
  (B0 for PC, C0 for the 3DS, V0 for the Vita), not after its replacement
  works. Until the new path draws, the demo only opens a window and clears.
  There is no depth-off state, `viewport_size` constant or old sprite batch
  left to keep alive. The removal checklist at the end lists what goes.
- **Pure maths in shared files, with tests.**
  - Files have no target suffix, and `odin test` runs on PC.
  - Main's `display_test.odin` is the model.
- **Every step has a "done when".** Don't start the next step until it is met
  on all three targets (Azahar for the 3DS, Vita3K or real hardware for the
  Vita; real hardware at the end of each phase). If the Vita emulator isn't
  trusted for GXM details, treat a step as done on the Vita only after a
  hardware run.

---

## Phase A: shared foundations (no rendering changes)

**A0. Turn the 3DS runtime on** (new 2026-11-14; do this before anything
else, since later steps assume `make` and `append` work).
- In `3ds_entry_point_freestanding_arm32.odin`, replace
  `context = runtime.default_context()` with the o3dx context:
  ```odin
  package demo

  import o3dx "matchbox/o3dx/o3dx"

  @(export, link_name = "odin_main")
  odin_main :: proc "c" (argc: i32, argv: [^]cstring) -> i32 {
  	context = o3dx.init()
  	defer o3dx.shutdown()
  	main()
  	return 0
  }
  ```
- Free the temp arena once per frame inside Matchbox (for example at the
  start of `poll_events`): `free_all(context.temp_allocator)`.
- Check that `3ds_build.bat` still compiles `o3dx/libm/bridge.c` and runs the
  `objcopy` rename (it does as of commit a0d559f). `core:fmt` now pulls in
  libgcc float helpers, and those need the rename.
- Verified statically 2026-11-14 (scratchpad copy of `3ds_build.bat` with this
  entry point; no emulator was run): it builds and links, the Odin object
  calls only `o3dx_*` for `sinf`, `cosf`, `powf`, `expf`, `fmaf` and the
  integer/float conversion helpers (no bare libm symbol left), and
  `o3dx::init`, `heap_allocator_proc`, `assertion_failure_proc` and `logger_proc`
  are in the ELF.
- **Vita counterpart (same step, written in A0b):** `vito.init()` /
  `vito.shutdown()` in the Vita entry point, and `free_all(context.temp_allocator)`
  in the Vita `poll_events`. `vito` has the identical shape to `o3dx`, so
  nothing else differs.
- Done when: on Citra, a one-off `s := fmt.tprintf("%v", 1.5)` followed by
  `mb.print(s)` shows `1.5`, a `make([]int, 4)` returns a non-empty slice, and
  a deliberately failed `assert(false, "test")` prints its message.

**A0b. Target selection, the backend contract, and the Vita scripts** (new 2026-11-14; rewritten
2026-11-21 after testing the mechanism). Right after A0 and before any C or V step, because it fixes the file
layout everything after it uses. The mechanism, and how it was tested, is in "The three targets".

**Who does it:** Claude writes the handheld backends (T2, T3), and the user reviews every file before it
changes (decided 2026-11-21, replacing the user typing it in from walkthroughs). Each file is shown in full, or as
exact changes, with the reasons. It is applied only once approved. The user still wants to learn the bindings,
so the review is the walkthrough.
Claude may run Azahar and Vita3K to check work it is asked to do; the user checks on the New 3DS LL and the Vita.

**Audio** is stubbed on all three targets until the rendering pipeline is done. `audio_windows.odin` and
`audio_3ds_freestanding_arm32.odin` already are (`Audio` is empty; `load_audio`, `play_audio` and
`destroy_audio` do nothing), and the Vita gets the same three empty procs. Games keep their audio calls and
compile everywhere.

**Why this step is bigger than choosing files.** Choosing files is solved. What blocks the handhelds is that
most of Matchbox is Windows-only today without needing to be (measured 2026-11-21):
- `sprite`, `animation`, `collision`, `shapes`, `text` and `font` contain no Windows code. They are
  `#+build windows` only because what they call (`queue_render`, `Texture`, `Render_Item`, `Mesh`) exists only
  in the D3D11 files. The handhelds would get none of them, or a third copy of each.
- `Matchbox_Info` is declared twice, once in `window_windows.odin` and once in
  `window_3ds_freestanding_arm32.odin`, and the two have drifted. The Vita would make three.
- Untagged test files (`bottom_screen_test.odin`, `texture_meta_test.odin`) pull `core:testing`, and through it
  `core:os` and `core:thread`, into the freestanding build. They cause about 200 of the 3DS check's errors.
  The rest are `demo.odin` (69), `shared.odin` (10, parallax uses `Sprite`) and `camera.odin` (1).
- The 3DS backend files (586 lines) are the old pixel-space 2D path, which "no legacy 2D path" deletes.

So A0b gives Matchbox a **backend contract**: shared types and procedures that each target fills in, so shared
files are written once.

**Layout:**

```
matchbox/
  target.odin                           VITA and the microarch asserts
  matchbox_info.odin                    Matchbox_Info (shared), with `backend:Backend_State`
  sprite.odin animation.odin ...        shared (no tag), calling only the contract
  backend_windows.odin                  Backend_State (D3D11), the contract on PC
  backend_3ds_freestanding_arm32.odin   when !VITA { Backend_State (citro3d), the contract }
  backend_vita_freestanding_arm32.odin  when  VITA { Backend_State (GXM), the contract }
  window_*, input_*, events_*, ...      per target as now; handheld ones wrapped in `when`
  *_test.odin                           #+build windows (tests run on PC)
```

**The contract:** the procedures shared code may call. Every backend defines them with the same signature:
- `queue_render`, executed at `camera_end`
- `Texture`, `load_texture`, `Mesh` and its create and destroy procs
- `init`, `poll_events`, `get_window_size`, timing, input queries
- `print`, the logger
- audio stubs

A backend that misses one fails its own check script, because a shared file calls it.

**Entry point:** `matchbox/handheld_entry`, one package for both consoles. Matchbox's own package can't hold it
(see decision 2 under "Decisions to make"), so it is a package of its own that imports the game:

```odin
package matchbox_handheld_entry

import game "matchbox_game:." // the scripts point this collection at the game's folder
import mb ".."

@(export, link_name = "odin_main")
odin_main :: proc "c" (argc: i32, argv: [^]cstring) -> i32 {
	context = mb.start_runtime() // o3dx.init() on the 3DS, vito.init() on the Vita
	game.main()
	mb.stop_runtime()
	return 0
}
```

The build and check scripts build this package with `-collection:matchbox_game=<the game's folder>`. Changed
2026-11-22: each game used to carry this as `entry_freestanding_arm32.odin` in its own package. A copy of that file
named the package it came from, so a game in any other package failed with "Different package name, expected
'demo'". Now a game has no entry file, and its package can have any name.

**T0. Tests and stray files off the handhelds.**
- Tag every `*_test.odin` with `#+build windows`.
- Tag `shared.odin` (parallax) with `#+build windows` until `Sprite` is shared, in T1.
- Done when: `odin check matchbox -target:freestanding_arm32 -no-entry-point -no-thread-local` reports nothing
  from `core:os`, `core:testing` or `core:thread`.

**T1. The contract on PC.**
- Add `target.odin`.
- Split `Matchbox_Info` into the shared struct plus `Backend_State`, and move the D3D11 and Win32 fields into
  `backend_windows.odin`.
- Untag `sprite`, `animation`, `collision`, `shapes`, `text`, `font` and `shared`.
- PC only.
- Done when:
  - PC behaves exactly as before: `odin test matchbox` passes, and shia-test, the demo and RunTeddyRun run unchanged.
  - The contract list is written at the top of `matchbox_info.odin`.

**T2. 3DS boots on the contract.**
- Delete the old 3DS render code. Update window, input, events, logger and util to the shared `Matchbox_Info`.
- Wrap every 3DS file in `when !VITA`.
- The drawing procs are empty, except `clear_background`.
- `start_runtime` calls `o3dx.init()`.
- The temp arena is freed once a frame.
- Done when:
  - `3ds_check.bat examples\handheld-boot` passes. Both scripts take the game's folder, and with none they use
    the root as before.
  - `3ds_build.bat examples\handheld-boot` gives a `.3dsx` that boots in Azahar or Citra, clears to a colour,
    and prints through `mb.print`.
  - The demo compiling on the 3DS stays with T4. It needs the HUD, the bottom screen and text, which the boot
    example doesn't (decided 2026-11-21).
  - A0's own check passes: `fmt.tprintf`, `make`, and a failed `assert` that shows its message.

**T3. Vita boots on the contract.**
- `vita_check.bat`: the same as `3ds_check.bat` plus `-define:MATCHBOX_VITA=true`.
- `vita_build.bat`, based on `vito/NewProjectTemplate/build.bat` (the separate `vito` repo):
  - Takes the game's folder like the 3DS scripts (`vita_build.bat examples\handheld-boot`), defaulting to the root.
  - `odin build %SRC% -target:freestanding_arm32 -o:speed -build-mode:asm -no-entry-point -min-link-libs
    -no-thread-local -microarch:cortex-a9 -define:MATCHBOX_VITA=true`
  - Assemble each `.S` with `arm-vita-eabi-gcc -march=armv7-a -mtune=cortex-a9 -mfpu=neon -mfloat-abi=hard`.
  - Then run `arm-vita-eabi-objcopy --remove-section .ARM.attributes --redefine-syms=matchbox\vito\libm\redefine.syms`
    on each object. The Vita *removes* the ABI attributes so `ld` accepts the soft-float objects; the 3DS appends
    `.eabi_attribute 28, 1` instead.
  - Compile the root `main.c`, the same one `3ds_build.bat` uses. It's plain C with nothing console-specific, so
    no `vita/main.c` was needed. Plus `matchbox\vito\libm\bridge.c` and `matchbox\vito\sce\bridge.c` (`-O2`).
  - Link:
    - flags: `-Wl,-q -Wl,--defsym,__sce_headroom=0x10000`
    - stubs: `SceDisplay`, `SceGxm`, `SceSysmodule`, `SceCtrl`, `SceTouch`, `SceMotion`,
      `SceKernelThreadMgr`, `SceIofilemgr`, `SceAudio`, `ScePgf`, `ScePvf`, `SceCommonDialog`, `SceAppMgr`,
      `SceAppUtil`, `ScePower`, `SceSysmem`, `SceLibKernel`
    - libraries: `-lpng16 -lz -lm`
  - Package:
    - `vita-elf-create`, then `vita-make-fself -c`
    - `vita-mksfoex`, which needs a 9-character `TITLE_ID`: 4 letters and 5 digits
    - `vita-pack-vpk`, with the assets staged like `3ds_build.bat` does (`assets\` plus `assets\vita\`) and
      packed as `app0:/assets`. `TITLE_ID` is `MBOX00001`.
  - VitaSDK is at `C:\vitasdk`. `arm-vita-eabi-gcc`, `nm` and `objcopy`, `vita-elf-create`, `vita-make-fself`,
    `vita-mksfoex` and `vita-pack-vpk` were all found there on 2026-11-21.
- The backend files are in `when VITA`:
  - `start_runtime` calls `vito.init()`.
  - `gfx.init()`, then `begin_frame` / `clear` / `end_frame` / `swap`. This is V0's clear.
  - Input is mapped from `vito/vito/input.odin`.
  - Audio is stubbed.
- The keyboard and mouse stubs (neither handheld has a keyboard or a mouse) and the audio stubs are one file
  each, used by both handhelds, with no `when`: `input_handheld_freestanding_arm32.odin` and
  `audio_handheld_freestanding_arm32.odin`. A single copy can't drift from a second one. Audio splits back per
  target once it's written.
- Done when:
  - `vita_check.bat examples\handheld-boot` passes.
  - `vita_build.bat examples\handheld-boot` gives a `.vpk` that boots in Vita3K, clears, and prints.
  - `arm-vita-eabi-nm -u` on the Odin object shows only `vito_*` for float maths.
  - `3ds_check.bat` and `3ds_build.bat` still pass on the same example.

**T4. All three green from one tree.**
- From a clean checkout, these pass:
  - the PC check and the shia-test build
  - both 3DS scripts
  - both Vita scripts
- One example builds for all three unchanged, drawing nothing yet on the handhelds.
- Done when: all of that passes, and the list is written into `docs/next_session_handoff.md` as "check everything".
- **Done 2026-11-21.** The example is the demo, which builds on all three.
  - The HUD (`screen.odin`) is shared.
  - The bottom screen is in two files: `bottom_screen_one_surface.odin` for the PC and the Vita, and
    `bottom_screen_3ds_freestanding_arm32.odin` for the 3DS.
  - The text code is shared, with only the atlas baking per target (see F2).
- On the handhelds the demo runs until its first sprite, then stops on `ensure("Sprite has no texture")`.
  Handheld `load_texture` gives no size until Phases C and V load images. A fake size would hide this, so the
  `ensure` stays.

Phases C and V then go row by row through the table at the start of Phase B:
- The Vita's shaders come from `mbsc --emit-cg`, which was written for this backend, compiled to the committed `.gxp`.
- The 3DS's come from `mbsc --emit-pica` and the `.tev` plan.

**A1. Shared maths file.** The FPU is done (`3ds_build.bat` uses
`-microarch:mpcore`) and libm calls are corrected at link time (see "3DS float
rules"). So the maths file no longer needs per-target trig; it is **one shared
file plus its tests**, already written and `odin check`-clean on PC and on the
3DS target (scratchpad copy; not yet run).
- [x] The `c3d.sinf`, `cosf`, ... `u32` bridges (pushed 2026-11-12) still
  exist. They are redundant for Odin's own libm calls now. Keep them while
  nothing depends on them; remove them with Phase H if unused.
- **`matchbox/math.odin`** (shared): `Vec3`, `Vec4`, `Mat4`, a plain `Quat`
  struct, `sin`/`cos`/`tan`/`atan2`/`sincos` over `core:math`, `radians`,
  `degrees`, the `vec3_*` helpers, and `mat4_identity`, `mat4_mul`,
  `mat4_mul_vec4`, `mat4_mul_point`, `mat4_translate`, `mat4_scale`,
  `mat4_from_quat`, `mat4_inverse`, `mat4_perspective` and `mat4_ortho` (both
  depth 0..1), `mat4_look_at`, `quat_angle_axis`, `quat_mul`,
  `quat_normalize`, `quat_rotate_vec3`. The multiplies are written as plain
  loops, for speed on the 3DS (the Vita's Cortex-A9 has VFPv3 and NEON but no
  fused multiply-add either, so `fmaf` is a library call there too, and the same
  hand-written code is used).
- **Vita additions to the file:** `mat4_perspective_gl` and `mat4_ortho_gl`
  (depth -1..1) beside the 0..1 versions, with test cases against
  `linalg.matrix4_perspective_f32`. The same maths file is used for all three
  targets; the Vita's libm calls go through `vito/libm`'s rename, the same
  mechanism as the 3DS's.
- **`matchbox/math_test.odin`** (`#+build windows`, so `core:testing` stays out
  of the 3DS check): compares against `linalg` and checks the conventions.
  Run with `odin test matchbox`.
- Done when: the tests pass on PC; on Citra a print of `sin(PI/2)` and a
  rotated vector shows the right numbers (this now exercises the link-time
  rename); and `nm -u` on the Odin object shows only `o3dx_*` float symbols.
- Decided 2026-11-14: keep `Quat` as a plain struct (not `quaternion128`) and
  keep `mat4_mul` hand-written, for 3DS speed, not for correctness.

**A2. `Transform`** (shared): `position: [3]f32`, `rotation: quaternion128`,
`scale: [3]f32`, plus `transform_matrix(t) -> matrix[4,4]f32`, built with the
A1 procs (translate × rotate × scale).
- Use `Quat` and `quat_mul` from A1.
- Done when: tests cover identity, translate-only and rotate-then-translate
  order.

**A3. `Camera`** (shared, description only):
Names follow raylib where they fit (`Camera3D` becomes `Camera`; `BeginMode3D` /
`EndMode3D` become `camera_start` / `camera_end`, matching `render_start` /
`render_end`). Decided 2026-11-16.
- `Projection :: enum {PERSPECTIVE, ORTHOGRAPHIC}` and `projection`
- `position`, `target`, `up` (raylib style; a `rotation` form can be added for
  3D cameras in G3)
- `fov_y` in degrees (perspective), `view_height` in world units
  (orthographic), `near`, `far`
- `fit: Fit_Policy`, `integer_scale: bool`, `overscan_cap: f32` (added in B8)

Helpers: `calculate_camera_view_matrix(cam)`, `calculate_camera_projection_gl(cam, aspect)` (shared,
OpenGL clip space; each backend adapts the depth range) and
`camera_create_2d(view_height)`, which returns an ortho camera at z = +10
looking down -Z.

Public API: `camera_start(cam)` / `camera_end()`, called between `render_start`
and `render_end`. The game never builds a projection matrix or computes the
aspect; the backend does. Picking helpers come later: `world_to_screen`,
`get_mouse_ray(cam)`, `calculate_mouse_world_position(cam)` (F2) and `camera_update`
(G3).
- Done when: the view matrix moves the world opposite to the camera, which is
  covered by a test.

**A4. Fit maths** (shared). This is the earlier "View" idea, moved under the
camera.
- Input: surface size in pixels, design aspect and policy.
- Output: viewport rect in pixels, scissor rect, scale, and the visible rect in
  world units.
- Overscan cap: beyond the cap, letterbox the rest.
- Done when tests reproduce these mockup numbers:
  - letterbox 1080p: 4.5x with 60px bars
  - overscan 1080p: 400x225 visible
  - Vita expand: 423.5x240 visible
  - Vita (960x544, aspect 1.765) with a 16:9 design under letterbox: 960x540
    viewport, 2px bars; and under overscan, the cropped width or height
  - ultrawide with a 10% cap: partial bars

**A5. Projection description per backend:** `camera_projection_params(cam,
viewport)` returns what a backend needs (fov, aspect, near, far, or ortho
extents). Backends build the actual matrix:
- PC: D3D 0..1 depth (`mat4_perspective` / `mat4_ortho` from A1).
- 3DS: `Mtx_PerspTilt` / `Mtx_OrthoTilt`, which handle the rotated
  framebuffer. `o3dx/c3d/bridge.c` already bridges the projection functions;
  check the Odin declarations pass `u32` (see "3DS float rules", case 2).
- Vita: OpenGL-style -1..1 depth: `mat4_perspective_gl` / `mat4_ortho_gl` from
  A1. `gfx.set_viewport` maps clip space onto 960x544 (y up), so no flip is
  needed. Cg multiplies `mul(v, M)`; the matrix memory is the same as PC's.

---

## Phases B, C, V: the core, once per target

The core is one set of steps done three times. Every row is "done" only when
all three columns are:

| What | PC (B) | 3DS (C) | Vita (V) |
|---|---|---|---|
| Shader toolchain | (HLSL is in the source; Phase S replaces it) | C0 (Phase S: S5, S6) | V1 (Phase S: S4) |
| Depth buffer | B1 | C1 | V2 |
| Vertex format and layout | B2 | C0 | V3 |
| Constants / uniforms | B3 | C0 | V3 |
| Shader maths and matrix order | B4 | C0 | V3 |
| Pipeline state (cull, depth, blend) | B5 | C1, C2 | V4 |
| Textures | (D1) | C2 | V5 |
| Meshes | B6 | C3 | V6 |
| Render queue execution | B7 | C4 | V7 |
| Viewport and scissor (fit) | B8 | C5 | V8 |
| Phase gate | cube and quad | same scene | same scene |

Do PC, then 3DS, then Vita for each row, or PC and both handhelds in one
sitting if they share the work. The render queue's sorting and the mesh
generators are shared code: they're written once, in B, and the other two
backends only execute them.

## Phase B: PC 3D core (D3D11)

**B0. Rip out the old 2D path (PC).** Do this first.
- Delete `matchbox/sprite_windows.odin` and `matchbox/shapes.odin` (`Sprite`,
  `Batch`, `batch`, `Rectangle`, `Triangle`, `create_triangle`).
- In `render_windows.odin` delete `MAX_BATCH_VERTICIES`, the old `Vertex` and
  `Constants` (with `viewport_size`), `flush`, `render_triangle_points`,
  `render_triangle_shape`, `render_triangle`, `corner`, `render_sprite`, and the
  constant-buffer upload in `render_start`. Keep `render_start`,
  `render_end` (without the `flush()` call), `clear_background` and the resize
  handling.
- In `window_windows.odin` delete the vertex buffer creation (`batch.gpu_buffer`),
  the `batch.current_texture_view` line, the pixel-space input layout, the
  `Constants` constant buffer, and the fields `vertex_buffer`, `vertex_count`,
  `vertex_stride`, `vertex_offset`, `constant_buffer`.
- Delete the old `shaders/shaders.hlsl` and its two compile blocks; B4 brings the
  new shader.
- Remove the sprite and triangle code from `demo.odin`.
- Keep: window, events, input, audio, util and logger; the device, swapchain,
  render target; the sampler, blend state and 1x1 white texture (the 3D path
  uses them); the image-loading code, which becomes `Texture` in D1.
- Done when: the demo opens a window and clears to a colour, and nothing in
  `matchbox` mentions a sprite, batch, `viewport_size` or pixel-space vertex.

**B1. Depth buffer.**
- Add a `D32_FLOAT` depth texture and its depth-stencil view (DSV).
- Recreate it in the `did_resize` block, next to the render target view (RTV).
- Clear it in `render_start`.
- Bind it with `OMSetRenderTargets(1, &rtv, dsv)`.
- Done when: the debug layer is quiet across resizes.

**B2. New vertex format:** `position: [3]f32, uv: [2]f32, color: [4]f32`.
`normal: [3]f32` is added in G2 and can be reserved now. Update the input
layout.

**B3. Constant buffers.**
- Per frame: `view_projection`.
- Per draw: `model`, `tint`.
- Retire the `viewport_size` constant.

**B4. Shader:** `output.position = mul(view_projection, mul(model, float4(pos, 1)))`.
- HLSL cbuffers default to column-major packing. Odin matrices are also column
  major, so upload them as-is and use `mul(M, v)`.
- Verify with a test draw: a quad at x = +1 must move right.
- If it moves wrong, transpose once at upload, never in the shader.

**B5. Pipeline states.**
- Rasterizer:
  - cull back faces
  - `FrontCounterClockwise = true` (right-handed)
  - a second no-cull state for sprites and two-sided quads
- Depth-stencil:
  - opaque: test and write
  - transparent: test without writing
  - HUD: off
- Blend:
  - opaque: off
  - alpha: the existing blend state

**B6. Meshes.**
- `Mesh` holds a GPU vertex buffer and a 16-bit index buffer, plus counts.
- `create_mesh(vertices, indices)`, `destroy_mesh(mesh)`.
- Generators in shared code: `mesh_cube`, `mesh_plane`, `mesh_sphere`. They
  return vertex and index slices only, with no GPU work. With the 3DS runtime
  (A0) they can `make` the slices, taking the allocator as a parameter
  (default `context.allocator`); the caller frees them after `create_mesh`.

**B6.5. Camera** (added 2026-11-16, so the API names are settled before B7).
- Shared `camera.odin`: `Projection`, `Camera`, `calculate_camera_view_matrix`,
  `calculate_camera_projection_gl`, `camera_create_2d` (see A3).
- PC: `camera_start(cam)` builds `GL_TO_D3D_DEPTH * projection * view` from the
  window aspect and uploads it to the frame constants; `camera_end()` does
  nothing yet (B7 flushes the queue there).
- Remove the public `perspective_projection` and `set_view_projection`.
  `set_frame_constants` is private.
- Done when: the demo calls only `render_start`, `camera_start(camera)`, draws,
  `camera_end`, `render_end`, builds no matrices, and looks the same. An
  orthographic camera built with `camera_create_2d` shows the cube flat.

**B7. Render queue** (shared logic, backend execution). This replaces the
immediate batch. `camera_end` is where the draws queued since `camera_start`
are sorted and flushed, so a frame with several cameras (world then HUD) just
flushes once per camera. PC first, as it is written (2026-11-16): the queue
is two persistent `[dynamic]Render_Item` arrays in `mbi` (opaque and
transparent) that are `clear`ed each flush, not temp-arena arrays, and the
code lives in `render_windows.odin`. It moves to shared code at C4 once
`Mesh` exists on the 3DS. `render_mesh` takes `blend` and `cull`; the queue
derives the depth mode, and `set_render_state` is private.
- `render_mesh(mesh, transform, texture, tint)` and later `render_sprite(...)`
  push items, and `render_end` sorts and draws them:
  - **Opaque and cut-out:** sorted by texture, then mesh, to reduce state
    changes. Drawn first with depth write.
  - **Transparent:** sorted back to front by view-space depth, stable for
    equal depth. Drawn after, without depth write.
- Quads (sprites, shapes) are pre-transformed on the CPU into one dynamic
  vertex buffer per texture run, with `model = identity`.
- Meshes use their own buffers and the per-draw cbuffer.
- The queue is a `[dynamic]` of items built in `context.temp_allocator` and
  sorted with `slice.sort_by` (`odin check` accepts both on the 3DS target;
  not yet run there). It is shared code, so C4 is only the 3DS executor. The
  queue is freed with the temp arena each frame (A0).

**B8. Viewport and scissor from A4.** DEFERRED (2026-11-17): not a priority. The
default is "expand": the camera shows more or less world as the window changes
shape, with no bars. Come back only if a game needs letterbox, integer scale or
a width cap (likely with pixel art in Phase E). Not part of the Phase B gate.
- `RSSetViewports` and `RSSetScissorRects` from the fit result.
- Clear the full window to the bar colour first, then the content.

**Phase B done when:** a textured, spinning cube is drawn with a perspective
camera, plus a half-transparent quad passing through it. Resizing keeps the
aspect, and letterbox and expand both behave as in the mockups.

---

## Phase C: 3DS 3D core (citro3d)

**Phase C: status (2026-11-22).** C0 to C4 are done and checked in Azahar 2126.2; nothing has run on a real 3DS yet.
How the build differs from the steps below, which are kept as written:
- **C0.** The shader is generated rather than hand-written: `matchbox/shaders/mesh.3ds.v.pica` and `mesh.3ds.tev`
  are mbsc's output for `mesh.mbs`, committed like `mesh.pc.hlsl`. `3ds_build.bat` assembles the `.pica` with
  picasso into `romfs/shaders/mesh.shbin`. The uniforms are mbsc's names: `render_model`, `frame_view_projection`,
  `render_tint`, `render_uv_rectangle`. The old 2D path and `vshader.shbin` were already gone (A0b).
- **C1.** The projection is linalg's OpenGL one, followed by `GL_TO_PICA_DEPTH` (z' = 0.5z - 0.5w) and
  `TILT_TO_PANEL`. citro3d's default depth map makes near 1, so the test is GREATER and depth clears to 0.
- **C2.** The TexEnv stages and the alpha test come from the `.tev` file, read by the shared `shader_tev.odin` (with
  PC tests). Untextured draws bind an 8x8 white texture, because 8x8 is the smallest the PICA takes. Real textures
  are Phase D.
- **C3.** Each mesh is one vertex and one 16-bit index buffer in linear memory. The attribute layout is set once
  per frame and the buffer per draw.
- **C4.** The queue sort is in `render.odin`, shared by every target. Each backend only supplies
  `calculate_render_item_sort_key`.
- **Checked by:** `examples/render-check` (3DS only), which reads the framebuffer back. All ten probes pass:
  depth against submission order, alpha blending, back-face culling, both corners, and the background.
- **Open:**
  - C5 waits on B8.
  - C6 is optional.
  - The bottom screen was queued and thrown away here. It has its own target since 2026-11-22 (Phase F,
    "Bottom screen: status (3DS)").
  - The gate below (the cube scene) has not been run.

**C0. Shader toolchain.**
- Only `romfs/vshader.shbin` (a compiled binary) is in the repo; its source
  isn't.
- Add `matchbox/shaders/vshader.v.pica`. (Hand-written. Phase S later generates
  it from the shader language; keep this one as the reference output.)
- Add a step to `3ds_build.bat` that runs `picasso` (part of devkitPro) on it
  and outputs to `romfs/`. (The Vita's Cg shader step is V1.)
- New shader inputs: position (v0), uv (v1), color (v2).
- Uniforms: `projection` (from the tilt helper) and `model_view`.
- Done when: the existing triangles draw through the rebuilt shader.

**C1. Depth.**
- Confirm the top-screen render target was created with a depth format such
  as `GPU_RB_DEPTH24_STENCIL8`. Change it if not.
- Enable `C3D_DepthTest(true, GPU_GREATER or as your projection requires,
  GPU_WRITE_ALL)`. PICA depth and the comparison direction must match the
  projection's range; test both with a known overlap.

**C2. Textured TexEnv.**
- `C3D_TexBind(0, tex)`.
- TexEnv sources: texture 0 and the primary colour, combined with `MODULATE`.
- Keep the existing colour-only env for untextured draws, or use a 1x1 white
  texture, as on PC.

**C3. Meshes.**
- Vertex and index data in linear memory (`linearAlloc`).
- `C3D_DrawElements` with 16-bit indices.
- Per-mesh `BufInfo` and `AttrInfo`.
- `destroy_mesh` calls `linearFree`.

**C4. Same render queue.**
- The queue's sorting is shared code. The 3DS backend only executes it.
- Quads go through the write-cursor VBO, as the triangles do now.

**C5. Fit on the 3DS.**
- The top screen is 400x240, so the fit is 1x and the viewport is the full
  screen. Under letterbox with a different design aspect, use `C3D_SetScissor`.
- The scissor is in portrait framebuffer coordinates, so swap x and y, as in
  the projection.

**C6. Stereoscopic 3D** (optional, any time after C4).
- `gfxSet3D(true)`, with left and right render targets.
- `Mtx_PerspStereoTilt` / ortho with an eye offset scaled by
  `osGet3DSliderState()`.
- The queue is drawn once per eye.

**Phase C done when:** the Phase B cube and transparent quad scene runs on
Azahar and on real hardware. (C0 first deletes the old 2D sprite and triangle
path from the 3DS backend, as B0 did on PC.)

---

## Phase V: Vita 3D core (GXM)

Done after (or alongside) Phase C, with the same scene as the gate. The
bindings and setup already exist: `matchbox/vito/sce/gxm.odin` (about 1,800
lines) and `matchbox/vito/gfx` (context, three display buffers, depth buffer,
shader patcher, `gfx.alloc`, textures, render targets). A0b already gave the
Vita a working build and entry point, so this phase is only rendering. The
rules that apply throughout are in "The three targets". Files are
`render_vita_freestanding_arm32.odin` (and others) wrapped in `when VITA`.

**V0. Backend skeleton.**
- `render_vita_freestanding_arm32.odin` implements the same public procedures
  as `render_windows.odin`: `render_start`, `render_end`, `render_mesh`,
  `render_sprite` (and later the rest). It imports `vito/gfx` and `vito/sce`.
- `gfx.init()` in the window / render init. Check `gfx.init_step` and
  `init_error` on failure and log them through the logger.
- Optional 4x MSAA through `gfx.Config{multisample = ._4X}`; leave it off until
  V8 (fit) works, then decide (it costs GPU time and memory).
- Frame loop: `gfx.begin_frame()`, `gfx.clear(...)`, draws, `gfx.end_frame()`,
  `gfx.swap()`. `gfx.swap()` waits for the display and so gives 60 fps.
- Done when: the Vita clears to a colour each frame with the Matchbox API and
  `mb.print` shows the init result.

**V1. Shader toolchain.**
- (Phase S4 later generates these from the shader language; keep the
  hand-written ones as the reference output.)
- New sources in `matchbox/shaders/vita/`: `mesh_v.cg` and `mesh_f.cg`.
  `vito/gfx/shaders/sprite_v.cg` is the model (position, uv, colour in; uniform
  `float4x4`; `mul(vector, matrix)`).
- Compile with `tools/build_shaders.py` (psp2cgc) from the `vito` repo, to
  `.gxp`. **Commit the `.gxp` outputs** next to the sources, and embed them with
  `#load`, as `gfx` does for its clear shaders. A clean checkout then builds
  without `psp2cgc`.
- Add an optional step to `vita_build.bat`: if `psp2cgc.exe` is found, rebuild
  the `.gxp` files; otherwise use the committed ones.
- Done when: the existing `gfx` sprite shaders are replaced by the Matchbox
  ones and a coloured triangle draws.

**V2. Depth.**
- The screen's depth buffer already exists (`gfx` creates it) and is **reset
  every scene**, so there is nothing to clear. Check that `gfx.init` creates it
  with the same multisample mode as the colour surface.
- Set depth state per draw (V4); `gfx.clear` leaves `LESS_EQUAL` with writes
  on and culling off.
- Depth range is -1..1: use `mat4_perspective_gl` (A1).
- Done when: two overlapping quads of known order draw in the right order
  regardless of submission order.

**V3. Vertex format, uniforms, shader maths.**
- Same vertex layout as B2: `position: [3]f32, uv: [2]f32, color: [4]f32`,
  described with `gfx.attribute(...)` and `gfx.create_vertex_program(...)`.
- Uniforms: `view_projection` and `model` (and `tint`) through
  `gfx.use_programs(...)` and `gfx.set_uniform_matrix`. GXM has one default
  uniform buffer per program; write the per-draw values before each draw.
- Cg: `out = mul(float4(pos, 1), mul(...))` is the HLSL expression reversed.
  Keep one source of truth: the matrices are built exactly as for PC, and only
  the multiplication order in the shader differs.
- Verify with the same test as B4: a quad at x = +1 must move right. If it
  moves wrong or mirrors, fix the order in the `.cg` file, not the matrix.
- Done when: the test quad is in the right place and the view/projection from
  the camera move it correctly.

**V4. Pipeline state.**
- Cull mode: `sceGxmSetCullMode` back (counter-clockwise front, matching B5)
  and a no-cull mode for sprites. Check the winding on hardware; the winding
  convention is the first thing to test: draw one triangle both ways.
- Depth: opaque test and write; transparent test without write; HUD off, with
  `sceGxmSetFrontDepthFunc` and `sceGxmSetFrontDepthWriteEnable`.
- Blend: a fragment program per blend mode (`gfx.create_fragment_program` with
  `.None` and `.Alpha`; a fragment program is tied to its vertex program, blend
  and multisample mode, so create the pairs up front and look them up).
- Alpha test: no fixed-function alpha test on GXM; cut-out sprites (E3) use
  `discard` in the fragment shader, the same as the PC.
- Done when: the three states behave as in B5 on the test scene.

**V5. Textures.**
- `gfx.create_texture(w, h)` returns a linear 32-bit texture in CDRAM with
  `pixels` and `stride` (rows padded to 8 pixels). Pixels are
  `0xAABBGGRR`, which is `R8G8B8A8` byte order; load PNGs with the template's
  `libpng` (`-lpng16 -lz`), as `gfx/image.odin` does.
- Filter (point or linear) per texture: the `filter` parameter (D1).
- Stable address: texture memory is GPU-mapped and doesn't move; keep the
  `gfx.Texture` in a stable place (heap, not stack) for the frame's life.
- Size limit: a GXM texture is at most 4096x4096; the shia-test sheet (3328px)
  fits. Check the format limits when picking sheet sizes in D3.
- Done when: a textured quad draws, point and linear.

**V6. Meshes.**
- Vertex and index buffers from `gfx.alloc` (CDRAM or mapped uncached memory),
  16-bit indices; `sceGxmDraw` with `.U16` indices.
- `destroy_mesh`: call `gfx.finish()` first if the mesh could still be in
  flight, then `gfx.free(uid)`. Track allocations; GPU memory is a separate
  budget from the heap.
- Done when: the cube from B6 draws and destroys cleanly in a loop (no leak,
  no crash after 1,000 create/destroy cycles).

**V7. Render queue execution.**
- The queue's recording and sorting are shared (B7, `render.odin`). The Vita
  executes it the way PC and 3DS do: every item, sprite, shape or mesh, is one
  draw of a mesh already in GPU memory, placed by per-draw uniforms (`model`,
  `tint`, `uv_rectangle`, `alpha_cutoff`). Sprites all draw the one shared unit
  quad (`mbi.sprite_mesh`), shapes their shared triangle, circle and quad.
- Nothing is copied into GPU memory per frame. `gfx.use_programs` reserves each
  draw's uniform buffers from GXM's own ring, which is what keeps a frame in
  flight from being overwritten.
- Not done, and why: the earlier plan here copied CPU-transformed quad vertices
  into a ring of three GPU buffers, as `vito/gfx/draw2d.odin` does. Per-draw
  uniforms made that unnecessary: there are no per-frame vertices to protect,
  and the Vita would have been the one target transforming sprites on the CPU.
  Revisit only if the draw count per frame turns out to cost too much on
  hardware; batching would then be shared work, not Vita-only.
- The queues are `mbi.opaque_items` and `mbi.transparent_items`, kept between
  frames and cleared at `camera_end`, as on the other targets.
- Done when: the Phase B scene (spinning textured cube, half-transparent quad
  passing through it) renders on the Vita.
- Status (2026-11-23, Vita3K): sprites, shapes, textured and animated sprites,
  a perspective cube with depth and culling, and blended quads all draw
  (V1-V6 tests). The exact Phase B scene, a transparent quad passing through
  the cube, has not been run on the Vita yet.

**V8. Fit and viewport.**
- The surface is fixed at 960x544. `gfx.set_viewport(width, height, x, y)`
  takes the fit viewport; GXM also has `sceGxmSetRegionClip` for the scissor
  (bars). Clear the full screen to the bar colour first.
- Aspect 1.765 is a different shape from both the PC and the 3DS. The fit's
  default policy (F1) has to look right on all three.
- Done when: letterbox, overscan and expand behave as in the mockups, with the
  same design aspect as PC and 3DS.

**V9. Input and audio parity** (can run in parallel with V0-V8, platform layer
only; no rendering).
- `vito/vito/input.odin` provides `input_init`, `input_update`, a normalised
  `dpad`, two sticks, face buttons, triggers and the front/rear touch panels.
  Map it onto Matchbox's input API with the same names as the PC and 3DS
  backends; touch maps into the screen rect, as in F3.
- `vito/vito/audio.odin` exists; map it onto Matchbox's audio API. (Vorbis for
  music is `vito/vorbis`; add `vorbis` to `BRIDGES` when needed.)
- `vito/vito/time.odin`, `file.odin` and `dialog.odin` cover timing, assets and
  system dialogs.
- Window and events: the Vita has one fixed window; `poll_events` handles the
  system (power button, PS-button exit) and frees the temp arena.
- Done when: the demo's input test and audio test run on the Vita, and `mb.print`
  / the logger go through `vito`.

**Phase V done when:** the Phase B cube and transparent quad scene runs on
Vita3K and on real hardware, `vita_build.bat` works from a clean checkout
without `psp2cgc`, and the PC and 3DS scenes still draw.

---

## Phase D: textures and assets

**Phase D: status (2026-11-22).** The 3DS half of D1, D2 and D4 is done and checked in Azahar 2126.2.
- **D1.** `texture_3ds_freestanding_arm32.odin` loads the `.t3x` with Tex3DS and keeps the `C3D_Tex` on the
  heap. `create_texture_from_pixels` pads and tiles pixels the way tritex does. The renderer maps the shared
  0..1, v-down coordinates onto the power-of-two, v-up canvas.
- **D2.** `3ds_build.bat` copies each image's `.meta` next to its `.t3x`. An image with no `.meta` gets its
  frames guessed from its pixels, read back from the tiled texture.
  - **A `.meta` belongs to the picture beside it.** When a target's own image replaces a shared one, the
    shared `.meta` is left out, and the target's own `.meta` (if any) is used. Both `3ds_build.bat` and
    `vita_build.bat` do this. Without the rule, a smaller 3DS copy was read with the PC's ppu and grid.
  - `assets\3ds\images\meme_cat.meta` is the 3DS cat's own: ppu 6.4, scaled the same way as the 32x32
    image, so the cat is 5 units wide on both targets.
- **D4.** The rule is that subfolders are kept: `images\enemies\bat.png` becomes `gfx\enemies\bat.t3x`, the same
  name `load_texture` takes on PC.
- **Also new:** a game in its own folder can bring `assets\` of its own, which win over the root's.
- **Checked by:** `examples/render-check`, which has 21 framebuffer probes and 10 facts:
  - a loaded `.t3x` and the same picture made from pixels, both pixel-exact
  - one frame of a `.meta` grid
  - `flip_x`
  - the `.meta` values, and a guessed layout
  - a 3DS-only image that must not take the shared `.meta`
- **The Vita half** is V5: the Vita has no GXM renderer to upload to yet.

**D1. `Texture` as its own resource.** DONE on PC.
- `load_texture(filename) -> Texture` and `destroy_texture`.
- A filter per texture: point or linear. This is the old roadmap item 1.5.
- 3DS: keep the heap-allocated `^c3d.Tex`, because the address must stay
  stable.

**D2. Sidecar metadata.** DONE on PC.
- A small text file next to an image: `name.meta` with `ppu`, `columns`,
  `rows`.
- Missing means PPU 1 and one frame.
- 3DS: the build copies `.meta` files into romfs next to the `.t3x`.
- Vita: `assets/` is packed into the `.vpk` as `app0:/assets/...`, so the PNG
  and its `.meta` travel together. The Vita can use the full-size shared sheet
  (textures up to 4096px), or a smaller one of its own (see D3).

**D3. Sheet-packing tool** (in `tools/`, like `tritex`). DONE on PC.
- Packs a folder of frames (natural sort) into one grid PNG and writes the
  `.meta`.
- With `-3ds` / `-3ds-frame`, also writes a downscaled copy into
  `assets/3ds/images/` (limit 1024px); with `-vita` / `-vita-frame`, one into
  `assets/vita/images/` (limit 4096px). Each smaller sheet gets its own `.meta`
  with a scaled `ppu`, so a sprite is the same world size on every target.
- Done when: shia-test's 169 256px frames become a PC sheet (13x13, 3328px)
  and a 3DS sheet at 64px (832px, which fits in 1024).

**D4. Subfolder asset names on the 3DS** (the Vita keeps real paths, so only
the 3DS flattening matters). The build flattens files to their
basename, while `get_asset` uses the relative path. Pick one rule and apply it
in both `3ds_build.bat` and `get_asset`.

---

## Phase E: 2D as a projection (2D milestone, part 1)

**E1. New `Sprite`.** DONE on PC.
- A texture, a frame index (or an internal source rect), and
  `position: [3]f32`. 2D helpers set x and y; z is the layer.
- `rotation` (radians, about Z), `scale`, `tint`, `flip_x`, `flip_y`, `pivot`.
- The world size is `frame_px / ppu * scale`.
- `render_sprite` pushes a quad into the queue.
- On the 3DS, citro2d is no longer used for sprites.

**E2. 2D camera.** DONE on PC.
- `camera_create_2d(view_height)` with `position.xy` and `zoom`, where zoom
  scales `view_height`.
- Port `camera_follow` and `calculate_mouse_world_position` from main, adapted to the
  camera.

**E3. Layers and sorting rule** (write this down in the docs). DONE on PC.
- Opaque and cut-out sprites use depth.
- Semi-transparent sprites sort by z, then by submission order.
- Cut-out means the shader does `discard` below alpha 0.5. The 3DS uses the
  PICA alpha test (`C3D_AlphaTest`).
- Recommend cut-out as the default for sprites, because it is cheap and
  sort-free.

**E4. Shapes as world geometry.** DONE on PC.
- `render_triangle`, `render_rectangle`, `render_line` (thickness in units)
  and `render_circle` produce quads or triangles into the queue.
- Delete the pixel-space `render_triangle_points`.

**E5. Pixel snapping** (ortho only, opt-in). DONE on PC.
- Snap the camera position and quad corners to whole screen pixels at the
  current scale.
- Combined with `integer_scale`, this gives clean pixel art at 4x and 2x.

**E6. Animation port.** DONE on PC.
- Implement the shia-test minimum set on the new `Sprite`, with frames by
  index:
  - `animation_range`, inclusive
  - `create_animated_sprite_from_clip`
  - `switch_animation`: idempotent, with `looping`
  - `queue_animation`
  - `update_animation`, with `playing` readable
  - `is_animation_in_window`, frames relative to the clip
  - `flip_x`
  - one destroy for the sheet
- Fix the flip bug from main's `seat_first_frame`.
- `Animation_Clip.offset` (image pixels, mirrored by `flip_x` / `flip_y`) was
  left out at first and added after E7: some of shia-test's attack frames are
  drawn off the character's feet, and the offset puts them back.
- Still left out: `replay`, progress, frame-passed and `sprite_set_frame`.

**E7. Acceptance test: port shia-test.** PC half DONE (`examples/shia-test`, run with
`odin run examples/shia-test`). 3DS half DONE (2026-11-22, Azahar only); the Vita half waits for Phase V.
- 3DS status:
  - **Built with** `3ds_build.bat examples\shia-test`, with no layout changes. The camera is in world units
    (`1080 * PX` tall), so the 400x240 screen shows the same view as the PC, smaller.
  - **Sheet:** the 832x832 sheet from `assets\3ds\images` loads onto a 1024 canvas.
  - **Checked in Azahar:** it runs at 60 FPS, and walk, jump and the attack chain respond to the buttons.
    SELECT quits (added for the handhelds, which have no Escape).
  - **Clip offsets were 4x too big on the 3DS.** An offset is in image pixels divided by the sheet's ppu, and
    the 3DS sheet has 64 ppu to the PC's 256. The crouch attack measured 1.547 units on the 3DS against 0.387
    on PC.
    - Fix (the user's choice): sheetpack writes `source_ppu` (the full-size sheet's ppu) into a target's
      smaller `.meta`, and `calculate_animation_render_offset` shrinks the offset by `ppu / source_ppu`.
    - Game code keeps offsets in the pixels of the art it was made with.
    - Measured after: 0.38671875 x 0.0703125 units on both. A test covers it.
  - **Not checked:** the crouch attacks on screen. The emulator input tools can't hold two buttons at once, so
    the offset was measured with a probe instead. Real hardware isn't checked either.
  - **Same kind of gap left in the demo:** its cat crop (`Sprite.source`) is in PC pixels too. `source_ppu`
    could fix it the same way.
- PC first, with y flipped to +Y up and positions in units.
- Then the 3DS with the downscaled sheet; layout changes there are expected.
- Then the Vita with the full-size sheet; the 960x544 surface should show it
  the same as the PC at 1x.

**Phase E done when:** a 2D test scene (the mockup scene) looks the same on PC,
the 3DS and the Vita under letterbox, and shia-test plays on PC.

---

## Phase S: Matchbox shader language (added 2026-11-17)

**Why.** A custom shader today means HLSL (PC), Cg (Vita) and PICA assembly
(3DS): up to three times the work for one effect. The goal is one shader
language with Odin-like syntax, compiled to each target's own format.

**What each target takes** (from `vito/README.md` and `vito/docs/roadmap.md`,
the picasso manual, and `o3dx/README.md`):

| | PC | Vita | 3DS |
|---|---|---|---|
| Programmable stages | vertex and pixel | vertex and fragment | **vertex only** |
| Source format | HLSL (`mesh.hlsl`, compiled at startup by `d3d_compiler`) | Cg, `NAME_v.cg` / `NAME_f.cg` | PICA200 assembly, `.v.pica` |
| Compiler | already in Windows | Sony's `psp2cgc.exe` (proprietary, git-ignored, supplied by the owner) -> `.gxp` | `picasso` (devkitPro) -> `.shbin` |
| Fragment stage | the shader | the shader | **fixed function**: TexEnv combiners, lighting unit, fog and alpha test, all set by citro3d calls |
| Matrix use | `mul(M, v)`, column-major | `mul(v, M)`, Odin matrix passed as is | `dp4` of each matrix row (`c3d` matrix order is reversed) |
| Clip space | depth 0..1 | OpenGL, -1..1 | reverse-Z, clips to `[-w, 0]` |

**What this means for the design**
- **The 3DS fragment stage can't run a program.** A shader language that lets
  `fragment_main` do anything can't compile for the 3DS. So the fragment side
  has a small "portable" subset (texture sample, vertex colour, uniform colour,
  and combine operations: multiply, add, mix) that maps onto TexEnv stages. A
  shader outside that subset is a compile error for the 3DS, naming the line,
  and still builds for PC and Vita.
- **The 3DS vertex ISA is small.** picasso lists add, dp3, dp4, dph, dst, mul,
  mad, max, min, ex2, lg2, litp, flr, rcp, rsq, mov, mova, sge, slt and cmp, plus
  loops and `if`. It has no `sin`, `cos`, `sqrt`, `pow` or divide, so those
  either lower to a sequence (divide = `rcp` then `mul`) or are errors on the
  3DS. 96 float uniforms, 16 inputs, 16 outputs, 16 temporaries (picasso manual).
- **Known PICA quirks** (O3DX's Lighting-Example and the picasso manual) that
  the backend must produce correctly: constants are only allowed as the first
  source operand; a `dp4` group writing a temp leaves components in reversed
  order, so write each result straight to its destination; two consecutive
  `mova` instructions hang the GPU; only one distinct input register may be
  used across an operand's sources.
- **Nobody has done this before for PICA.** I found assemblers (picasso,
  nihstro) but no high-level compiler for the PICA200, so the 3DS backend is
  ours to write. Vita direct `.gxp` writing is not needed now (see S8).

**The language (a draft; decide in S0).** An Odin subset, so `.odin` tooling
mostly works and the syntax is the one you know. Matrices use `*` as in Odin
(`matrix * vector`); the backend picks `mul` order. A draft of today's
`mesh.hlsl`:

```odin
Vertex_In :: struct {
	position: [3]f32 `attr:"position"`,
	uv:       [2]f32 `attr:"texcoord"`,
	color:    [4]f32 `attr:"color"`,
}

Varying :: struct {
	position: [4]f32 `out:"position"`,
	uv:       [2]f32,
	color:    [4]f32 `out:"color"`,
}

Frame :: struct { view_projection: matrix[4, 4]f32 }
Draw  :: struct { model: matrix[4, 4]f32, tint, uv_rectangle: [4]f32, alpha_cutoff: f32 }

@(uniform = 0) frame: Frame
@(uniform = 1) draw:  Draw
@(texture = 0) tex:   Texture2D

vertex_main :: proc(in: Vertex_In) -> Varying {
	out: Varying
	world := render.model * [4]f32{in.position.x, in.position.y, in.position.z, 1}
	out.position = frame.view_projection * world
	out.color = in.color * render.tint
	out.uv = lerp(render.uv_rectangle.xy, render.uv_rectangle.zw, in.uv)
	return out
}

fragment_main :: proc(v: Varying) -> [4]f32 {
	color := sample(tex, v.uv) * v.color
	if color.a < render.alpha_cutoff do discard()
	return color
}
```

On the 3DS the `discard` becomes the PICA alpha test state (see E3), and the
fragment multiply becomes one TexEnv stage.

Per-target variants use Odin's own `when TARGET == .PICA { ... } else { ... }`,
so a shader can provide a fallback where a target can't do something.

**Where it runs.** A build-time tool, `tools/mbsc.odin` (**mbsc**, the Matchbox
Shader Compiler; like `tritex`), not code in the game. Inputs: a shader file and `-target`. Outputs:
- PC: `name.hlsl`
- Vita: `name_v.cg` and `name_f.cg`. mbsc stops at Cg: turning that into `.gxp` is
  vito's job (`tools/build_shaders.py` with `psp2cgc.exe` today, vito's own Odin
  compiler later). The `.gxp` outputs stay committed (vito's rule, kept)
- 3DS: `name.v.pica` then `picasso` -> `.shbin`, plus a TexEnv table
  (`name.tev`) for the fragment stage
- All: a small reflection file listing the attributes, uniforms and textures
  each stage actually uses (Vita removes unused ones; the 3DS assigns registers)

**S0. Specify the language** (write `docs/shader_language.md`).
- Types, built-in functions, entry points, uniforms and textures, and a table
  of what compiles on which target. Settle the decisions below first.
- Decided 2026-11-18: no silent approximation. A built-in a target can't do is a
  compile error that says how to do it instead; `sin_approx` and `cos_approx` are
  explicit built-ins that state their error. Errors are numbered `MBS-E<n>` and
  explained in `docs/shader_errors.md`, in the style of rustc: what, where, why,
  and a fix. The 3DS fragment spec assumes `DOT3_RGBA` will be in the o3dx
  bindings.
- Built-in support is measured, not read from manuals: `tools/mbsc_probe.odin`
  compiles one tiny shader per built-in with d3dcompiler, `psp2cgc` and `picasso`
  and writes the table (picasso checks the 3DS instruction lowering, so a pass
  means it assembles, not that it computes the right number).
- Done when: the draft above is a complete spec, and every built-in is marked
  PC / Vita / 3DS.

**S1. Front end** (`tools/mbsc.odin`).
- Parse the shader (try `core:odin/parser` first), type-check the subset,
  build an intermediate form, report errors with file and line.
- Done when: the draft above parses and type-checks, and a deliberate mistake
  gives a clear message. Golden-file tests.

**S2. PC backend: HLSL.**
- Emit HLSL from the intermediate form. Port `mesh.hlsl` to the language.
- Done when: the demo looks identical with the generated HLSL, including the
  alpha cut-off and the `uv_rectangle` sprites.

**S3. Bindings and reflection.**
- Engine-owned slots (`frame`, `render`) bind the same way on every target, and
  the reflection file tells each backend what to look up.
- Done when: the PC runtime reads the reflection output instead of hard-coding
  slots.

**S4. Vita backend: Cg.**
- Emit `_v.cg` and `_f.cg` with the Vita rules: `mul(vector, matrix)`, attribute
  names the runtime can find with `gfx.attribute`, OpenGL clip space.
- Hook `psp2cgc` as an optional step; commit the `.gxp` outputs.
- Done when: the language's mesh shader replaces the hand-written V1 one and
  the V3 triangle draws on the Vita.

**S5. 3DS backend: vertex (PICA assembly).**
- Lower the vertex subset to PICA instructions: matrix transform as four `dp4`
  groups straight into outputs, `mad`, `rcp` / `rsq` for divide and inverse
  root, `min` / `max`, `ex2` / `lg2`, `flr`. Allocate the 16 temporaries.
- Generate the quirk-safe forms listed above. Run `picasso`.
- Done when: the generated shader draws the same as O3DX's `SpinningCube`
  vertex shader.

**S6. 3DS backend: fragment (TexEnv).**
- Map the portable fragment subset onto TexEnv stages and emit the table;
  the runtime applies it with `C3D_TexEnv*`. Alpha cut-off becomes
  `C3D_AlphaTest`.
- Done when: the textured, tinted cube and the cut-out sprite look the same as
  PC.

**S7. Capabilities and fallbacks.**
- The `when TARGET` blocks, per-target errors, and `mbsc --check` that
  reports what compiles where.

**S8. Later: write `.shbin` and `.gxp` directly.**

*S8a. `.shbin` (3DS).* Start only after the generated PICA assembly has been
tested on real 3DS hardware (S5/S6 were checked on Azahar only).
- Add an `mbsc` option that writes `.shbin` itself (DVLB / DVLP / DVLE:
  instruction words, the shared operand-descriptor table with its 128-entry
  limit, flow-control encoding, constant, uniform and output-map tables,
  symbols). `--emit-pica` stays; the `.v.pica` output is not removed.
- Check it against `picasso`: assemble the same program both ways, decode both
  files and compare instructions, descriptors and tables, then run in Azahar and
  on the 3DS.
- Done when: every shader the PICA tests cover builds to a `.shbin` that
  matches `picasso`'s in behaviour, without `picasso` installed.

*S8b. `.gxp` (Vita).* Separate and later than S8a; much larger, because the
GPU's instruction encoding is only partly public. Check what is documented
before scheduling it.
- Vito plans to replace `psp2cgc` with its own compiler (vito's
  `docs/gxp-format.md` has a staged plan: disassemble, assemble, a small
  subset, then widen). The shared piece is the back end, not Cg parsing:
  one `gxp` package in its own repo that takes a small, stable low-level IR
  and writes `.gxp`. It knows nothing about Cg or mbs.
- Vito's compiler parses Cg, lowers it to that IR and calls the package.
- mbs first emits Cg and calls vito's compiler (`--emit-cg` stays as the
  debuggable path). Later it may lower its own IR straight to the shared IR,
  skipping the text round trip. mbs's internal IR is not the shared interface.
- Keep `psp2cgc` as the reference while this is built: compile the same shaders
  both ways and compare in Vita3K, then on a Vita.
- Done when: mbs and vito both produce `.gxp` through the shared package, and
  the Vita shaders draw the same as with `psp2cgc`.

**Order.** S0 to S3 need only PC, so they can start once the PC side is stable
(after Phase E) and before the handheld work. C0 and V1 then take generated
shaders instead of hand-written ones; until S4 and S5 exist the hand-written
ones stay, and become the reference the backends are compared against.

**Phase S done when:** one shader file builds for PC, Vita and 3DS and the
Phase B cube scene looks the same on all three (the 3DS within the fragment
subset).

**Risks.**
- The 3DS fragment subset is much smaller than the vertex one; most effects
  that need a real pixel shader won't exist there.
- `psp2cgc` can't be redistributed, so the Vita route depends on a copy
  the owner has, and on committed `.gxp` files.
- PICA floats are 24-bit, so results won't be bit-identical to PC.
- S5 and S6 are the real work: the front end and PC backend are ordinary
  compiler tasks; PICA code generation and TexEnv mapping have no reference
  implementation to follow.

---

## Phase F: screen space, text, input (2D milestone, part 2)

**F1. HUD camera.** DONE on PC (2026-11-18). Built as a screen camera that goes
through the one `camera_start` / `camera_end` pair, with `screen_start()` /
`screen_end()` as one-line wrappers, so each handheld ports one pair of entry
points, not two (decided 2026-11-18).
- `Camera.screen` and `create_screen_camera(view_height)`. A screen camera draws
  with depth off, in submission order (the opaque texture sort is skipped).
- `set_screen_height(units)` (default 12, a placeholder), `calculate_visible_rectangle()`
  and `calculate_anchor_position(anchor, offset)`, on top of the shared pure maths
  `calculate_camera_visible_rectangle` and `calculate_camera_anchor_position`, which have tests.
- A second HUD (the 3DS bottom screen, F4) is another screen camera passed to
  `camera_start`.
- Not decided yet: the default fit policy and the overscan cap. F1 shipped
  without them: the HUD fills the window and follows its shape. They come with B8.
- Known limit: in a screen pass cut-out items are drawn before blended ones, so
  a blended panel is always on top of a cut-out icon, whatever the submission order.

**Bottom screen: status (3DS, 2026-11-22).** Checked in Azahar only.
- **The bottom screen has its own citro3d target** (240 x 320, with depth).
  - `bottom_screen_start` points the frame at it, and `camera_start` sizes its view by the screen being drawn, so
    the shared queue and cameras draw there as on the top screen.
  - `clear_background` clears both screens.
- **`print` draws on the bottom screen,** replacing the ctru console (decided 2026-11-22).
  - The last 32 lines are kept in `mbi.print_log`. At `render_end` the newest lines that fit are drawn over the
    game's bottom screen: wrapped, newest at the bottom of the block, on a dark backdrop.
  - The text is in the system font at `print_log_settings.pixel_size` (12).
  - Each line still goes to the emulator's log and Luma3DS's debugger.
- **Checked by:** `examples/render-check`.
  - A red rectangle over the left half of the bottom screen's view lands on the left half of the bottom
    framebuffer, and the cleared colour is on the right.
  - The print log's text is lit where it should be.
- **Every pass, every frame (decided 2026-11-22).** A game draws the world, the HUD and the bottom screen every
  frame and never picks a screen. Matchbox drops the passes a target cannot show (`bottom_screen.odin`):
  - On PC and the Vita, `.FULLSCREEN` drops the world and HUD (`is_top_screen_hidden`, asked by
    `camera_start`), and `.HIDDEN` drops the bottom screen.
  - On the 3DS both screens always show.
  - Whether a menu is open is the game's own state. `is_bottom_screen_visible` only says whether the screen is
    shown.
  - The demo works this way: B toggles its `menu_open`, and its three passes are always drawn.
- **`.CONSOLE` (new layout value).** On the 3DS it hands the bottom screen to ctru's console: `print` writes there
  the old way, citro3d's bottom target is unlinked, and the bottom screen pass is dropped. Any other layout gives
  the screen back, with the screen format and double buffering citro3d needs restored. On PC and the Vita it is
  `.HIDDEN`.
- **Crashes show on the console.** `start_runtime` wraps o3dx's assertion handler (`report_crash`): on a failed
  assert or a panic it brings up ctru's console on the bottom screen, shows the message, and waits for START. Then
  o3dx appends the message to the SD card log and traps. Bounds-check and nil failures trap without a message, as
  before.
- **Checked in Azahar** with a throwaway app:
  - In `.CONSOLE` the top screen keeps drawing and a print lands on the console.
  - Switching back draws the game's rectangle on the bottom screen in the right colours.
  - A deliberate panic shows its file, line and message, and "Press START to quit".
  - The demo shows the world and HUD on top and its menu on the bottom.
- **Known gaps:**
  - Each glyph of the print log is one draw.
  - The PC side of the pass rule is covered by a unit test (`bottom_screen_windows_test.odin`). It has not been
    watched in a window.

**F2: status (3DS, 2026-11-22).** Each target uses its own native text (decided 2026-11-22).
- **3DS:** `font_3ds_freestanding_arm32.odin` bakes from the console's system font. It ignores the TTF the game
  passes.
  - It copies the 95 printable ASCII glyphs out of the font's 4-bit tiled sheets into the shared grayscale atlas,
    scaled from the font's 30-pixel cells to the size asked for. Each atlas pixel averages a 4 x 4 grid of samples.
  - Each glyph's rectangle and advance come from libctru's `fontCalcGlyphPos`. The baseline comes from the
    sheet info.
  - Everything after the bake is shared: `create_font`, layout, wrapping and measuring.
  - If the system font cannot be mapped, the game prints that once and text draws nothing.
- **Checked by:** `examples/render-check`.
  - A line of text with descenders has lit pixels inside the box `calculate_text_size` and the ascent and
    descent give it, and nothing in an 8-pixel ring around that box.
  - Drawn at three times the size in a throwaway build, the glyphs were whole: the tails of g, j and y, and
    the dot on the j.
- **Vita:** a stub until Phase V (`font_vita_freestanding_arm32.odin`).

**F2. Text.** Decided 2026-11-18: port the font code from `main` (`font.odin`,
`text.odin`) and rework it onto this branch, for PC first. It bakes with
`stb_truetype` (`vendor:stb/truetype`), as on main. **This may change: the
`stb` dependency might be removed later** (a different baker, or a build-time
atlas from an asset tool). Keep the stb calls inside `create_font` and the glyph
loop of `render_text_string`, and keep `Font` free of stb types where it can be, so
that swap does not touch games.
- Rework, not a copy: main draws glyphs through its own pipeline and shader; here
  each glyph is a blended `Sprite` through the existing queue (no new shader), in
  world units with +Y up, so text works in a world pass and in `screen_start`.
- Leave behind from main for now: the size cache (`get_font`), the UI scale
  (`sharp_face`) and the pixel-space `draw_text_ui`; the HUD pass replaces it.
- Rasterise glyphs at final pixel size into a texture atlas, drawn as quads.
- PC: `stb_truetype` (vendor) to bake the atlas.
- 3DS: the system font (`fontGetSystemFont`, which is what citro2d text uses),
  or a pre-baked atlas built with the asset tools.
- Vita: the same baked atlas (the Vita has its own `vita2d`/`gfx` text, but
  it is pixel-space and doesn't use the camera).
- Decide which before starting. The pre-baked atlas is identical on all three
  targets, which is the argument for it.
- 2026-11-21 (A0b T4): **stb is isolated.**
  - `bake_font_atlas` in `font_windows.odin` is Matchbox's only stb call.
  - `Font` holds `Baked_Glyph`, not stb's type.
  - `text.odin` places glyphs with `calculate_glyph_corner`, stb's arithmetic written out. The test
    `glyph_corner_matches_stb` checks it against stb.
  - The handhelds' `bake_font_atlas` (`font_handheld_freestanding_arm32.odin`) bakes nothing, so text draws
    nothing there until this decision is made. Whichever option is chosen replaces that one procedure.
  - A third option for the handhelds: stb compiled for ARM, with a bridge for `BakeFontBitmap`'s float
    argument, the way `libm/bridge.c` handles maths.

**F3. Input to world.** DONE on PC for orthographic cameras (2026-11-18).
- Mouse, ortho: `calculate_mouse_world_position(camera)` (from E2) already inverts any
  `create_camera_2d` camera, and a screen camera is one, so it works for the
  HUD too. New: `calculate_mouse_screen_position()`, the mouse in HUD units, the same space
  as `calculate_anchor_position`. A test checks that a window corner gives that anchor.
- Hit-testing: `is_point_in_rectangle(point, min, max)` and `calculate_sprite_bounds(sprite)`.
  The bounds ignore rotation and pixel snapping.
- Still open:
  - Perspective: a ray from the camera (Phase G).
  - Points in the bars report as outside: needs B8. With no bars, every point
    in the window is inside.
- 3DS touch maps to the bottom screen's camera (F4). DONE on the 3DS (2026-11-22, Azahar only):
  - The stylus is the mouse. `is_mouse_pressed/held/released(.LEFT)` come from `KEY_TOUCH`, and the other buttons are
    never down. `get_mouse_position` is the stylus in bottom screen pixels.
  - `calculate_mouse_bottom_screen_position` gives the point in the bottom screen's units, through
    `calculate_screen_to_world_2d` over the 320x240 screen. `inside` is true while the stylus is down and on the
    frame it lifts, and false in `.CONSOLE`.
  - The point is kept after the stylus lifts: `hidTouchRead` reports 0, 0 by then, and a button that acts on release
    still needs the point it lifted from.
  - `calculate_mouse_world_position` and `calculate_mouse_screen_position` stay {0, 0}: the stylus never reaches the top
    screen. The demo ignores a world click made on the bottom screen for that reason.
  - Checked in Azahar with a throwaway app:
    - Pixel (279, 39) gave (5.95, 4.05) units, and (80, 176) gave (-4, -2.8); both match 12 units over 240 pixels.
    - A tap on a box counted as a hit.
    - A square followed a drag.
    - A release outside the box reported the last held point and no hit.
- Vita front touch (and the rear panel) report in the panel's own coordinate
  range, not screen pixels; scale them to 960x544 first, then treat as mouse.
  Check the range on hardware.

**F4. 3DS bottom screen** as a second surface (320x240) with its own camera.
DONE on PC (2026-11-18).
- On PC: `set_bottom_screen(.HIDDEN)` (the default) or `(.FULLSCREEN)`. The game
  chooses. HIDDEN queues the drawing and throws it away; ask
  `is_bottom_screen_visible()` to skip the work. FULLSCREEN fills the window, and
  the game draws only the bottom screen until it switches back (the demo uses B or
  Start). No letterbox: the view is as tall as the HUD (`set_screen_height`), its
  width follows the window, and in a window narrower than 4:3 it grows taller
  instead so the 320x240 shape is never cut off. Lay it out with
  `calculate_bottom_screen_anchor_position`.
- `bottom_screen_start` / `bottom_screen_end` draw it, `calculate_mouse_bottom_screen_position()`
  is the touch stand-in (position plus `inside`, false while hidden).
- Left out at this time: an overlay (both screens at once) and a stacked layout. The
  overlay needs a per-camera viewport and scissor; stacked also needs the top
  screen in a sub-rectangle (B8). Add them when a game needs both screens at once.
- The test hardware is a New 3DS LL: same 400x240 and 320x240 screens as the
  original, so nothing here depends on the model.
- Vita: one 960x544 screen plus touch panels; the game gets the main surface,
  and the front touch panel maps to it (F3). No second screen exists, so
  bottom-screen content is drawn as an overlay or hidden, like the PC choice.

**2D milestone done when:**
- shia-test runs on PC, the 3DS and the Vita (positions tuned for the 3DS).
- A HUD stays anchored under every fit policy.
- Text is crisp on both targets.

---

## Phase G: 3D games (3D milestone)

**G1. Models** (all three targets).
- glTF on PC: port main's `gltf2` parsing, but not its GPU code.
- 3DS: a **build-time** converter from glTF to a compact binary
  (positions/uv/normals/indices, 16-bit indices, textures through tritex).
  With the 3DS runtime (A0), parsing glTF on the device is now *possible*, but
  the converter is still the better choice: no JSON parse time or heap spike
  at load, and smaller files in romfs. The Vita can read the same converted
  binary from `assets/`; GPU buffers there come from `gfx.alloc`.

**G2. Lighting.**
- Directional plus ambient to start. Add `normal` to the vertex format.
- PC: per-pixel in HLSL.
- 3DS: PICA hardware fragment lighting (`C3D_LightEnv`, `C3D_Light`) or
  per-vertex in the shader.
- Vita: per-pixel in Cg is feasible (it has a real programmable pipeline).
- Keep the shared API to what the 3DS can do. Anything PC- or Vita-only is
  marked as such.

**G3. 3D cameras.** Port main's first-person, third-person and orbit helpers
onto `Camera`.

**G4. Billboards.** Sprites facing the camera in a perspective scene; they
reuse E1.

**G5. Render targets.**
- Render to a texture: `C3D_RenderTargetCreateFromTex` on the 3DS, an RTV plus
  shader resource view (SRV) on PC, and `gfx.create_target` /
  `gfx.begin_target` on the Vita (offscreen targets are not multisampled).
- This also enables an opt-in pixel-perfect 2D mode: render at the design size,
  then upscale.

**G6. Skinned animation** (late).
- Port main's animator logic.
- 3DS skinning on the CPU, or in the vertex shader with a small bone limit.
  Measure before choosing.

**3D milestone done when:** a small third-person scene (a model, lighting, a
camera rig, and a HUD) runs on PC, the 3DS and the Vita.

---

## Phase H: hard-float on the handhelds (later: when performance is the focus)

Not part of the main milestones. Do it after the main parts of Matchbox are
complete, when performance becomes the next concern.

**Why (revised 2026-11-14):** correctness is no longer the reason, because
Odin's libm calls are fixed at link time (see "3DS float rules"). What
hard-float still removes:
- every float parameter crossing into citro3d / citro2d / libctru goes through
  a `uint32_t` bridge, so each new binding needs a bridge function;
- the `objcopy --redefine-syms` step and the `o3dx/libm` wrappers (an extra
  call layer on every `sinf`, `fmaf` and conversion);
- citro3d's own optimised maths can't be called directly with floats.
So this is a performance and simplicity phase, as originally planned.

**Root cause (found 2026-11-12):** Odin dev-2026-11 already has hard-float
(AAPCS-VFP) argument lowering for arm32, float structs included. But it emits
the target triple `arm-none-eabihf` without normalising it, so LLVM appears
to fall back to soft-float. That's also why `3ds_build.bat` appends
`.eabi_attribute 28, 1` by hand.

**Plan:** Farlite installs an Odin compiler built with the fix, so the
`freestanding_arm32` target really is hard-float. Then:
1. Confirm with a small test that `proc(a: f32, b: f32)` passes `b` in `s1`
   and that the object is tagged "VFP registers"
   (`arm-none-eabi-readelf -A`).
2. Remove the `.eabi_attribute 28, 1` append, the `objcopy --redefine-syms`
   step and `o3dx/libm` from `3ds_build.bat`. (The Vita has the same pair in
   `vito/libm`; the Farlite compiler would remove it there too.)
3. **In the same change**, rework every o3dx binding with float parameters:
   - Real functions in citro2d/citro3d/libctru: declare them directly with
     `f32`, drop the `link_name`, delete the bridge.
   - `static inline` header functions: rewrite in Odin, or keep a plain C
     wrapper with `float` parameters and no `u2f`/`f2u`.
   - Bridges whose Odin declaration already uses `u32` keep working, so they
     can go later.
4. Drop the "3DS float rules" section. `fmaf` stays a slow library call on
   VFPv2 even then, so keep `mat4_mul` for speed.
5. Done when: the demo, shia-test and the Phase G scene run unchanged on
   hardware, and no `u2f`/`f2u` bridge remains for a non-inline function.

**Fallback, already proven in the scratchpad:** with the stock compiler, emit
IR (`-build-mode:llvm-ir`) and compile it with
`clang -c -O2 --target=arm-none-eabihf -mcpu=mpcore -mfloat-abi=hard`. That
needs a C shim mapping `__aeabi_h2f` to libgcc's `__gnu_h2f_ieee`, and step 3
above all the same.

---

## Removal checklist (old to new)

| Old (current rewrite) | Replaced by | Remove after |
|---|---|---|
| PC `Constants.viewport_size` and the pixel→NDC shader maths | `view_projection` cbuffer | B4 |
| PC immediate `batch` + `flush` | Render queue | B7 |
| 3DS `Renderer` enum, `use_renderer`, `finish_renderer` | Render queue | C4 (gone, 2026-11-22) |
| 3DS hand-built pixel projection rows | `GL_TO_PICA_DEPTH` and `TILT_TO_PANEL` on linalg's projection | C0 (gone, 2026-11-22) |
| 3DS `vshader.shbin` without source | mbsc's `mesh.3ds.v.pica` + picasso step | C0 (gone, 2026-11-22) |
| `Sprite.x/y` (pixels), `width/height`, pixel `source` | `position: [3]f32`, frame index, PPU | E1 |
| citro2d sprite drawing (`DrawImageAtRotated`, sub-texture maths) | Quads in the queue | E1 |
| `render_triangle_points` (pixel-space) | World-space shapes | E4 |
| `get_window_size()` as the game's coordinate space | `calculate_visible_rectangle()` + camera | F1 |
| citro2d link entirely | Own text (F2) | F2, if citro2d isn't used for text |
| `u2f`/`f2u` bridges, `.eabi_attribute 28, 1` append / `.ARM.attributes` removal, `objcopy` libm rename + `o3dx/libm` + `vito/libm`, 3DS float rules | Hard-float Odin from Farlite | Phase H |
| `c3d.sinf`, `cosf`, ... `u32` bridges (added 2026-11-12) | `math.sin` etc. via the libm rename | When nothing calls them |
| Fixed-buffer `get_asset` / `print` in `util_3ds_*.odin` | Same code as the PC versions (A0 runtime) | After A0, when convenient |
| `vito/gfx` `draw2d.odin` pixel batcher (as the Vita's 2D path; not part of Matchbox yet) | Matchbox's render queue (V7) | V7; keep it as a reference until then |
| `vita2d` bindings (`vito/vita2d`) | Not used by Matchbox, which draws through GXM | Never needed by Matchbox; leave it in `vito` |

## Risks to watch

1. **The libm rename step** (A0/A1 onward): float maths is correct on the 3DS
   only while `3ds_build.bat` keeps running the `objcopy` rename and
   `-microarch:mpcore`. If either is dropped, the same code returns garbage
   without an error. The `nm -u` check in "3DS float rules" catches it. Also
   watch for **slow** matrix `*` in per-draw code on the 3DS.
1b. **The runtime is off until A0:** `make`, `append`, maps and `fmt.tprintf`
   silently do nothing on the 3DS until the entry point calls `o3dx.init()`.
2. **HLSL matrix packing** (B4): a transposed matrix looks like a wrong
   rotation. Check with the x = +1 test before anything else.
3. **PICA shader authoring** (C0): new language and toolchain. Start from a
   citro3d example shader and change one thing at a time.
4. **3DS depth direction and range** (C1): wrong comparison means nothing
   draws. Test with two overlapping quads of known order.
5. **3DS linear memory** (C3): VBOs and textures share a small linear heap.
   Track allocations, and free on destroy.
6. **Transparency vs batching** (B7/E3): sorting transparent items breaks
   texture runs. Defaulting sprites to cut-out keeps most of them batched.
7. **3DS performance:** the vertex throughput is modest, and CPU-transformed
   quads cost ARM11 time. Measure with a sprite stress test at the end of E.
8. **Text on the 3DS** (F2): if citro2d is dropped, text must be your own.
   Decide before E1 removes citro2d sprites, or keep citro2d linked for text
   only.
9. **Target selection** (A0b): the `when VITA` mechanism relies on each target's
   imports type-checking in the other target's build. If `foreign import`
   libraries from the unused target leak into a link, the build fails with
   missing stubs. A0b's two checks and two builds are the test.
10. **Vita GPU memory** (V6, V7): GPU buffers and textures come from a separate
   budget (CDRAM and mapped memory) and are never freed while in flight. Use
   a ring of 3 for dynamic vertex data and `gfx.finish()` before freeing.
11. **Vita shader toolchain** (V1): `psp2cgc` isn't in the repo. Commit the
   compiled `.gxp` and make recompiling optional, or the build breaks on any
   machine without it.
12. **Cg multiply order and winding** (V3, V4): a mirrored or empty frame is
   nearly always `mul(v, M)` vs `mul(M, v)` or the front-face setting, not the
   matrix. Test one triangle both ways before anything else.
13. **Three screens, one design** (A4, F1): 400x240, 960x544 and any PC window
   have different aspects. Decide the default design aspect and policy by
   looking at all three, not PC alone.

## Decisions to make (and record here with dates)

- [x] Up axis and handedness: right-handed, +Y up, camera looks down -Z, everywhere including 2D (decided 2026-11-12). Screen/HUD pixel space stays top-left, y-down.
- [x] 3DS FPU: `-microarch:mpcore` in `3ds_build.bat` (2026-11-12, runs in the emulator).
- [x] 3DS float calls: stay soft-float; hard-float via a Farlite-built Odin in Phase H (2026-11-12). Odin's own libm calls are fixed at link time by `o3dx/libm` (2026-11-14); calls into citro3d / ctru with float parameters still use `u32` bridges.
- [x] 3DS runtime: o3dx provides the allocator, temp arena, logger and assertion handler (2026-11-14). Switched on in A0.
- [x] Vita is a core target, in the renderer core with PC and 3DS (decided 2026-11-14). Its specifics are settled in "The three targets", A0b and Phase V.
- [x] Target selection: `-define:MATCHBOX_VITA` with `when` blocks, since `odin check` can't see the microarch (chosen 2026-11-14; verify in A0b that each target's imports type-check in the other's build).
- [x] PC first, with `core:math/linalg` (2026-11-14): no shared `math.odin` for now; performance work waits until PC, 3DS and Vita all run. D3D needs the GL-to-D3D depth remap (`z' = 0.5z + 0.5w`) on `linalg` projections. A1's shared file moves over when a handheld needs it.
- [x] Shader language syntax (S0): an Odin subset parsed with `core:odin/parser` (decided 2026-11-19).
- [x] Shader file extension and location: `.mbs`, under `matchbox/shaders/` (decided 2026-11-18). Compiler: `mbsc`.
- [x] 3DS fragment policy: portable subset that maps to TexEnv, a compile error naming the line and the fix for anything else (decided 2026-11-18).
- [x] Generated shader output: generate at build on PC; Vita `.gxp` stays committed (vito's rule, 2026-11-13); 3DS output decided at S5 (decided 2026-11-18).
- [x] Vita emulator: Vita3K is the per-step check while the bindings are built; the user checks on the real Vita (decided 2026-11-22).
  User, 2026-11-21, for both handhelds: Claude may run Azahar and Vita3K to check work it does; the user checks on the New 3DS LL and the Vita.
- [ ] `Matchbox_Info` for three targets (A0b): one shared struct holding the engine state, with a per-target `Backend_State` field for the device handles (recommended), or one whole struct per target, as now.
- [ ] Entry point on the handhelds (A0b): Matchbox can't own `odin_main`, because it can't call the game's `main`. It can't import the game, and `intrinsics.__entry_point()` compiles to nothing under `-build-mode:asm`: the compiler sets the entry point only for executables (`src/checker.cpp`, "check entry point"; measured 2026-11-21). `init` can't set it either, because `context` is passed per call, so a context set inside `init` never reaches the game's `main`. That is the same reason `context.logger = mb.mbi.logger` is needed on PC. Recommended: one six-line game file shared by both consoles, calling `mb.start_runtime()`.
- [ ] Vita MSAA: off, or 4x (decide at V8).
- [ ] Design aspect: all three screens have different shapes (400x240, 960x544, any PC window); pick the default design aspect and fit policy together (F1).
- [ ] Sprite pivot convention (recommended: `{0.5, 0.5}` = centre).
- [ ] Sprites default to cut-out or blended (recommended: cut-out).
- [ ] Default fit policy and the overscan cap (F1 shipped without them; decide with B8).
- [ ] Text approach on the 3DS (before E1).
- [x] Bottom screen on PC: hidden or fullscreen, no overlay or stacked layout for now (decided 2026-11-18).
