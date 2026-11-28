# Plan: what Matchbox needs so Stargate can be rebuilt on `full-rewrite`

Status: **plan only, nothing built** (2026-11-27). Source: `C:\Users\King-\Documents\odin-projects\Stargate\matchbox_requirements.md`
(Stargate `raylib-port` @ `7a37d74`). Matchbox is `full-rewrite` @ `e67c881`.

## 1. Is the document correct? Yes, for the Matchbox side

Checked against the current code on 2026-11-27. The Stargate-side references (its `ui/`, `render/`, `editor/` files and
line numbers) were **not** opened; only the repository and branch were confirmed.

| Item | Verdict | What the code shows |
|---|---|---|
| A1 | correct | `events_windows.odin` has no `WM_CLOSE`; `WM_QUIT`/`WM_DESTROY` call `stop_running` |
| A2 | correct | no `WM_CHAR` anywhere; `TranslateMessage` is already called in the pump, so `WM_CHAR` will arrive once handled |
| A3 | correct | `WM_KEYDOWN` sets `keys_pressed` on every message (auto-repeat too); the switch covers `VK_BACK..VK_HELP`, `0-9`, `A-Z` only. Not in the `Key` enum: `=` `-`, numpad, F1-F12. `SHIFT`/`CONTROL` (0x10/0x11) are already inside the range, so left/right is not needed |
| A4 | correct | `WM_MOUSEWHEEL` assigns, no `SetCapture`/`ReleaseCapture`, no `WM_MOUSEHWHEEL` |
| A5 | correct | `hCursor = nil` (`window_windows.odin:180`), no `WM_SETCURSOR` |
| A6, A7 | correct | no clipboard, no `DragAcceptFiles`/`WM_DROPFILES` |
| A8 | correct | only `SetProcessDPIAware()` (`window_windows.odin:156`) |
| A9 | correct | swapchain and depth `SampleDesc.Count = 1`; no `WM_GETMINMAXINFO`; `read_render_target_pixels` exists for targets only |
| B1 | correct | `set_screen_height` is a plain field write (`screen.odin:23`), nothing cached. Pixel-edge snapping is still open |
| B2 | correct, one nuance | `camera_end` draws all opaque, then all transparent. The opaque list is unsorted in a screen pass. **Transparent items are stable-sorted by depth (z)**, so within the see-through list submission order holds only at equal z. The fix must keep z as the layer, with ties in submission order |
| B3 | correct | no `Scissor` anywhere in the package |
| B4 | correct | `render_circle`, `render_triangle`, `render_line`, `render_rectangle(_outline)` exist; no ring, no texture-into-rectangle |
| B5 | correct | `create_font` bakes the atlas and uploads a texture in one call; `calculate_text_size`, `rune_advance`, `wrap_text` exist but need a `Font` with a texture |
| B6 | not measurable yet | one `Render_Item` per glyph and rectangle; no numbers |
| C | correct | no widgets |
| D1 | correct | topology is `TRIANGLELIST` only; `render_line` is flat in XY |
| D2 | correct | only 2D unprojection and `calculate_camera_projection_gl` |
| D3 | correct | `find_asset` looks in `assets/pc/<kind>/` then `assets/<kind>/`; `level` strips `assets/models/` and `assets/images/` |
| D4 | correct | `load_model_checked` exists; `load_skybox_*` and `load_texture` stop on bad input |
| D5 | unconfirmed | targets are fixed-size and do not nest, as stated; whether destroy + create between frames is cheap and safe on PC is untested |
| D6 | correct | three light kinds plus ambient |
| F | correct | the four comments name procedures that do not exist (`get_pref_path`, `fixed_camera_add_shot`, `camera_shot_contains`) |

## 2. Decisions

**Made (2026-11-27, the user):**
- The toolkit lives in its own `matchbox/ui` package, like `matchbox/level`.
- **D6 and A9: Matchbox gains them** (shadows, fog, exposure, tonemap, area lights; MSAA, minimum window size, window
  screenshot). Neither blocks the rewrite, so they are phase 7, after the editor runs. The handhelds are a separate question per feature.
- **D3: Stargate adopts Matchbox's asset layout** (the user, 2026-11-28). Models live under `assets/models/` (and `assets/pc/models/` for PC
  overrides), images under `assets/images/`; a level stores the name Matchbox looks up (`props/crate.glb`), not a project-root path.
  The editor loads through Matchbox's own `find_asset` and `_checked` loaders, so it shows what the game shows. `matchbox/level`
  keeps stripping a leading `assets/models/` or `assets/images/`, so old levels still load. Matchbox work: the D4 `_checked`
  loaders, and a procedure that lists the asset names of a kind, merged across `assets/pc/` and `assets/` (for the pickers).
- **Names:** any new public name that follows the house style (CLAUDE.md) is approved without review. A list of every new
  public procedure is written at the end of the work, for the user to read.
## 3. Phases

Each phase touches its own files, ends in a check, and stops for review. PC (D3D11) only; the handhelds get stubs that do
nothing or return zero.

