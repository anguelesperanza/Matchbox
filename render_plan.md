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
  - The visible rect plus `anchor_position` for the HUD.
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

**Selecting the target's files** (tested 2026-11-14 with `odin check`/`build`
on scratchpad packages; not yet used in Matchbox). The 3DS and Vita are both
`freestanding_arm32`, so the `_3ds_freestanding_arm32` suffix and
`#+build freestanding arm32` match both. What was tried:
- **`odin build -file`: does not work.** `-file` builds one file as its own
  package, and several files are rejected ("takes a package/directory").
- **A microarch build tag (`#+build mpcore`): does not exist.** Odin's tags are
  OS and architecture only.
- **`when ODIN_MICROARCH_STRING == "cortex-a9"`: works for `odin build`,** but
  `odin check` has no `-microarch` flag and always sees the default
  (`arm1176jzf-s`), so the Vita check couldn't check Vita code.
- **`#config` with `-define:MATCHBOX_VITA=true`: works for both `check` and
  `build`. This is the chosen mechanism.** `VITA :: #config(MATCHBOX_VITA, false)`
  once in a shared file; `when !VITA { ... }` wraps the contents of each 3DS
  file and `when VITA { ... }` the Vita file. `vita_build.bat` and
  `vita_check.bat` pass `-define:MATCHBOX_VITA=true`.
- **Catch:** `import` is a syntax error inside `when`, so each target file
  imports its packages at the top, unconditionally. A 3DS build therefore
  type-checks the Vita files' imports (`vito/...`) and a Vita build those of
  the 3DS (`o3dx/...`). Whether that compiles cleanly, and whether `foreign
  import` libraries of the unused target leak into the link, is **untested: it
  is the first thing A0b verifies.**
