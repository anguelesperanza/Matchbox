# G5: render targets and internal resolution (plan)

Written 2026-11-26. Status: **API approved 2026-11-26 with one change (`no_depth` replaces `depth`); implemented and checked on PC, Azahar and Vita3K; hardware builds are waiting for the user's check.**
Source of truth for the phase: `render_plan.md`, "G5. Render targets", and the open item "Render resolution as a performance lever"
(the Vita's per-pixel lighting runs at about 30 fps and is accepted; the next gain is drawing fewer pixels).
Camera conventions are `docs/g3_cameras_plan.md`'s (world units, +Y up). The plan format and check pattern are `docs/g4_billboards_plan.md`'s.

## What this branch has now

Every target has exactly one thing to draw into per screen, set up once at `init`, and the shared code never names it.

| | Frame start | What `camera_start` sizes the view by | What `camera_end` draws into | Depth buffer |
|---|---|---|---|---|
| PC (`render_windows.odin`) | `render_start` binds `mbi.framebuffer_view` and `mbi.depth_view`, sets one viewport of `mbi.window_size`, clears depth | `mbi.window_size[0..1]` | the bound framebuffer | a `D32_FLOAT` texture the size of the swapchain, remade on resize |
| 3DS (`render_3ds_...`, `bottom_screen_3ds_...`, `window_3ds_...`) | `C3D_FrameBegin`, `C3D_FrameDrawOn(mbi.top_screen)` | `window_size[0..1]` (400x240), or `[2..3]` (320x240) while `drawing_bottom_screen` | the citro3d target last passed to `C3D_FrameDrawOn`; `bottom_screen_target_start/_end` switch it | citro3d's, made with each screen target; both screens are `RenderTargetCreate` objects linked to the LCDs by `C3D_RenderTargetSetOutput` |
| Vita (`render_vita_...`, `vito/gfx`) | `gfx.begin_frame` = `sceGxmBeginScene` on the display surface straight away | `window_size[0..1]` (960x544) | the one scene | `gfx`'s depth surface; the screen is not multisampled in Matchbox (`gfx.init()` with no config) |

Shared facts that matter here:

- `camera_start` (each backend) reads the **window** size three ways: the projection's aspect, `mbi.camera_window_height` (billboards'
  `screen_size`) and `calculate_camera_snap_scale` (`pixel_snap`). The shared helpers `calculate_window_aspect` (`screen.odin`),
  `calculate_visible_rectangle` and `calculate_anchor_position` read `mbi.window_size` through it.
- The 3DS projection carries `TILT_TO_PANEL`: the LCD is mounted sideways, so the top screen's framebuffer is 240 wide and 400 tall.
  That tilt belongs to the *screens*; a texture target has no panel.
- A 3DS texture is a power-of-two canvas (8 to 1024 a side) with the image in its top-left corner, upside down in PICA terms;
  `calculate_canvas_uv_rectangle` (`texture_3ds_...`) maps the shared uv space onto it. Rendered content must land in the same corner
  or every sprite and model would need a second uv rule.
- `Texture` is `{using backend:Backend_Texture, filter, width, height, ppu, frames...}`. PC: `texture` + `view` (an SRV). 3DS: `^C3D_Tex`.
  Vita: `^gfx.Texture`. `destroy_texture` frees the GPU object once for every copy.
- `mbi.discard_pass` already drops whole passes the target cannot show; a render target pass is a new kind of destination, not a new
  kind of pass.
- Input is in window pixels (mouse, stylus, Vita touch). `calculate_mouse_world_position(camera)` converts through the window size.
- PC's `Depth_Mode`, blend and sampler states are created once and are independent of the destination, so they work inside a target
  unchanged. PC's swapchain is `B8G8R8A8_UNORM_SRGB`; the viewport and states are the only per-frame setup.

## What `main` has

