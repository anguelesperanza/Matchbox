# Matchbox: 3D-first rendering plan

Status: proposed 2026-11-12, branch `full-rewrite`. Updated 2026-11-12 with
the A1 results (3DS float maths) and Phase I (hard-float, later).
Targets now: PC (D3D11) and 3DS (citro3d). Vita: after 3D is done (see Phase H).

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

- Input, audio, events, logger, the asset lookup (`get_asset`) and `build.bat`.
  `build.bat` gains a shader step in Phase C.
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
  - Float arguments to C go through bridges, and so does any libm call
    (`sinf`, `cosf`, `fmaf`, ...). See "3DS float rules" below.
  - The framebuffer is portrait, so x and y swap.

## 3DS float rules (until Phase I)

Odin calls C with the soft-float convention (floats in `r` registers), while
devkitARM's libraries are hard-float (floats in `s` registers). A mismatched
call links fine and returns garbage. The build now uses `-microarch:mpcore`
(done 2026-11-12, runs in the emulator), so Odin's own float maths uses the
hardware FPU; only calls *into C* are affected.

- **Never use `*` on Odin `matrix` types in code that runs on the 3DS.** It
  lowers to libm `fmaf` (64 calls per 4x4 multiply). The same goes for
  `core:math/linalg` procs that multiply matrices. Use the hand-written procs
  from A1.
- **Never call `math.sin`, `cos`, `tan`, `atan2`, `pow`** etc. on the 3DS. They
  become libm calls. Use the bridged versions from A1. (`math.sqrt` is fine
  with `mpcore`: it becomes the `vsqrt` instruction.)
- **Plain arithmetic is fine:** `+ - * /`, comparisons, `min`/`max`, `abs`, and
  loops over `[N]f32` all compile to VFP instructions.
- **Check:** after a 3DS build, `odin_asm/*.s` must contain no `bl fmaf`,
  `bl sinf`, `bl cosf`, `bl tanf` or `bl __*sf3`. Worth adding as a
  `findstr` step in `build.bat` that fails the build.

## Conventions (decide before Phase A ends)

These shape every matrix written afterwards, so settle them once and write
them at the top of the shared math file.

| Item | Recommendation | Why |
|---|---|---|
| Handedness and up | Right-handed, **+Y up**, camera looks down **-Z** | Matches glTF, which main already loads, and most 3D tutorials. |
| 2D y direction | Also +Y up | One world, one rule. Unity, Bevy and Godot 3D do this. 2D code written y-down needs flipping (demo, shia-test). |
| Angles | Radians | Already the case in `render_sprite`. |
| Matrix layout | Store as Odin `matrix[4,4]f32` (column-major, column vectors), but multiply only through `mat4_mul` / `mat4_mul_vec4` | Odin's native layout, uploadable as-is. The `*` operator is off-limits on the 3DS (see 3DS float rules). Watch HLSL packing in B4. |
| Depth range | Per backend | D3D uses 0..1. citro3d's own helpers build its range. Shared code describes the camera, and each backend builds the projection matrix. |
| Units | 3D: 1 unit = 1 metre. 2D: the game picks its ortho view height. With PPU 1, one unit is one art pixel at 1x. | Keeps 2D numbers familiar. |
| Sprite pivot | `{0.5, 0.5}` = centre is the position | Opposite of main. Main's comment calls its own convention surprising. |

## Milestones (replaces README "Milestones")

```
[x] POC
[-] Renderer core: 3D pipeline on PC and 3DS       (Phases A, B, C)
[ ] 2D: 2D as an orthographic projection           (Phases D, E, F)
[ ] 3D: 3D games                                   (Phase G)
[ ] Improved build system                          (shader step lands in Phase C)
[ ] Vita target                                    (Phase H, after 3D)
[ ] 3DS hard-float (performance)                   (Phase I, via Farlite, late)
```

2D can't come first, because it is built on the 3D pipeline. The 2D milestone
still comes before 3D games, because it needs only the core, not lighting,
models or skinning.

## How to work through it

- **PC first, then the same step on the 3DS before moving on.** Don't let the
  3DS fall more than one step behind; the bugs found so far all came from
  differences between the targets.