- **Longer term:** Farlite's patched Odin (Phase H) could add `3ds` and `vita`
  build tags, and the `when` blocks then become `#+build` lines. The compiler
  already has a subtarget mechanism (the Playdate target uses it).

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
  on all three targets (Citra for the 3DS, Vita3K or real hardware for the
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

**A0b. Target selection and the Vita scripts** (new 2026-11-14; right after A0,
before A1, because it fixes the file layout everything after it uses). See "The
three targets" for the mechanism and its untested catch.
- Add one shared file, e.g. `matchbox/target.odin`:
  `VITA :: #config(MATCHBOX_VITA, false)`.
- Wrap the contents of every existing `*_3ds_freestanding_arm32.odin` in
  `when !VITA { ... }`, keeping the imports at the top, unconditional. The root
  `3ds_entry_point_freestanding_arm32.odin` gets the same treatment (it's in
  `package demo`, so import `target` through `matchbox`, or use a second
  `#config` there; pick the smaller change).
- Add the Vita entry point (`vita_entry_point_freestanding_arm32.odin`, wrapped
  in `when VITA`):
  ```odin
  import vito "matchbox/vito/vito"

  @(export, link_name = "odin_main")
  odin_main :: proc "c" (argc: i32, argv: [^]cstring) -> i32 {
  	context = vito.init()
  	defer vito.shutdown()
  	main()
  	return 0
  }
  ```
- **`vita_check.bat`:** the same as `3ds_check.bat` plus
  `-define:MATCHBOX_VITA=true`. Run both checks after the wrapping; **both must
  pass**, which is the test of the "imports compile in the other target" catch.
- **`vita_build.bat`:** based on `vito/NewProjectTemplate/build.bat` (the
  separate `vito` repo), with these settings:
  - `odin build . -target:freestanding_arm32 -o:speed -build-mode:asm
    -no-entry-point -min-link-libs -no-thread-local -microarch:cortex-a9
    -define:MATCHBOX_VITA=true`
  - Assemble each `.S` with `arm-vita-eabi-gcc -march=armv7-a -mtune=cortex-a9
    -mfpu=neon -mfloat-abi=hard`.
  - Then `arm-vita-eabi-objcopy --remove-section .ARM.attributes
    --redefine-syms=matchbox\vito\libm\redefine.syms` on each object. (This
    differs from the 3DS script: the Vita **removes** the ABI attributes so
    `ld` accepts the soft-float objects, while the 3DS appends
    `.eabi_attribute 28, 1`.)
  - Compile a Vita `main.c` shim (the same 3 lines as the 3DS one; keep it in a
    `vita/` folder so it doesn't clash with the root `main.c`), plus the
    bridges: `matchbox\vito\libm\bridge.c` and `matchbox\vito\sce\bridge.c`
    (`-O2`).
  - Link with `-Wl,-q -Wl,--defsym,__sce_headroom=0x10000` and the stubs the
    template lists (`SceDisplay`, `SceGxm`, `SceSysmodule`, `SceCtrl`,
    `SceTouch`, `SceMotion`, `SceKernelThreadMgr`, `SceIofilemgr`, `SceAudio`,
    `ScePgf`, `ScePvf`, `SceCommonDialog`, `SceAppMgr`, `SceAppUtil`,
    `ScePower`, `SceSysmem`, `SceLibKernel`, plus `-lpng16 -lz -lm`).
  - Package: `vita-elf-create`, `vita-make-fself -c`, `vita-mksfoex` (needs a
    9-character `TITLE_ID`, 4 letters + 5 digits), `vita-pack-vpk` with
    `-a assets=assets` for the shared assets folder.
  - It needs VitaSDK at `C:\vitasdk` (or `VITASDK` set) on `PATH`.
- Done when: `3ds_check.bat` and `vita_check.bat` both pass; `3ds_build.bat`
  still produces a working `.3dsx`; `vita_build.bat` produces a `.vpk` for an
  empty `main` that prints through `mb.print` and runs in Vita3K (or on
  hardware) without a crash; and `arm-vita-eabi-nm -u` on the Vita Odin object
  shows only `vito_*` for float maths (the same check as the 3DS's).

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

Helpers: `camera_view_matrix(cam)`, `camera_projection_gl(cam, aspect)` (shared,
OpenGL clip space; each backend adapts the depth range) and
`camera_create_2d(view_height)`, which returns an ortho camera at z = +10
looking down -Z.

Public API: `camera_start(cam)` / `camera_end()`, called between `render_start`
and `render_end`. The game never builds a projection matrix or computes the
aspect; the backend does. Picking helpers come later: `world_to_screen`,
`get_mouse_ray(cam)`, `get_mouse_world_pos(cam)` (F2) and `camera_update`
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
- Shared `camera.odin`: `Projection`, `Camera`, `camera_view_matrix`,
  `camera_projection_gl`, `camera_create_2d` (see A3).
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
is two persistent `[dynamic]Draw_Item` arrays in `mbi` (opaque and
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
Citra and on real hardware. (C0 first deletes the old 2D sprite and triangle
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
- The queue's sorting and batching are shared (B7). The Vita executes it:
  - Quads: the CPU-transformed vertices go into a **ring of three** GPU
    buffers (one per display buffer) so a frame in flight is never overwritten.
    `vito/gfx/draw2d.odin` is a working example of exactly this (`push_quad`,
    `flush_2d`, `draw2d_next_frame`); lift its buffer handling, not its pixel
    maths.
  - Meshes use their own buffers and the per-draw uniforms.
- The queue and its sort scratch stay in `context.temp_allocator`; only the
  quad vertices are copied into GPU memory each frame.
- Done when: the Phase B scene (spinning textured cube, half-transparent quad
  passing through it) renders on the Vita.

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

**D1. `Texture` as its own resource.**
- `create_texture(filename) -> Texture` and `destroy_texture`.
- A filter per texture: point or linear. This is the old roadmap item 1.5.
- 3DS: keep the heap-allocated `^c3d.Tex`, because the address must stay
  stable.

**D2. Sidecar metadata.**
- A small text file next to an image: `name.meta` with `ppu`, `columns`,
  `rows`.
- Missing means PPU 1 and one frame.
- 3DS: the build copies `.meta` files into romfs next to the `.t3x`.
- Vita: `assets/` is packed into the `.vpk` as `app0:/assets/...`, so the PNG
  and its `.meta` travel together. The Vita uses the full-size shared sheet
  (textures up to 4096px), so it needs no third output.

**D3. Sheet-packing tool** (in `tools/`, like `tritex`).
- Packs a folder of frames (natural sort) into one grid PNG and writes the
  `.meta`.
- With a flag, also writes a downscaled copy into `assets/3ds/images/`.
- Done when: shia-test's 169 256px frames become a PC sheet (13x13, 3328px)
  and a 3DS sheet at 64px (832px, which fits in 1024).

**D4. Subfolder asset names on the 3DS** (the Vita keeps real paths, so only
the 3DS flattening matters). The build flattens files to their
basename, while `get_asset` uses the relative path. Pick one rule and apply it
in both `3ds_build.bat` and `get_asset`.

---

## Phase E: 2D as a projection (2D milestone, part 1)

**E1. New `Sprite`.**
- A texture, a frame index (or an internal source rect), and
  `position: [3]f32`. 2D helpers set x and y; z is the layer.
- `rotation` (radians, about Z), `scale`, `tint`, `flip_x`, `flip_y`, `pivot`.
- The world size is `frame_px / ppu * scale`.
- `render_sprite` pushes a quad into the queue.
- On the 3DS, citro2d is no longer used for sprites.

**E2. 2D camera.**
- `camera_create_2d(view_height)` with `position.xy` and `zoom`, where zoom
  scales `view_height`.
- Port `camera_follow` and `get_mouse_world_pos` from main, adapted to the
  camera.

**E3. Layers and sorting rule** (write this down in the docs).
- Opaque and cut-out sprites use depth.
- Semi-transparent sprites sort by z, then by submission order.
- Cut-out means the shader does `discard` below alpha 0.5. The 3DS uses the
  PICA alpha test (`C3D_AlphaTest`).
- Recommend cut-out as the default for sprites, because it is cheap and
  sort-free.

**E4. Shapes as world geometry.**
- `render_triangle`, `render_rectangle`, `render_line` (thickness in units)
  and `render_circle` produce quads or triangles into the queue.
- Delete the pixel-space `render_triangle_points`.

**E5. Pixel snapping** (ortho only, opt-in).
- Snap the camera position and quad corners to whole screen pixels at the
  current scale.
- Combined with `integer_scale`, this gives clean pixel art at 4x and 2x.

**E6. Animation port.**
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
- Leave out `offset`, `replay`, progress, frame-passed and `sprite_set_frame`.

**E7. Acceptance test: port shia-test.**
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
Draw  :: struct { model: matrix[4, 4]f32, tint, uv_rect: [4]f32, alpha_cutoff: f32 }

@(uniform = 0) frame: Frame
@(uniform = 1) draw:  Draw
@(texture = 0) tex:   Texture2D

vertex_main :: proc(in: Vertex_In) -> Varying {
	out: Varying
	world := draw.model * [4]f32{in.position.x, in.position.y, in.position.z, 1}
	out.position = frame.view_projection * world
	out.color = in.color * draw.tint
	out.uv = lerp(draw.uv_rect.xy, draw.uv_rect.zw, in.uv)
	return out
}

fragment_main :: proc(v: Varying) -> [4]f32 {
	color := sample(tex, v.uv) * v.color
	if color.a < draw.alpha_cutoff do discard()
	return color
}
```

On the 3DS the `discard` becomes the PICA alpha test state (see E3), and the
fragment multiply becomes one TexEnv stage.

Per-target variants use Odin's own `when TARGET == .PICA { ... } else { ... }`,
so a shader can provide a fallback where a target can't do something.

**Where it runs.** A build-time tool, `tools/shaderc.odin` (like `tritex`),
not code in the game. Inputs: a shader file and `-target`. Outputs:
- PC: `name.hlsl`
- Vita: `name_v.cg` and `name_f.cg`, then runs `psp2cgc` if `tools/psp2cgc.exe`
  exists; otherwise the committed `.gxp` is used (vito's rule, kept)
- 3DS: `name.v.pica` then `picasso` -> `.shbin`, plus a TexEnv table
  (`name.tev`) for the fragment stage
- All: a small reflection file listing the attributes, uniforms and textures
  each stage actually uses (Vita removes unused ones; the 3DS assigns registers)

**S0. Specify the language** (write `docs/shader_language.md`).
- Types, built-in functions, entry points, uniforms and textures, and a table
  of what compiles on which target. Settle the decisions below first.
- Done when: the draft above is a complete spec, and every built-in is marked
  PC / Vita / 3DS.

**S1. Front end** (`tools/shaderc.odin`).
- Parse the shader (try `core:odin/parser` first), type-check the subset,
  build an intermediate form, report errors with file and line.
- Done when: the draft above parses and type-checks, and a deliberate mistake
  gives a clear message. Golden-file tests.

**S2. PC backend: HLSL.**
- Emit HLSL from the intermediate form. Port `mesh.hlsl` to the language.
- Done when: the demo looks identical with the generated HLSL, including the
  alpha cut-off and the `uv_rect` sprites.

**S3. Bindings and reflection.**
- Engine-owned slots (`frame`, `draw`) bind the same way on every target, and
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
- The `when TARGET` blocks, per-target errors, and `shaderc --check` that
  reports what compiles where.

**S8. Later, only if needed:** write `.gxp` directly (vito's
`docs/gxp-format.md` has a staged plan: disassemble, assemble, a small
subset, then widen) or `.shbin` directly, to drop `psp2cgc` or `picasso`.

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

**F1. HUD camera.**
- `screen_start()` / `screen_end()` (a second orthographic camera, same
  `_start` / `_end` naming as `camera_start`) switch the queue to screen space
  in design units, with depth off.
- Add `get_visible_rect()` and `anchor_position(anchor, offset)`.
- Choose the default fit policy here, and the overscan cap value.

**F2. Text.**
- Rasterise glyphs at final pixel size into a texture atlas, drawn as quads.
- PC: `stb_truetype` (vendor) to bake the atlas.
- 3DS: the system font (`fontGetSystemFont`, which is what citro2d text uses),
  or a pre-baked atlas built with the asset tools.
- Vita: the same baked atlas (the Vita has its own `vita2d`/`gfx` text, but
  it is pixel-space and doesn't use the camera).
- Decide which before starting. The pre-baked atlas is identical on all three
  targets, which is the argument for it.

**F3. Input to world.**
- Mouse: invert the fit and camera.
  - Ortho: a direct inverse.
  - Perspective: a ray from the camera.
- Points in the bars report as outside.
- 3DS touch maps to the bottom screen's camera (F4).
- Vita front touch (and the rear panel) report in the panel's own coordinate
  range, not screen pixels; scale them to 960x544 first, then treat as mouse.
  Check the range on hardware.

**F4. 3DS bottom screen** as a second surface (320x240) with its own camera.
- On PC: render it stacked below the top screen, as an overlay, or not at all.
  The game chooses.
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
| 3DS `Renderer` enum, `use_renderer`, `finish_renderer` | Render queue | C4 |
| 3DS hand-built pixel projection rows | `Mtx_OrthoTilt` / `Mtx_PerspTilt` | C0 |
| 3DS `vshader.shbin` without source | `vshader.v.pica` + picasso step | C0 |
| `Sprite.x/y` (pixels), `width/height`, pixel `source` | `position: [3]f32`, frame index, PPU | E1 |
| citro2d sprite drawing (`DrawImageAtRotated`, sub-texture maths) | Quads in the queue | E1 |
| `render_triangle_points` (pixel-space) | World-space shapes | E4 |
| `get_window_size()` as the game's coordinate space | `get_visible_rect()` + camera | F1 |
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
- [ ] Shader language syntax (S0): an Odin subset parsed with `core:odin/parser` (recommended), or a small custom parser.
- [ ] Shader file extension and location (S0), for example `matchbox/shaders/*.shader`.
- [ ] 3DS fragment policy (S0): portable subset that maps to TexEnv, with a compile error for anything else (recommended).
- [ ] Generated shader output (S2 to S6): commit it, or generate at build. Vita `.gxp` stays committed (vito's rule, 2026-11-13).
- [ ] Vita emulator: Vita3K vs hardware as the per-step check (decide before V0).
- [ ] Vita MSAA: off, or 4x (decide at V8).
- [ ] Design aspect: all three screens have different shapes (400x240, 960x544, any PC window); pick the default design aspect and fit policy together (F1).
- [ ] Sprite pivot convention (recommended: `{0.5, 0.5}` = centre).
- [ ] Sprites default to cut-out or blended (recommended: cut-out).
- [ ] Default fit policy and the overscan cap (at F1).
- [ ] Text approach on the 3DS (before E1).
- [ ] Bottom screen on PC (at F4).