**Phase 1: input and window (A1-A3, then A4-A8).** Files: `events_windows.odin`, `input_windows.odin`,
`window_windows.odin`, the handheld input stubs. One writer, because they share the message pump.
- A1: `WM_CLOSE` recorded, nothing destroyed; `is_close_requested()`.
- A2: `WM_CHAR` with surrogate pairs, control characters skipped, per-frame UTF-8 buffer cleared with `keys_pressed`.
- A3: keys added to `Key`; `pressed` only when lParam bit 30 is clear; `is_key_repeated`; keypad Enter via the extended bit.
- Then A4 (capture, accumulated wheel, horizontal wheel), A5 (cursors), A6 (clipboard read, write if cheap), A7 (drop),
  A8 (`get_display_scale`; per-monitor-v2 + `WM_DPICHANGED`).
- Check: synthetic-message tests (post real window messages to a test window); holding Ctrl+Z does not re-fire "pressed".

**Phase 2: the 2D base (B2, B3, B1).** Files: `render_windows.odin`, `render.odin`, `shapes.odin`, `screen.odin`.
- B2: in a screen pass, one list, stable by z, blend chosen per item. 3D scenes unchanged.
- B3: clip rectangle in screen units stored on the item, `RSSetScissorRects` at draw, scissor-enabled rasterizer states,
  a nesting `begin_clip`/`end_clip`, and a read of the current clip.