`main:matchbox/render_target.odin` (SDL3_GPU): `Render_Target{texture, depth, width, height}`, `create_render_target(width = 0, height = 0)`
(0 means the window's size), `destroy_render_target`, `begin_drawing_target(&target)` / `end_drawing_target()`, `draw_render_target(target, dest)`
(a quad into a rectangle) and `draw_post` (a shader effect over the target). Rules it states, which carry over:
- the target has **its own depth buffer**, since a depth buffer must match its colour buffer's size;
- it does **not** follow a window resize: the game destroys and recreates it (fixed resolution is usually the point);
- **targets do not nest**, one at a time;
- inside, everything works as outside: `clear_background`, 3D, sprites, text; what changes is where pixels land and what the screen
  size reports;
- no flip: SDL3_GPU is top-down like the swapchain.
Examples `post`, `viewport` use it. `draw_post`, tonemapping and the SSAO/shadow code that read a target's depth are `main`'s lighting rework
and not part of G5 (no post effects in this phase).

Port: the type, the create/destroy pair, begin/end, the "no nesting, no auto-resize, own depth" rules. New here: the handhelds, the upscale, input.

## Proposed public API (needs the user's approval)

New files: `matchbox/render_target.odin` (shared: types, settings, the maths, the draw-into rules; no GPU code) plus
`render_target_windows.odin`, `render_target_3ds_freestanding_arm32.odin`, `render_target_vita_freestanding_arm32.odin` and
`render_target_test.odin`. `Backend_Render_Target` joins each `backend_<target>.odin`.

```odin
Render_Target_Settings :: struct {
	width:i32,           // pixels. 0 with height 0 = the size of the screen it is drawn for (the window; the 3DS top screen)
	height:i32,
	scale:f32,           // only when width and height are 0: the screen's size times this. 0.5 = a quarter of the pixels. 0 means 1
	filter:Filter_Mode,  // how it is sampled when drawn bigger. POINT (the zero value) is pixel-perfect; LINEAR smooths
	no_depth:bool,       // a bare {width, height} has a depth buffer, for 3D. A 2D-only target opts out and saves the memory (the 3DS has 6 MB of VRAM)
}

Render_Target :: struct {
	using backend:Backend_Render_Target, // colour/depth GPU objects, which differ per target
	texture:Texture,     // the colour, readable as any texture: render_sprite, a model's texture, render_mesh
	width:i32,           // the size the game asked for (on the 3DS the GPU object is padded up; see per-target notes)
	height:i32,
	has_depth:bool,
}

Fit_Mode :: enum {
	FIT,      // the whole picture, aspect kept, bars at the sides or top: the default
	INTEGER,  // the largest whole-number multiple that fits, centred: pixel-perfect, never blurry (bars if it does not divide)
	FILL,     // aspect kept, covers the whole screen, the overflow cropped
	STRETCH,  // the whole screen, aspect ignored
}

// Makes a target. Nothing is drawn into it until render_target_start. destroy(&target) frees it
create_render_target :: proc(settings := Render_Target_Settings{}) -> Render_Target
destroy_render_target :: proc(target:^Render_Target)               // joins the `destroy` group

// Everything drawn between these goes into the target: camera_start ... camera_end, screen_start ... screen_end, text, as usual.
// Cameras, anchors and the HUD are sized by the target while it is active, so a 320x180 target has a 320x180 view.
// Clears colour (and depth) to `clear_color` on entry; pass nil to keep what was drawn before
render_target_start :: proc(target:^Render_Target, clear_color:Maybe([4]f32) = [4]f32{0, 0, 0, 0})
render_target_end :: proc()

// Draws the target over the screen being drawn, between render_start and render_end, outside render_target_start/_end.
// It is a pass of its own (no camera needed): the target scaled by `fit`, bars left as they are
render_upscaled_target :: proc(target:Render_Target, fit := Fit_Mode.FIT, tint := [4]f32{1, 1, 1, 1})

// Where the picture lands on the screen, in screen pixels (top-left origin, y down): for placing a HUD around it
calculate_upscaled_rectangle :: proc(target:Render_Target, fit := Fit_Mode.FIT) -> (min, max:[2]f32)

// A window pixel (the mouse, a touch) -> a target pixel (top-left origin, y down). Outside the picture the result is outside 0..size.
// `calculate_screen_to_world_2d(camera, result, size_of_target)` takes it the rest of the way to world units
calculate_target_position :: proc(target:Render_Target, window_position:[2]f32, fit := Fit_Mode.FIT) -> [2]f32
```

Using it:

```odin
scene := mb.create_render_target({width = 480, height = 272})     // half the Vita's pixels in each direction
defer mb.destroy(&scene)

for mb.is_running() {
	mb.render_start()
	mb.render_target_start(&scene, mb.SKY_BLUE)        // all targets first (see "Frame order")
		mb.camera_start(camera); /* models, billboards, sprites */ mb.camera_end()
	mb.render_target_end()

	mb.clear_background(mb.BLACK)
	mb.render_upscaled_target(scene, .INTEGER)          // or: mb.render_sprite(mb.create_sprite(scene.texture)) for anything fancier
	mb.screen_start(); /* the HUD at full resolution: text stays crisp */ mb.screen_end()
	mb.render_end()
}
```

`render_start`/`render_end`, `camera_*`, `screen_*` and `bottom_screen_*` are unchanged and keep every existing game working. No new
package constants or globals (the settings default is a literal); the one new `mbi` field group is `mbi.render_target_state` (the active
target, whether the screen has been drawn into this frame, the saved screen viewport on PC).

### Decisions the proposal makes

1. **Frame order, one rule on all three targets: draw every render target first, then the screen.** The Vita cannot nest or interleave
   GXM scenes (vito's own note: "draw into targets first, then `begin_frame` for the screen"), while PC and 3DS could. A game that
   worked on PC and failed on the Vita would be the worst outcome, so Matchbox enforces the Vita's order everywhere
   (`ensure` in `render_target_start` that nothing has been drawn to the screen this frame). On the Vita `render_start` stops opening the
   screen scene itself: the scene opens at the first screen draw (`camera_end` or `clear_background` on the screen) or at `render_end`.
   A frame with no target behaves exactly as today.
2. **A target is a texture, not a special thing.** `target.texture` is an ordinary `Texture` (same fields, `filter`, `pixels_per_unit` = 1),
   so sprites, models and `render_mesh` use it through the paths they already have. `render_upscaled_target` is the convenience, not the
   only way. `destroy_texture` on it is a mistake the doc comment warns about; `destroy` on the `Render_Target` is the one way.
3. **While a target is active, "the window" is the target.** One shared `get_draw_size()` (target size or `window_size`/the 3DS screen) feeds
   the aspect, `camera_window_height`, `pixel_snap` and the anchors. So `screen_start()` inside `render_target_start` lays a HUD out in the
   target's pixels (a chunky pixel-art HUD), and after `render_target_end` the same call lays it out in screen pixels (a crisp one).
   The game picks per HUD by where it puts the call. `calculate_visible_rectangle()` follows the same rule, so it answers for whichever is active.
4. **The target size is the game's, not the window's.** It does not follow a resize (as on `main`). `scale` exists for the common case
   ("half resolution"): worked out once at creation from the screen's size; a game that wants it to follow a resize destroys and recreates it.
5. **Pixel-perfect is `POINT` + `INTEGER`.** `INTEGER` picks `floor(min(sw/w, sh/h))` (at least 1) so every target pixel is a whole number of
   screen pixels. At 480x272 on the Vita's 960x544 that is exactly x2. At 400x240 on a 1920x1080 window it is x4 with bars. `FIT` with
   `LINEAR` is the smooth "lower the resolution for speed" setting.
6. **Depth is opt-out per target** (`no_depth`, answered 2026-11-26). A world camera drawing into a `no_depth` target is an `ensure` failure,
   since it would silently draw in submission order; screen passes (`Depth_Mode.DISABLED`) are fine.

### Proposed second step, kept separate: one internal resolution for the whole game

The render-resolution item in `render_plan.md` is about *Matchbox as a whole*, not a texture the game manages. Built on the target above,
and offered as a second API so the first can be approved or changed on its own:

```odin
Internal_Resolution_Settings :: struct {
	width:i32,           // 0 and 0 = off (the default): render at the screen's own size
	height:i32,
	scale:f32,           // or: the fraction of the screen's size, 0.5 = a quarter of the pixels
	filter:Filter_Mode,
	fit:Fit_Mode,
}
set_internal_resolution :: proc(settings := Internal_Resolution_Settings{})   // call any time; takes effect next frame
get_internal_resolution :: proc() -> [2]i32                                   // the size the game is drawn at (the screen's, when off)
```

While on, Matchbox owns one `Render_Target` (in `mbi`): `render_start` begins it, everything the game draws goes into it, and `render_end`
ends it, draws it to the screen with `fit`, and presents. The game changes one line and nothing else: `get_window_size`, anchors and
`calculate_visible_rectangle` answer in internal pixels, `calculate_mouse_world_position` and the stylus/touch maths unscale through the
fit rectangle, so input stays correct. `screen_start` HUDs scale with everything else (the simple, uniform behaviour; a game that wants a
crisp HUD over a lowered world uses explicit targets, above). The 3DS bottom screen is never scaled (it is 320x240 already) and the 3DS top
is allowed to go *lower* than 400x240 only (nothing to gain by going up). Reason for a global mode rather than only explicit targets: on the
Vita the entire frame's pixel cost drops with one setting, and it can be switched at runtime from a settings screen.

## Per-target notes and risks

| Target | How a target is made | Risk / what to measure |
|---|---|---|
| **PC (D3D11)** | `ID3D11Texture2D` (`R8G8B8A8_UNORM`, `RENDER_TARGET \| SHADER_RESOURCE`, one mip) + an RTV + the SRV that becomes `texture.view`; depth is a `D32_FLOAT` texture + DSV the target's size. `render_target_start` saves nothing but sets RTV/DSV and a viewport of the target; `render_target_end` rebinds the swapchain's and the window viewport | The swapchain is `B8G8R8A8_UNORM_SRGB` (writes are converted to sRGB), so the target must be `R8G8B8A8_UNORM_SRGB` or the picture is darker or lighter after the upscale: the pixel test compares a known colour through the whole round trip. Sampling a texture that is still bound as RTV: unbind before the draw (`OMSetRenderTargets` with the swapchain first). Readback for tests: a staging copy and `Map` |
| **3DS** | A `C3D_Tex` from `C3D_TexInitVRAM` (RGBA8; VRAM is fast and the GPU can write it), then `C3D_RenderTargetCreateFromTex(tex, 2D, 0, depth)`. Drawing: `C3D_FrameDrawOn(target)` inside the frame, so no extra `C3D_FrameBegin`. The canvas is the next power of two (min 8) per side as with `create_texture_from_pixels`; the viewport and scissor are the requested size **at the canvas's top-left**, so `calculate_canvas_uv_rectangle` and every sprite/model path work unchanged | (a) **orientation:** the screen targets need `TILT_TO_PANEL`; a texture target should not. The plan expects it, but whether the GPU's texture-target image comes out the right way up is exactly the kind of thing that fails silently: step G5-5 reads texels back and asserts a four-colour quadrant picture. (b) VRAM: two LCD targets already hold about 1.4 MB of the 6 MB; a 256x256 RGBA8 target is 256 KB plus 192 KB for D24. `create_render_target` asserts on failure with the numbers. (c) the 1024 limit and 8-pixel alignment, asserted. (d) the **command buffer**: each target is a `FrameDrawOn` with its own clear, and G4 showed hardware overflows where Azahar does not: the check example draws a handful of items per target, not a sweep. (e) citro3d clears a target with `C3D_RenderTargetClear` (a GPU memory fill), not a draw. (f) the 3DS top screen is already only 400x240: a *lower* internal resolution is the only useful direction there, and the saving is small; the interesting 3DS use is the effect target (a minimap, a mirror) |
| **Vita (GXM)** | `gfx.create_target(w, h)` (a linear `U8U8U8U8_ABGR` texture + a depth surface + a `GxmRenderTarget`, **not multisampled**); `gfx.begin_target` opens a scene, `gfx.end_frame` ends it. Matchbox's fragment programs are made for a non-multisampled screen already, so the same programs draw into the target (vito's note about `target_multisample = .NONE` is satisfied) | (a) **scene order**: see decision 1; `render_start` stops opening the screen scene, and the Vita3K run must show the screen scene still opening exactly once per frame, including a frame with no target and one with no draw at all. (b) **hazard between scenes**: sampling a target the GPU has just rendered in the same frame needs the second scene to wait for the first; `gfx.end_frame` passes no notification objects today. This is the item most likely to be wrong on hardware and invisible in Vita3K (the emulator runs scenes in order); the check example reads the target in the very next scene, so a missing wait shows as stale pixels. If it does, the fix is in `vito/gfx` (a fragment sync object on `begin_target`'s scene), not in Matchbox. (c) texture memory: `gfx.alloc` GPU-mapped; the depth surface is whole tiles (32x32 samples), so a 480x272 target pads to 480x288 |
| Shared | `render_upscaled_target` is a screen-pass quad with the target's texture and the fit rectangle: it reuses `render_sprite`'s unit quad (`mbi.sprite_mesh`), so no new shader or pipeline anywhere | `LINEAR` upscales bleed one pixel at the picture's edge unless the sampler clamps: all three clamp already. `INTEGER` with a window smaller than the target gives scale 1 and crops, never 0 |

### Input and `calculate_visible_rectangle`

Input stays in the **window's** pixels on every target (no change to `get_mouse_position`); only the maths that turns a window pixel into
"where on the picture" is new (`calculate_target_position`). While a target is active, `calculate_visible_rectangle` / anchors answer for
the target, since decision 3 makes the target "the window". Outside, they answer for the real screen, so a HUD drawn after
`render_upscaled_target` is placed in screen units as today. On the 3DS the stylus maths is the bottom screen's own and does not involve the
top screen's target.

### Why this is also the render-resolution answer

Pixels shaded is `width * height * overdraw * cost per pixel`; a target halves `width` and `height` for a quarter of the first factor. On
the Vita at 960x544 (522k pixels) a 640x362 target is 232k (44%) and 480x272 is 130k (25%); the per-pixel lighting cost scales with it.
The upscale costs one textured quad over the full screen (about 522k texels read, no lighting, no depth): small next to a lit scene. These are
arithmetic, not measurements: step G5-7 puts the numbers on the Vita3K/hardware frame time (a lit scene at full, 2/3 and 1/2 size), and the
user's own 30 fps case is the one to compare.

## Tests that assert on numbers

- **Shared, no GPU** (`render_target_test.odin`): `calculate_upscaled_rectangle` and `calculate_target_position` for every `Fit_Mode`
  (480x272 into 960x544 -> exactly x2 and `(0,0)..(960,544)`; 400x240 into 1920x1080 -> `INTEGER` x4 centred (160,60)..(1760,1020), `FIT` 1800x1080
  at (60,0); `FILL` crops; `STRETCH`); round trip window <-> target pixel; `scale` -> size (0.5 of 960x544 is 480x272, odd sizes round up);
  `INTEGER` never scales to 0; the settings' defaults.
- **PC pixel test** (D3D11 WARP device, as `tools/mbsc/gpu_windows_test.odin` does): render a known 2-colour/4-quadrant scene into a 64x32
  target (a rectangle, a sprite, a depth-tested pair of quads whose order a depth buffer decides), read it back through a staging copy and
  assert the quadrant colours exactly and the depth result; then draw it to a 128x64 `INTEGER` x2 destination and assert every 2x2 block equals
  its source pixel; `LINEAR` vs `POINT` differ at an edge; sRGB round trip of one mid-grey stays within 1/255.
- **3DS and Vita on-target self-check** (`examples/render-target-check`, the `billboard-check` pattern: prints `render-target-check: N passed, M failed`
  and shows it on the HUD): a 16x16 and a 64x32 target are drawn into, then the **raw texels are read back on the CPU** after the frame (the 3DS
  can read VRAM linear-mapped and untile with `read_texture_pixels`'s logic; the Vita reads `gfx.Texture.pixels`) and the four quadrant colours,
  the corners and one pixel row are asserted. One target, a handful of draws: light, as the G4 hardware lesson asks. Failures print the first
  mismatch with coordinates and values.

## Steps

- [x] G5-1. Read the code (`render_*`, `bottom_screen_*`, `texture_*`, `vito/gfx`, o3dx's `C3D_RenderTargetCreateFromTex`), search `main`, write this plan.
- [ ] G5-2. **User approves the public API** (this file's "Proposed public API", and says whether the second step, `set_internal_resolution`, is in G5 or later). Nothing below starts before.
- [ ] G5-3. Shared: `render_target.odin` (types, `Fit_Mode` maths, `get_draw_size()`, the frame-order flag, the active target in `mbi`); the camera/screen code reads the draw size; tests for the maths.
- [ ] G5-4. PC: create/destroy, start/end, upscale draw; the WARP pixel test. Check on PC first, since it is the cheapest place to read pixels.
- [ ] G5-5. 3DS: `TexInitVRAM` + `RenderTargetCreateFromTex`, viewport at the canvas's top-left, no tilt; the orientation read-back test in Azahar (**the most likely thing to need a second try**).
- [ ] G5-6. Vita: `create_target`/`begin_target`, deferred screen scene, the between-scene wait if the example shows stale pixels; Vita3K.
- [ ] G5-7. `examples/render-target-check` (a lit 3D scene into a half-size target, upscaled `POINT` + `INTEGER`; a second small target used as a sprite texture; a HUD inside and a HUD outside; keys/buttons to switch size, filter and fit; the self-check; the frame time on the HUD at full, 2/3 and 1/2 size). `odin check` matchbox and the example, `odin test matchbox`, `3ds_check.bat`, `vita_check.bat`, Azahar and Vita3K runs, the numbers read.
- [ ] G5-8. If approved: `set_internal_resolution` on top of G5-3..7, with its own test (the mouse maths through the fit) and an example switch.
- [ ] G5-9. Hardware builds `render_target_check_g5.3dsx` and `render_target_check_g5.vpk` in the main checkout's `build\hardware\`. Commit, do not push. **Wait for the user's hardware check.**

## Open questions for the user

1. **Names.** `Render_Target`, `create_render_target`, `render_target_start` / `_end` (the `camera_start` / `screen_start` / `bottom_screen_start` shape), `render_upscaled_target`,
   `Fit_Mode { FIT, INTEGER, FILL, STRETCH }`: right vocabulary? (`main` called the draw `draw_render_target` and the begin/end `begin_drawing_target`; this branch's verbs are `render_` and
   `_start`/`_end`.)
2. **"Targets first, then the screen" everywhere**, so the Vita and PC share one rule (decision 1), or allow PC/3DS to interleave and document the Vita's limit?
   Proposed: one rule.
3. **HUD placement** (decision 3): a `screen_start` inside the target is in target pixels, one after is in screen pixels. Right default, or should a
   HUD always be crisp (screen pixels) unless asked?
4. **`set_internal_resolution`**: in G5, or deferred? It is the lever for the Vita's frame time; the explicit targets are the engine for it either way.
5. **Colour format**: a target is RGBA8 on every target (the 3DS's and the Vita's native; PC sRGB to match the swapchain). No HDR or 16-bit format
   (`main`'s tonemap target) in G5. Agreed?
6. **Depth default**: answered, `no_depth:bool`.

## Answers (2026-11-26)

1. Names right. 2. One frame-order rule everywhere (error if the screen was drawn to first; `clear_background` on the screen first is allowed, the Vita holds it). 3. HUD placement as proposed.
4. `set_internal_resolution` is in G5. 5. RGBA8 everywhere, PC sRGB. 6. `no_depth`.

## What was done and how it was checked (2026-11-26)

- Files: `matchbox/render_target.odin` (shared), `render_target_{windows,3ds_freestanding_arm32,vita_freestanding_arm32}.odin`, `render_target_test.odin`,
  `render_target_windows_test.odin`, `examples/render-target-check`. One public procedure beyond the proposal: `read_render_target_pixels(target, allocator)` (RGBA rows, top
  first), because the on-target self-check and the tests need to read a target back.
- Tests (PC, 179 in the package, all pass): fit/position/size maths by hand; the pointer unscaled through the fit and the pixel counts quoted below; on a D3D11 WARP device, a scene with four quadrants and a
  depth-decided pair read back exactly, a x2 upscale where every 2x2 block equals its source pixel, the sRGB grey round trip (188 in, 188 out), LINEAR blends where POINT does not, and a whole
  internal-resolution frame into a 16x8 stand-in screen.
- **3DS (Azahar):** `render-target-check` prints `12 passed, 0 failed`: the target's rows read back top-first, depth ordering, the no-depth minimap, padded canvases (267x161 and 200x120 targets sit in 512x256 / 256x128 canvases). The
  scene and minimap draw the right way up, and internal-resolution mode works. **First attempt was wrong:** I assumed the GPU writes a target bottom-up and built a `bottom_up` rule; Azahar showed 5 failures and an upside-down
  minimap, so it was removed: a target's rows lie first-row-on-top like a loaded texture, with no tilt and the viewport at (0, 0).
  **A target created in the middle of a frame killed the app** (an `svcBreak` exception dialog, cause not found), so the internal target is made in `set_internal_resolution`, between frames.
- **Vita (Vita3K):** the scene, the minimap (red quarter top left) and the HUD draw correctly. The example's pixel read-back checks **fail in Vita3K (4 passed, 8 failed)** because the emulator keeps GPU-written
  textures on the GPU and does not write them back to the memory the CPU reads; that says nothing about a real Vita, where the check is the one to read. Not verified on hardware: the scene-to-scene wait (decision above).
- Pixel counts and what each size costs (emulators cannot give hardware frame times; both Azahar and Vita3K sit at their 60 fps vsync, so ms below are vsync, not cost):

  | Target | Full | 2/3 | 1/2 |
  |---|---|---|---|
  | Vita 960x544 | 522,240 px | 641x363 = 232,683 (45%) | 480x272 = 130,560 (25%) |
  | 3DS top 400x240 | 96,000 px | 267x161 = 42,987 (45%) | 200x120 = 24,000 (25%) |

## Hardware finding, 2026-11-26: the 3DS viewport sat at the bottom of the canvas

On the real 3DS the picture showed the target's clear colour over the top of the screen at full size, and over about half of it at 2/3
size. Cause: `C3D_SetViewport(0, 0, w, h)` puts the picture in the LAST rows of the canvas (y counts up from the bottom, the buffer is
stored top row first), while sampling (`calculate_canvas_uv_rectangle`) and `read_render_target_pixels` expect the first rows. A canvas
with no padding hides it, so the 16 x 16 and 64 x 64 checks passed in Azahar. 400 x 240 in 512 x 256 has 6% padding, 267 x 161 has 37%.
Fixed: the viewport's y is the canvas height minus the picture's. Azahar reproduced it with a 20 x 12 picture drawn green over a
magenta clear and sampled into a second target (`sample POINT: 160 off ...`); after the fix `0 off`. That check is now in
`render-target-check` (14 checks), and the example's default fit is FIT (INTEGER leaves bars by design).

Not explained: with the two sample pairs alive through the benchmark, Azahar panicked (svcBreak, reason lost) when the scene target was
remade for the third size. The pairs are now freed at frame 3, between frames, and that no longer panics (not run to the end of the
benchmark: Azahar ran at 1% speed in the background). Freeing a target mid-frame also panics.
