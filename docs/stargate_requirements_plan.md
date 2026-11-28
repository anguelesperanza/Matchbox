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
| F | correct | the four comments name procedures that do not exist (`draw_bounds_wires`, `get_pref_path`, `fixed_camera_add_shot`, `camera_shot_contains`) |

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

**Phase 7: D6 and A9 (decided: Matchbox gains them).** Shadows (one shadow map for the first directional or spot caster), fog,
exposure and tonemap, hemisphere ambient, area lights; MSAA, minimum window size, window screenshot. Each is PC first.
Planned in detail when phase 6 is done.

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