- B1: whole-pixel edges (snap the screen camera's origin, or a pixel-snap switch).
- Check: pixel-readback tests (`read_render_target_pixels`) for a panel over a dim, a clip inside a clip, a 1-unit line at odd and even heights.

**Phase 2 in detail (read from the code 2026-11-28; nothing built yet).**

*B2, paint order.* `queue_render` puts a `.NONE` item in `opaque_items` and an `.ALPHA` item in `transparent_items`, and
`camera_end` draws the whole first list then the whole second. A screen pass skips the opaque sort, and the transparent sort
is a stable sort by `depth`, which is only computed for `.ALPHA` items (the view-space distance of the item's origin).
`shape_blend` makes a rectangle `.ALPHA` only when its alpha is below 1. So today a see-through dim submitted *before* a
solid panel is drawn *after* it. The change, for a screen pass only: compute `depth` for every item, concatenate the two
lists, stable-sort by depth (so z is the layer, equal z keeps submission order), and draw in that order with each item's own
blend state. 3D passes and handhelds are untouched. **The one behaviour change** is for games that draw HUD in a screen pass
and relied on "solid first, see-through second": text submitted before a solid background at the same z used to appear on top
and will now be covered, which is what "drawn last lands on top" promises. Seven examples use `screen_start`; they are
checked before and after (pixel readback of a render target), and each is fixed or noted.

*B3, clipping.* D3D11 needs `ScissorEnable = true` on the rasterizer states and an `RSSetScissorRects` per draw. Plan: both
states get scissor enabled; every item carries a clip (pixels, or "none" = the whole target) recorded at queue time, because
items are drawn at `camera_end`, long after they were queued; `camera_end` sets the rectangle when it changes. The clip is
given in screen-pass units (min bottom left, max top right) and converted with the screen camera's scale, centre origin and
+Y up, to window pixels (or render-target pixels while a target is active), rounded to whole pixels and clamped to the target.
A fixed-depth stack (`MAX_CLIP_DEPTH`) intersects each new clip with the one below. Proposed names, in the house `thing_start` /
`thing_end` pattern (`screen_start`, `camera_start`): `clip_start(min, max)`, `clip_end()`, and `get_clip_rectangle()`
for the UI's pointer test. It is an error outside a screen pass, with a message. An empty intersection draws nothing.

*B1, whole-pixel edges.* The requirements document says an odd window height puts the centre in the middle of a pixel and
blurs every 1-unit line. That is **not yet shown**: shapes are untextured quads with no multisampling, so a misplaced edge
makes a line one or two pixels thick, or shimmer, rather than blur, and text (linear-filtered glyph sprites) is the case that
would blur. So B1 starts with a measurement: pixel-readback tests of a 1-unit line, a 1-unit outline and a glyph at an even and
an odd window height and at UI scale 1, 1.25 and 2. If they show a problem, the fix is to snap the screen camera's origin to a
pixel edge (`calculate_camera_snapped` already does this for orthographic cameras with `pixel_snap`, but the screen camera does
not set it). A scale like 1.25 puts unit positions between pixels whatever the origin does, so the UI layer still rounds its
own rectangles to whole pixels (`calculate_snapped_to_pixel` exists). `set_screen_height` every frame is confirmed fine: a plain field write.

*Check for the phase:* the example from section 4, built up in steps: panel over dim over panel (B2), a list clipped inside a
clipped scroll view (B3), the pixel-line measurements (B1); each asserted on pixels read back from a render target, plus the
existing `render-check` and `render-target-check` examples unchanged.

*Risks:* the render loop is shared by every PC game, so the 3D path must draw byte-identical frames (checked with the
existing render checks before and after); per-item scissor and blend changes cost state changes per item in a screen pass
(measured later, B6); clip applies only to the screen pass, so a clipped 3D viewport is drawn into a render target at the
size of its panel instead.

**Phase 3: 3D for the viewport (D1, D2).** New files, so it can run beside phase 2 with a different writer.
- D1: depth-tested 3D lines (line-list topology or camera-facing quads), `render_grid`, `render_bounds_wires`; many lines per
  frame without one item each. Also fixes the `level` comments that name `draw_bounds_wires`.
- D2: `calculate_ray_from_screen`, `calculate_world_to_screen`, ray vs plane, sphere, box, oriented box, in screen-pass units.
- Check: Stargate's `render/ray_test.odin` ported as the acceptance tests; round trip ray -> world -> screen.

**Phase 4: the toolkit (C, plus B4, B5).** After the C-where decision. Ring and texture-into-rectangle (B4), text metrics
without a GPU (B5), then the widgets from the document's table. Acceptance: Stargate's `ui_test.odin` ported, with every
test's numbers turned over for +Y up (rows run downwards while +Y is up).

**Phase 5: loading and targets (D3, D4, D5).** `_checked` loaders for skybox and texture; `get_asset_names(kind)` for the D3 decision; measure
destroy + create of a render target between frames on PC and add a resize call if it is not safe or cheap. Fixes the F
sky-crash finding.

**Phase 6: measure.** B6 with a real editor-sized screen; F comment fixes (small, can go in earlier).

**Phase 7: D6 and A9 (decided: Matchbox gains them).** Each is PC first; the handhelds get stubs or nothing. Planned 2026-11-28, in this order
(cheap and independent first, the shader work last because every lit shader changes and the `.dxil`/`.spv` must be rebuilt together):

- **7a, A9 small items.** `set_minimum_window_size` (WM_GETMINMAXINFO) and `read_window_pixels` (the back buffer as RGBA). *Done.*
- **7b, MSAA.** *Done.* The swapchain's flip-model is not used (`SwapEffect = .DISCARD`), so a multisampled swapchain is allowed; the work is the depth
  buffer, the rasteriser's `MultisampleEnable`, and render targets (Stargate draws its viewport into one, where the grid lines shimmer), which need a
  multisampled colour+depth pair resolved into the texture the UI samples. Shape: a `samples` field on `Render_Target_Description` and an
  `init` option for the window; tested on WARP by counting edge pixels that are neither colour.
- **7c, scene settings block (PC).** *Done.* One new constant buffer, `Scene_Settings` (exposure, tonemap kind including AGX, fog colour/near/far/density,
  hemisphere ambient sky + ground), read by the lit shaders and the unlit one for fog. `Lighting_Settings` gains the fields as defaulted values that mean
  "as before", so existing scenes draw unchanged (checked pixel for pixel against the old build's numbers).
- **7d, area lights.** *Done.* `AREA_RECT`/`AREA_DISK` as a closest-point-on-shape approximation in the PC shaders, `matchbox/level` stops flattening them.
- **7e, shadows.** One shadow map for the first directional or spot caster: depth-only pass of the casters, 3x3 PCF in the lit shaders, resolution,
  extent and bias settings; `level.draw_level_shadow_casters` already exists. Needs a per-draw custom shader or a built-in depth pipeline.
- Handhelds: none of 7b-7e is planned for them; `matchbox/level` keeps ignoring what a handheld cannot draw.

## 4. First check that the base works (from the document)

A Matchbox example: a screen-pass panel with a clipped, scrolling list of 500 text rows, a modal over it, and a
render-target viewport showing a grid and a wire box picked by mouse ray. Report the frame time. This is also the B6 measurement.

## 5. Order and risk

Phase 1 and 3 are independent; 2 follows 1 only for tests. The biggest risks are phase 4 (size: ~1,900 lines of widgets and
a test port) and B2/B3 (they change the render loop every game uses; the 3D and handheld paths must stay byte-identical,
checked by the existing render checks).

## 6. Status and the list of new public names

**Phase 1, A1-A3: done 2026-11-27 (uncommitted).** `odin test matchbox`: 245 pass, 9 of them new (`input_windows_test.odin`, driven by
sending `window_event_proc` real messages). Five mutations each fail a test (repeat counted as a press, keypad Enter without
the extended bit, a lone surrogate half kept, control characters typed, the close button always held back). 3DS and Vita
`odin check` and `matchbox/level` still pass. Not run: a real window with a real keyboard (the tests send messages, not
key presses). The "remaining keyboard keys" item in `fixes.md` is folded in and marked done.

**Phase 1, A4-A8: done 2026-11-28 (uncommitted at the time of writing).** `odin test matchbox`: 252 pass (7 more). Wheel turns are
added up per frame (saturating) and there is a horizontal wheel; the window holds the pointer (`SetCapture`) while any button
is down and gives it back on the last release or on losing focus; cursor shapes are loaded at init and applied on
`WM_SETCURSOR` over the client area; clipboard read and write; dropped files with their window position; `get_display_scale`.
Mutation checks: wheel assigned instead of added, no `SetCapture`, no `ReleaseCapture` on the last release or on focus loss,
the `WM_SETCURSOR` handler not setting the cursor, the drop position dropped, and an unsaturated wheel each fail a test
(the cursor one first survived and its test was tightened). Handheld stubs added; 3DS, Vita and `matchbox/level` checks pass.

Not verified, and why: a drag that really leaves the window with a real mouse (the tests prove the capture calls, not the
hardware path); dropping a file from a real Explorer window (the test builds the same structure Explorer sends); and the
display scale on a second monitor. **A8 reads the DPI of a process that is still only system-DPI aware** (`SetProcessDPIAware`),
so on a mixed-scale setup it reports the primary monitor's scale and does not follow the window across monitors. Moving to
per-monitor-v2 awareness (with `WM_DPICHANGED` and `AdjustWindowRectExForDpi`) changes every game's window handling and
needs a second monitor to test, so it was not done: it is a decision for you when the editor needs it. The clipboard test
replaces the clipboard text while it runs and puts the old text back (non-text contents, such as an image, are not restored).

Two choices to know about: the close button is held back **only after `set_close_confirmation()`**, so no existing game
stops closing (the requirements document's wording would have made the X do nothing in every game that did not call
`stop_running`); and Windows' Alt-key and F10 messages (`WM_SYSKEYDOWN`) are still not handled, as the document says.

**Phase 2, B2 + B3 done, B1 measured and not needed: 2026-11-28 (uncommitted at the time of writing).** `odin test matchbox`: 259 pass.
*B2:* in a screen pass `camera_end` merges the opaque and see-through lists, stable-sorts by z (the layer, farther first) then by
submission order, and draws each item with its own blend; 3D passes and the handhelds are unchanged. A modal (dim, then solid
panel) now covers what is under it. Mutating the screen-pass branch off fails two tests.
*B3:* `clip_start(min, max)` / `clip_end()` / `get_clip_rectangle()` in HUD units; nested clips are cut down to the shared area;
each queued item carries its pixel rectangle, and `camera_end` sets the D3D scissor only when it changes. Scissor is enabled on
both rasterizer states, so every place that binds a target (`bind_render_target`, `bind_screen`) sets the whole target as the
scissor (an unset scissor is empty and would draw nothing). A clip that leaves nothing draws nothing. Making the scissor ignore
the clip fails three tests. Handheld stubs do nothing (a clip there shows everything). 3DS, Vita, `matchbox/level` checks pass
and 57 level tests pass; the PC examples that use `screen_start` still `odin check` (`render-check` does not on Windows
because of `o3dx/ctru` socket names; it was not run before this change, so I did not look further).
*B1:* measured with a one-unit-thick rectangle at window heights 64, 65, 99 and 100: always exactly one row, no part-lit pixel.
Shapes are untextured quads with no multisampling, so there is nothing to blur; **no change made**. Text (linear-filtered glyphs)
is the one thing an odd height could soften, and it was not measured here. Not seen: any of this on a real screen.

**Phase 3, D1 + D2 done: 2026-11-28 (uncommitted at the time of writing).** `odin test matchbox`: 266 pass.
*D2:* `ray.odin` (shared by every target, pure maths). The ray and the projection use `calculate_camera_projection_gl` and the view
matrix, the same ones `camera_start` draws with. Screen points are in screen-pass units (+Y up). Stargate's 28-case ray-box table
(made in Python by another algorithm) and its plane, sphere, oriented-box and round-trip tests are ported with the cases unchanged;
the y flip is the only difference. Flipping the ndc y in `calculate_ray_from_screen` fails the round trip.
*D1:* a line is one draw of a shared two-vertex mesh drawn as a **line list** (new `Mesh.lines`, `LINELIST` topology), stretched
between its ends by the model matrix, so there are no per-frame vertices; 1 pixel wide, depth-tested. A 40 by 40 grid is 82 draws
(not measured for cost). A thickness was left out on purpose: a thick line would need a camera-facing quad whose pixel width
changes along its length, and nothing asks for one. Pixel tests: a line along Z is seen, and is hidden behind a nearer quad
drawn first; the grid has one line per slice; the box draws a ring. Using triangle topology instead fails two of them.
The handhelds get no-op stubs. The `level` comments now name `render_bounds_wires`. Not seen on a real screen.

**Phase 4, B4 + B5 + the toolkit (C): done 2026-11-28 (uncommitted at the time of writing).** `odin test matchbox`: 269 pass; `odin test matchbox/ui
-define:ODIN_TEST_THREADS=1`: 13 pass (they share one `ui_state`, so one at a time).
*B4:* `render_circle_outline` (a ring from two triangles a segment, so a see-through colour does not double at the joins; 16 to 96
segments by radius) and `render_texture_rectangle` (a texture, such as a render target, into a rectangle, the right way up, with a `source`
region). Both pixel-tested. *B5:* `create_font_metrics`: the same advances and ascent as `create_font`, with no texture, so no window or GPU;
`calculate_text_size`, `calculate_line_height` and `wrap_text` work on it (tested with no device).
*Cursor shapes:* Stargate's editor also uses a move cursor and two diagonal resizes, so `Cursor_Shape` gained `RESIZE_DIAGONAL_DOWN`,
`RESIZE_DIAGONAL_UP`, `MOVE` and `NOT_ALLOWED`.
*The toolkit, `matchbox/ui` (Windows only, 9 files):* ported from Stargate's `ui` package with the geometry turned over. The decisions: units are
the screen pass's (`begin_frame` sets the screen height to the window height over the UI scale); `Rectangle` is `min`/`max` with
`create_rectangle(top_left, size)` for layout; the pointer is *claimed* (`claim_pointer`), because `mb.is_mouse_captured` is the OS lock; the
clip is kept in `ui` as well as forwarded to Matchbox, so hit tests work in a test with no screen pass; text uses Matchbox's fonts through
`create_font_metrics` and is baked at size x scale, with Matchbox's default font unless `ui_state.font_settings.bytes` is set (Stargate's
Adapa is its own asset, so it sets it). Names follow the house style: `render_*` draws, `calculate_*` works out, `get_*`, `is_*`; widgets
that act and answer keep their verbs (`button`, `toggle`, `dropdown`, `context_menu`, `number_field`, `modal_begin`).
*Tests:* Stargate's ten ported with every number turned over, plus three that did not exist because the arithmetic that flipped was
untested there: the scroll view (origin, wheel, thumb drag, `scroll_to`) and a dropdown opening upwards. Mutations (the flip test off, the wheel sign
reversed) each fail a test. *Seen:* `examples/ui-check` ran on this PC with a real mouse and keyboard: widgets, a clipped scroll view, a
dropdown over everything, typing with a caret, a 3D viewport in a render target with the grid, a wire box and a ground marker that follows the
pointer. Not seen: odd window heights, a UI scale other than 1, a second monitor.
*Not ported:* Stargate's `Input.dropped` (use `mb.get_dropped_files`; its position is in window pixels) and its keyboard wrappers (use `mb.is_key_*`).

**Phase 5, D3 + D4 + D5: done 2026-11-28 (uncommitted at the time of writing).** `odin test matchbox`: 272 pass; level 57; 3DS, Vita and `ui` checks pass.
*D4:* `load_texture_checked`, `load_skybox_panorama_checked`, `load_skybox_cubemap_checked` return `ok` for a missing file, bytes that are not a picture,
a picture that is not 8 bits a channel, a cube cross of the wrong shape, or a texture that does not divide into its columns and rows; the
plain loaders are now these plus an `ensure`. `matchbox/level`'s sky uses the checked ones, which closes the F finding (a bad picture used to
stop a level that should fall back to its background colour). Tested for missing and not-a-picture files, with no device.
*D3 (the user's layout decision):* `get_asset_names(asset_type, extensions, allocator)` lists every asset of a kind across `assets/pc/<kind>/` and
`assets/<kind>/`, in folders below too, as the names `find_asset` takes (`props/crate.glb`), sorted, a name in both listed once, extension filter
case-insensitive. Tested on a tree built under the temp folder.
*D5:* `resize_render_target(&target, width, height)` keeps the filter and depth, does nothing at the same size (so a panel can call it every
frame), and is for between frames. Measured on the software device (WARP): resize + draw + read back 120 times in a row costs 0.09 ms a frame
and the target stays drawable with the new size. **That is a software device; a real GPU's cost of freeing and making a small texture was not
measured.** `destroy_render_target` was already guarded against the target being drawn into.
*Not done:* anything for D3 on the handhelds (the listing and the checked loaders are PC only; a handheld level still loads what `find_asset` finds).

**Phase 6, B6 + F: done 2026-11-28 (uncommitted at the time of writing).**
*B6, measured:* `examples/ui-bench` (`odin run examples/ui-bench -o:speed`) draws an editor-sized 1920x1080 frame: three scroll panels of 50 text rows
(about 1500 glyphs each), 12 buttons, a clipped scroll view, and a 3D viewport target with an 82-line grid, times 1, 2, 4 and 8. This PC's monitor
refreshes at 120 Hz, so every frame was 8.33 ms (vsync) at all four loads, i.e. the GPU kept up.

| Load | Draws a frame | UI build (CPU) | Submit (`screen_end`, CPU) |
|---|---|---|---|
| x1 (an inspector with a long list) | 3539 | 0.17 ms | 0.84 ms |
| x2 | 6992 | 0.30 ms | 1.72 ms |
| x4 | 13898 | 0.58 ms | 3.68 ms |
| x8 | 27710 | 1.05 ms | 7.10 ms |

*Verdict:* one draw per glyph and per rectangle is enough. The real editor screen is about x1, which costs about 1 ms of CPU; cost grows
linearly (about 0.26 ms per thousand draws). **No batching of screen-pass items.** *Not measured:* a 60 Hz or weaker GPU than this PC's, and the
handhelds (the UI is PC only).
*F:* three comments brought into line with the renamed procedures (`level/camera.odin`, `level/camera_test.odin`, `level/load.odin`).
`docs/g3_cameras_plan.md` and `docs/the_game_port_plan.md` still carry old names in their history tables, left as written.
No new public names this phase.

**Phase 7a, A9 minimum window size + window screenshot: done 2026-11-28 (uncommitted at the time of writing).** `odin test matchbox`: 274 pass; 3DS, Vita,
ui and level checks pass. `set_minimum_window_size(width, height)` takes the drawing area and grows it by the frame (`calculate_minimum_tracking_size`,
tested to grow by exactly the area's difference). `read_window_pixels()` returns RGBA (red first) and the size; tested on a blue-first stand-in buffer.
*Not seen:* a real drag against the minimum on a real window, a real swapchain read. The screenshot must be taken before `render_end` (the swapchain
discards on present).

**Phase 7b, MSAA: done 2026-11-28 (uncommitted at the time of writing).** `odin test matchbox`: 275 pass; level 57; 3DS, Vita, ui checks pass.
*Render targets:* `Render_Target_Settings.samples` (2, 4, 8; a count the GPU lacks drops to the next lower, asked with `CheckMultisampleQualityLevels`). The target draws
into a multisampled texture and `render_target_end` resolves it into `texture` (sRGB resolves in linear light), so everything that samples or reads a target
is unchanged; `resize_render_target` keeps the count. *Window:* `set_window_samples(samples)` remakes the swapchain (it cannot change count in place; init is
untouched, a window starts at 1) and the depth buffer follows the colour's count; `read_window_pixels` resolves first. *Lines:* a second set of rasteriser
states with `MultisampleEnable`, chosen while drawing into a multisampled target, because that flag is what smooths a line and with one sample it would
widen every 1-pixel line (the grid test caught it: 8 lit pixels in a row instead of 5), so plain targets keep the old states and draw byte-identically.
*Measured:* WARP test, a thick diagonal: 0 half-covered pixels at 1 sample, many at 4. `examples/msaa-check` on this PC's real GPU and window: a 3D line has
0 half-covered pixels at 1 and 568 (window) / 324 (256 px target) at 4. *Not measured:* the GPU cost of 4x (fill rate, memory) on a real editor frame; the
handhelds ignore it (`set_window_samples` answers 1). The internal-resolution target is not multisampled.

**Phase 7c, hemisphere ambient, fog, exposure, tonemap: done 2026-11-28 (uncommitted at the time of writing).** `odin test matchbox`: 277 pass (stable over 4 runs);
level 58; `tools/mbsc` 141; 3DS, Vita and ui checks clean.
*Shape:* `Lighting_Settings` gains `hemisphere`, `ambient_ground`, `fog` (`Fog_Settings`), `exposure`, `tonemap` (`Tonemap`: NONE, REINHARD, ACES, AGX); the zero of each
means "as before", so a scene that never heard of them is unchanged (an exposure of 0 is read as 1). The PC lights block carries four more rows after `lights_count`
(`ground`, `up`, `fog_color`, `fog_range`; `Lights_Block` has them only on Windows, the handhelds' blocks are untouched). One new mbsc built-in, `light_finish(color, view)`,
PC only, called under `when TARGET == .PC` in `mesh_lit.mbs` and `mesh_skinned_lit.mbs`; the generated `.pc.hlsl`/`.pc.refl` of those, `mesh_vertex_lit` and the optional psx shaders
were rebuilt (their lights block grew). Order is exposure, tonemap, then fog, so the fog colour reaches the screen as written. While a tonemap is on, the light sums are no longer
clamped to 1. `matchbox/level`'s `Lighting_Settings` now holds the file's `ambient.kind`/`ground_color`, `fog`, `exposure`, `tonemap`, and `get_level_lighting(&level)` makes Matchbox's
settings from it, by name.
*Measured:* mbsc's pixel test (the generated HLSL on the software device, numbers worked by hand): exposure 2 doubles, Reinhard 1 -> 0.5 and 3 -> 0.75, ACES 1 -> 2.54/3.16, fog 0/0.5/1
at, half way and past its end with alpha kept, hemisphere sky/ground/sideways, a bright ambient left at 3 under a tonemap and clamped to 1 without. Matchbox test: a lit plane read back
from a target (188 for 0.5, 255 for exposure 2, 255 then 225 for an ambient of 3 without and with Reinhard, solid blue in complete fog, the sky colour from a hemisphere).
*Fixed on the way:* mbsc crashed (nil) on a `when` that is false for the target, has no `else` and sits in a fragment stage (`settled_statements`); two tests raced on `mbi`'s asset folders and
camera (the asset-names and billboard tests now take the same locks as the others).
*Not done / not known:* **AgX and ACES are the published approximations, not checked against Stargate's own shader** (Stargate's copy was not readable as source here), so a level may look slightly
different in the editor; compare one scene side by side before trusting them. Fog and the tonemap apply to lit models only, not to unlit models, sprites, text, the skybox or per-vertex-lit parts
(`mesh_vertex_lit` has no finish; it computes light in the vertex stage) and not to the 3DS or Vita. Not looked at on a real window.

**Phase 7d, area lights: done 2026-11-28 (uncommitted at the time of writing).** `odin test matchbox`: 279 pass; level 58; `tools/mbsc` 142; 3DS and Vita checks clean.
`Light_Kind` gains `AREA_RECT` and `AREA_DISK`, `Light` gains `right` and `area_size` (half-extents; a disk's radius in x), with `create_area_rect_light(position, direction, right, width, height, color)` and
`create_area_disk_light(position, direction, radius, color)`. *How it is lit:* the nearest point of the shape to each pixel (clamped to the rectangle, or pulled in to the rim for a disk) shines as a point light does,
with the engine's one distance curve, from the front face only (a pixel behind the shape gets nothing). It is a stand-in for integrating over the shape: exact for a pixel straight in front of a point inside it, and
a hard-edged, slightly too bright penumbra elsewhere, with none of an area light's soft falloff and no spread highlight. In the block, kinds 3 and 4; the facing (not reversed, unlike a sun's) with the half height in
`direction.w`, the right vector with the half width in `cone`. The handhelds turn an area light into a point light at its centre. `matchbox/level` now builds real area lights (facing the entity's forward, its width along the entity's X).
*Measured:* mbsc's pixel test with numbers worked by hand (in front, past the side, past the end, behind, a disk inside and past its rim); a lit plane read back from a target (the fade of a disk 2 above it, and black when the
disk faces away).
*Not done:* Stargate's own area-light look was not compared; its numbers (`area_size` meaning, intensity) are taken at face value from the level format.

New public names so far (the user reads this list at the end):

| Name | Kind | Where |
|---|---|---|
| `is_key_repeated(key)` | procedure | `input_windows.odin`, handheld stub |
| `get_typed_text()` | procedure | `input_windows.odin`, handheld stub |
| `is_close_requested()` | procedure | `input_windows.odin`, handheld stub |
| `set_close_confirmation(enabled := true)` | procedure | `input_windows.odin`, handheld stub |
| `get_mouse_wheel_horizontal_value()` | procedure | `input_windows.odin`, handheld stub |
| `set_cursor_shape(shape)` | procedure | `input_windows.odin`, handheld stub |
| `get_clipboard_text(allocator := context.temp_allocator)` | procedure | `input_windows.odin`, handheld stub |
| `set_clipboard_text(text)` | procedure | `input_windows.odin`, handheld stub |
| `get_dropped_files()` | procedure | `input_windows.odin`, handheld stub |
| `get_display_scale()` | procedure | `input_windows.odin`, handheld stub |
| `Cursor_Shape` (`ARROW`, `TEXT`, `RESIZE_HORIZONTAL`, `RESIZE_VERTICAL`, `HAND`, `CROSSHAIR`) | enum | `desktop_input.odin` (shared) |
| `Dropped_File` (`path`, `position`) | struct | `desktop_input.odin` (shared) |
| `MAX_TEXT_INPUT` | constant (array size) | `backend_windows.odin` |
| `Key` values: `NUMPAD_0`..`NUMPAD_9`, `MULTIPLY`, `ADD`, `SEPARATOR`, `SUBTRACT`, `DECIMAL`, `DIVIDE`, `KEYPAD_ENTER`, `F1`..`F12`, `NUMLOCK`, `SCROLL_LOCK`, `SEMICOLON`, `EQUALS`, `COMMA`, `MINUS`, `PERIOD`, `SLASH`, `GRAVE`, `LEFT_BRACKET`, `BACKSLASH`, `RIGHT_BRACKET`, `APOSTROPHE` | enum values | `input_windows.odin`, handheld `Key` |
| `set_minimum_window_size(width, height)` | procedure | `input_windows.odin`, handheld stub |
| `read_window_pixels(allocator := context.allocator)` | procedure | `render_target_windows.odin`, handheld stub |
| `set_window_samples(samples)` | procedure | `render_windows.odin`, handheld stub |
| `Render_Target_Settings.samples`, `Render_Target.samples` | struct fields | `render_target.odin` (shared) |
| `Lighting_Settings.hemisphere`, `.ambient_ground`, `.fog`, `.exposure`, `.tonemap` | struct fields | `light.odin` (shared; PC only in effect) |
| `Fog_Settings` (`enabled`, `color`, `start`, `end`) | struct | `light.odin` (shared) |
| `Tonemap` (`NONE`, `REINHARD`, `ACES`, `AGX`) | enum | `light.odin` (shared) |
| `get_level_lighting(level)` | procedure | `level/draw.odin` |
| `Level_Ambient.kind`/`.ground_color`, `Level_Fog`, `Lighting_Settings.fog`/`.exposure`/`.tonemap`, `Ambient_Kind`, `Tonemap` | level file types | `level/level.odin` |
| `light_finish(color, view)` | shader built-in (mbsc, PC only) | `tools/mbsc/builtins.odin`, `docs/shader_language.md` |
| `Light_Kind.AREA_RECT`, `.AREA_DISK`; `Light.right`, `Light.area_size` | enum values, struct fields | `light.odin` (shared; PC only in effect) |
| `create_area_rect_light(position, direction, right, width, height, color)`, `create_area_disk_light(position, direction, radius, color)` | procedures | `light.odin` (shared) |
| `clip_start(min, max)` | procedure | `clip_windows.odin`, handheld stub |
| `clip_end()` | procedure | `clip_windows.odin`, handheld stub |
| `get_clip_rectangle()` | procedure | `clip_windows.odin`, handheld stub |
| `MAX_CLIP_DEPTH` | constant (array size) | `clip.odin` (shared) |
| `Clip_Rectangle`, `Clip_State` | structs | `clip.odin` (shared) |
| `Ray` (`origin`, `direction`) | struct | `ray.odin` (shared) |
| `calculate_ray_point(ray, distance)` | procedure | `ray.odin` (shared) |
| `calculate_ray_from_screen(camera, point, min, max)` | procedure | `ray.odin` (shared) |
| `calculate_world_to_screen(camera, point, min, max)` | procedure | `ray.odin` (shared) |
| `calculate_ray_plane`, `calculate_ray_sphere`, `calculate_ray_box`, `calculate_ray_oriented_box` | procedures | `ray.odin` (shared) |
| `render_line_3d(start, end, color)` | procedure | `lines_windows.odin`, handheld stub |
| `render_grid(slices, spacing, color, height := 0)` | procedure | `lines_windows.odin`, handheld stub |
| `render_bounds_wires(lower, upper, color, model := identity)` | procedure | `lines_windows.odin`, handheld stub |
| `create_line_mesh(vertices, indices)`, `create_line_geometry()` | procedures | `render_windows.odin`, `mesh.odin` |
| `render_circle_outline(position, radius, thickness, color)` | procedure | `shapes.odin` |
| `render_texture_rectangle(texture, min, max, z, tint, source)` | procedure | `sprite.odin` |
| `create_font_metrics(bytes, pixel_size, pixels_per_unit)` | procedure | `font.odin` |
| `Cursor_Shape` values `RESIZE_DIAGONAL_DOWN`, `RESIZE_DIAGONAL_UP`, `MOVE`, `NOT_ALLOWED` | enum values | `desktop_input.odin` |
| the `matchbox/ui` package | package | see its files: `Rectangle`, `create_rectangle`, `create_rectangle_centred`, `calculate_rectangle_size`, `calculate_rectangle_centre`, `calculate_rectangle_intersection`, `get_rectangle_top_left`, `is_point_in_rectangle`, `begin_frame`, `end_frame`, `shutdown`, `set_scale`, `get_scale`, `get_display_scale`, `get_screen_rectangle`, `calculate_pixels`, pointer (`get_pointer_position`, `get_pointer_delta`, `get_pointer_wheel`, `is_button_pressed`, `is_button_held`, `is_button_released`, `claim_pointer`, `release_pointer`, `is_pointer_claimed`, `is_pointer_over_rectangle`), typing (`start_text_input`, `end_text_input`, `is_text_input_open`, `get_text_input`), drawing (`render_rectangle`, `render_rectangle_border`, `render_line`, `render_circle`, `render_circle_outline`, `render_triangle`, `render_texture`, `begin_clip`, `end_clip`, `is_point_in_clip`), text (`get_font`, `default_font`, `calculate_text_size`, `calculate_line_height`, `calculate_baseline_centred`, `render_text`, `wrap_text`), widgets (`button`, `calculate_button_enabled_if`, `toggle`, `Text_Field` with `update_text_field`, `render_text_field`, `set_text_field_text`, `insert_text_field_text`, `place_text_field`, `get_text_field_string`, `destroy_text_field`, `calculate_text_field_height`, `calculate_text_field_label_height`; `number_field`, `is_number_field_active`, `destroy_number_field`; `begin_scroll`, `end_scroll`, `scroll_to`, `get_scroll_max`; `dropdown`, `open_context_menu`, `context_menu`, `render_dropdown_overlay`, `is_dropdown_open`, `close_dropdown`, `calculate_dropdown_list`, `calculate_dropdown_row`, `get_dropdown_row_at`; `open_modal`, `close_modal`, `is_modal_open`, `modal_begin`, `modal_overlay`, `is_modal_dismissed`; `set_status`, `clear_status`, `get_status_text`, `calculate_status_alpha`, `render_status`), and their style and state structs and `*_STYLE` constants |
| `load_texture_checked(filename, filter)` | procedure | `texture_windows.odin` |
| `load_skybox_panorama_checked(filename)`, `load_skybox_cubemap_checked(filename)` | procedures | `skybox_windows.odin` |
| `get_asset_names(asset_type, extensions, allocator)` | procedure | `assets_windows.odin` |
| `resize_render_target(target, width, height)` | procedure | `render_target.odin` (shared) |