- **Keep the demo running.**
  - The new path is added beside the old one (`render_mesh` beside
    `render_sprite`).
  - Each old piece is removed only when its replacement works on both targets.
  - See the removal checklist at the end.
- **Pure maths in shared files, with tests.**
  - Files have no target suffix, and `odin test` runs on PC.
  - Main's `display_test.odin` is the model.
- **Every step has a "done when".** Don't start the next step until it is met
  on both targets (Citra for the 3DS; real hardware at the end of each phase).

---

## Phase A: shared foundations (no rendering changes)

**A1. Shared maths file.** Investigated 2026-11-12: `core:math/linalg`
compiles and links for the 3DS but gives wrong results there (see "3DS float
rules"). The FPU part is done: `build.bat` uses `-microarch:mpcore`.
Remaining:
- [x] **Trig bridge** (done 2026-11-12, pushed). `o3dx/c3d` now has
  `c3d.sinf`, `cosf`, `tanf`, `asinf`, `acosf`, `atanf`, `atan2f`, `powf`,
  `fmodf`, `sqrtf` and `sincosf`, declared `u32` on the C side. Not yet
  checked for values on the emulator.
- **`math.odin` in `matchbox/`** (shared, no target suffix), with
  target-specific `sin`/`cos`/`tan`/`atan2`/`sincos` in `math_windows.odin`
  (calls `core:math`) and `math_3ds_freestanding_arm32.odin` (calls the
  `c3d.*f` wrappers).
- **Procs to write by hand:** `mat4_identity`, `mat4_mul`, `mat4_mul_vec4`,
  `mat4_translate`, `mat4_scale`, `mat4_from_quat`, `mat4_inverse`,
  `mat4_ortho`, `mat4_perspective`, `mat4_look_at`, `quat_angle_axis`,
  `quat_mul`, `quat_normalize`, `quat_rotate_vec3`, plus `vec3` `dot`,
  `cross`, `normalize`, `length`. Write `mat4_mul` as explicit loops over
  indices, never `a * b`.
- **Tests** in `math_test.odin` on PC: compare each hand-written proc against
  `core:math/linalg` (allowed on PC) within a small epsilon. That gives
  correctness for free.
- Write the conventions table (right-handed, +Y up, -Z forward, radians,
  column-major) as a comment at the top of `math.odin`.
- Done when: the tests pass on PC, the 3DS build passes the "no libm calls"
  check above, and a 3DS test that prints `sin(PI/2)` and a rotated vector
  shows the right numbers in Citra.

**A2. `Transform`** (shared): `position: [3]f32`, `rotation: quaternion128`,
`scale: [3]f32`, plus `transform_matrix(t) -> matrix[4,4]f32`, built with the
A1 procs (translate × rotate × scale).
- Odin's built-in quaternion `*` may also lower to `fmaf`; use `quat_mul`
  from A1 unless the 3DS check shows it is clean.
- Done when: tests cover identity, translate-only and rotate-then-translate
  order.

**A3. `Camera`** (shared, description only):
- `projection: enum {PERSPECTIVE, ORTHOGRAPHIC}`
- `position`, `rotation` (or `target`)
- `fov_y` (perspective), `view_height` (orthographic), `near`, `far`
- `fit: Fit_Policy`, `integer_scale: bool`, `overscan_cap: f32`

Helpers: `camera_view_matrix(cam)` and `camera_create_2d(view_height)`, which
returns an ortho camera at z = +10 looking down -Z.
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
  - ultrawide with a 10% cap: partial bars

**A5. Projection description per backend:** `camera_projection_params(cam,
viewport)` returns what a backend needs (fov, aspect, near, far, or ortho
extents). Backends build the actual matrix:
- PC: D3D 0..1 depth.
- 3DS: `Mtx_PerspTilt` / `Mtx_OrthoTilt`, which handle the rotated
  framebuffer. `o3dx/c3d/bridge.c` already bridges the projection functions;
  check the Odin declarations pass `u32` (see A1).

---

## Phase B: PC 3D core (D3D11)

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
  return vertex and index arrays only, with no GPU work.

**B7. Render queue** (shared logic, backend execution). This replaces the
immediate batch.
- `render_mesh(mesh, transform, texture, tint)` and later `render_sprite(...)`
  push items, and `render_end` sorts and draws them:
  - **Opaque and cut-out:** sorted by texture, then mesh, to reduce state
    changes. Drawn first with depth write.
  - **Transparent:** sorted back to front by view-space depth, stable for
    equal depth. Drawn after, without depth write.
- Quads (sprites, shapes) are pre-transformed on the CPU into one dynamic
  vertex buffer per texture run, with `model = identity`.
- Meshes use their own buffers and the per-draw cbuffer.

**B8. Viewport and scissor from A4.**
- `RSSetViewports` and `RSSetScissorRects` from the fit result.
- Clear the full window to the bar colour first, then the content.

**Phase B done when:** a textured, spinning cube is drawn with a perspective
camera, plus a half-transparent quad passing through it. Resizing keeps the
aspect, letterbox and expand both behave as in the mockups, and the old 2D demo
still draws.

---

## Phase C: 3DS 3D core (citro3d)

**C0. Shader toolchain.**
- Only `romfs/vshader.shbin` (a compiled binary) is in the repo; its source
  isn't.
- Add `matchbox/shaders/vshader.v.pica`.
- Add a step to `build.bat` that runs `picasso` (part of devkitPro) on it and
  outputs to `romfs/`.
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
Citra and on real hardware, and the old 2D demo still draws.

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

**D3. Sheet-packing tool** (in `tools/`, like `tritex`).
- Packs a folder of frames (natural sort) into one grid PNG and writes the
  `.meta`.
- With a flag, also writes a downscaled copy into `assets/3ds/images/`.
- Done when: shia-test's 169 256px frames become a PC sheet (13x13, 3328px)
  and a 3DS sheet at 64px (832px, which fits in 1024).

**D4. Subfolder asset names on the 3DS.** The build flattens files to their
basename, while `get_asset` uses the relative path. Pick one rule and apply it
in both `build.bat` and `get_asset`.

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

**Phase E done when:** a 2D test scene (the mockup scene) looks the same on PC
and the 3DS under letterbox, and shia-test plays on PC.

---

## Phase F: screen space, text, input (2D milestone, part 2)

**F1. HUD camera.**
- `begin_screen()` / `end_screen()` switch the queue to a screen ortho camera
  in design units, with depth off.
- Add `get_visible_rect()` and `anchor_position(anchor, offset)`.
- Choose the default fit policy here, and the overscan cap value.

**F2. Text.**
- Rasterise glyphs at final pixel size into a texture atlas, drawn as quads.
- PC: `stb_truetype` (vendor) to bake the atlas.
- 3DS: the system font (`fontGetSystemFont`, which is what citro2d text uses),
  or a pre-baked atlas built with the asset tools.
- Decide which before starting. The pre-baked atlas is identical on both
  targets.

**F3. Input to world.**
- Mouse: invert the fit and camera.
  - Ortho: a direct inverse.
  - Perspective: a ray from the camera.
- Points in the bars report as outside.
- 3DS touch maps to the bottom screen's camera (F4).

**F4. 3DS bottom screen** as a second surface (320x240) with its own camera.
- On PC: render it stacked below the top screen, as an overlay, or not at all.
  The game chooses.
- Leave Vita behaviour until Phase H.

**2D milestone done when:**
- shia-test runs on PC and the 3DS (positions tuned for the 3DS).
- A HUD stays anchored under every fit policy.
- Text is crisp on both targets.

---

## Phase G: 3D games (3D milestone)

**G1. Models.**
- glTF on PC: port main's `gltf2` parsing, but not its GPU code.
- 3DS: a **build-time** converter from glTF to a compact binary
  (positions/uv/normals/indices, 16-bit indices, textures through tritex). No
  JSON parsing on the device.

**G2. Lighting.**
- Directional plus ambient to start. Add `normal` to the vertex format.
- PC: per-pixel in HLSL.
- 3DS: PICA hardware fragment lighting (`C3D_LightEnv`, `C3D_Light`) or
  per-vertex in the shader.
- Keep the shared API to what the 3DS can do. Anything PC-only is marked as
  such.

**G3. 3D cameras.** Port main's first-person, third-person and orbit helpers
onto `Camera`.

**G4. Billboards.** Sprites facing the camera in a perspective scene; they
reuse E1.

**G5. Render targets.**
- Render to a texture: `C3D_RenderTargetCreateFromTex` on the 3DS, an RTV plus
  shader resource view (SRV) on PC.
- This also enables an opt-in pixel-perfect 2D mode: render at the design size,
  then upscale.

**G6. Skinned animation** (late).
- Port main's animator logic.
- 3DS skinning on the CPU, or in the vertex shader with a small bone limit.
  Measure before choosing.

**3D milestone done when:** a small third-person scene (a model, lighting, a
camera rig, and a HUD) runs on PC and the 3DS.

---

## Phase H: Vita (after 3D)

- 3D needs the Vita GPU (GXM) directly. vita2d has no camera or depth, so it
  can't run this renderer.
- Prerequisites in vito:
  - `sceGxm` bindings
  - display queue
  - memory blocks
  - a way to compile shaders to `.gxp`
- **Research the shader compiler's availability first.** It decides whether
  this phase is feasible.
- Fit: 960x544 is just another surface for A4, so nothing new is needed.
- Touch: the front panel's coordinate range differs from the screen pixels.
  Check on hardware and map it in F3's input code.

---

## Phase I: hard-float on the 3DS (later: when performance is the focus)

Not part of the main milestones. Do it after the main parts of Matchbox are
complete, when performance becomes the next concern.

**Why:** with soft-float calls, every float crossing into C goes through a
bridge, matrix and trig maths need hand-written or bridged versions, and
citro3d's own optimised maths can't be called directly.

**Root cause (found 2026-11-12):** Odin dev-2026-11 already has hard-float
(AAPCS-VFP) argument lowering for arm32, float structs included. But it emits
the target triple `arm-none-eabihf` without normalising it, so LLVM appears
to fall back to soft-float. That's also why `build.bat` appends
`.eabi_attribute 28, 1` by hand.

**Plan:** Farlite installs an Odin compiler built with the fix, so the
`freestanding_arm32` target really is hard-float. Then:
1. Confirm with a small test that `proc(a: f32, b: f32)` passes `b` in `s1`
   and that the object is tagged "VFP registers"
   (`arm-none-eabi-readelf -A`).
2. Remove the `.eabi_attribute 28, 1` append from `build.bat`.
3. **In the same change**, rework every o3dx binding with float parameters:
   - Real functions in citro2d/citro3d/libctru: declare them directly with
     `f32`, drop the `link_name`, delete the bridge.
   - `static inline` header functions: rewrite in Odin, or keep a plain C
     wrapper with `float` parameters and no `u2f`/`f2u`.
   - Bridges whose Odin declaration already uses `u32` keep working, so they
     can go later.
4. Drop the "3DS float rules": `core:math`, `linalg` and the matrix `*`
   operator become correct, though `fmaf` stays a slow library call on VFPv2.
   Keep `mat4_mul` for speed.
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
| `u2f`/`f2u` bridges, `.eabi_attribute 28, 1` append, 3DS float rules | Hard-float Odin from Farlite | Phase I |

## Risks to watch

1. **Silent libm calls on the 3DS** (A1 onward): any `matrix *`, `linalg`
   or `math.sin` that slips into 3DS code builds fine and returns garbage.
   The build check in "3DS float rules" is what catches it.
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

## Decisions to make (and record here with dates)

- [x] Up axis and handedness: right-handed, +Y up, camera looks down -Z, everywhere including 2D (decided 2026-11-12). Screen/HUD pixel space stays top-left, y-down.
- [x] 3DS FPU: `-microarch:mpcore` in `build.bat` (2026-11-12, runs in the emulator).
- [x] 3DS float calls: stay soft-float with bridges for now; hard-float via a Farlite-built Odin in Phase I (2026-11-12).
- [ ] Sprite pivot convention (recommended: `{0.5, 0.5}` = centre).
- [ ] Sprites default to cut-out or blended (recommended: cut-out).
- [ ] Default fit policy and the overscan cap (at F1).
- [ ] Text approach on the 3DS (before E1).
- [ ] Bottom screen on PC (at F4).
