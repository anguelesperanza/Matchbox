# Cleanup -- what to check

The `cleanup` branch compiles clean: `odin check matchbox -no-entry-point` and
every example. That catches type and name errors and nothing else, so what
follows is the behaviour a compiler cannot speak for.

**Nothing here was run.** The refactor was done while the machine was in use, so
no window was opened -- every claim below is "this compiles and the change was
intended to be behaviour-neutral", not "this was observed working".

Ordered by risk. The first three are where a mistake would actually hide.

---

## 1. Skyboxes -- highest risk

The cube-map path changed in three places at once: the texture is created by a
merged procedure, uploaded by a merged procedure, and a `nil` check was removed
because the merged creator panics instead of returning nil.

- [ ] `examples/skybox` -- both formats draw, SPACE swaps them
- [ ] the cube map is not scrambled, mirrored, or seamed -- the face slicing and
      the `-x` flip were untouched, but the upload beneath them was rewritten
- [ ] the panorama still wraps with no seam down the sky
- [ ] your game's `Cubemap_Sky_15` still loads and looks as it did

**If something is wrong here** it will look like a wrong face in the wrong place
or a black cube, not a crash.

## 2. Animation clips -- memory

`read_vec3_owned` was deleted and its caller now passes `context.allocator` to
the merged `read_vec3`. If that argument were wrong, keyframe data would be
temp-allocated and freed underneath a playing clip.

- [ ] your game runs a full walk cycle without the character distorting after a
      few seconds
- [ ] switching clips repeatedly (walk, run, crouch, jump) stays stable over a
      minute or two
- [ ] quitting cleanly does not crash in `destroy_model`

**If this is wrong** the symptom is a character that animates correctly at first
and then folds up, or a crash on exit.

## 3. UI widgets -- twenty-two moved numbers

Every widget metric moved into `UI_DEFAULTS`. A mis-mapped field would put the
right number in the wrong place, which compiles fine.

- [ ] `examples/ui` -- buttons, text fields, scrollbars, dropdowns, sliders and
      text plates all look as they did
- [ ] scrollbar thumb is the right width and does not shrink below its minimum
- [ ] text field caret blinks, the focus ring is the right thickness, the
      password mask is still `*`
- [ ] a confirm button arms red and forgets after about three seconds
- [ ] dropdown rows have their hairline gap
- [ ] `examples/layout` and `examples/clipping` still lay out correctly

---

## 4. Cameras

Values were moved into `CAMERA3D_DEFAULTS`, not changed.

- [ ] `examples/first-person` -- walking and looking feel the same, pitch still
      stops just short of vertical
- [ ] `examples/third-person` -- orbit, zoom limits (1.5 to 20), the three
      shoulder settings, and the three steering modes
- [ ] your game -- strafe steering, right shoulder, distance 1

## 5. Fonts

The cache moved from two package globals into `mbi.font_cache`.

- [ ] text draws at the default size
- [ ] `get_font` at several sizes works, and asking for more than six sizes
      evicts the least recently used rather than growing forever or crashing
- [ ] `examples/draw-text`, `examples/render-text`, `examples/load-ttf-font`

## 6. Models and sprites

`upload_texture` was rewritten to call the shared region uploader.

- [ ] `examples/model` -- all four `.gltf` files load with their textures
- [ ] any 2D example -- sprites still draw with the right texture
- [ ] `examples/framebuffer` / `pixel_buffer` -- deliberately *not* merged, so
      this is checking it was left alone correctly

## 7. Shapes

`SHAPE_ELLIPSE` / `SHAPE_TRIANGLE` became a `Shape_Kind` enum converted at the
call site.

- [ ] `examples/shapes` -- ellipses are ellipses and triangles are triangles.
      Getting this backwards would swap them, which is very visible

## 8. Gamepad

- [ ] `examples/gamepad` -- sticks have their deadzone, triggers their threshold

---

## Not covered by any of the above

- **Android.** Nothing here is platform-specific, but nothing was built for it
  either
- **The five examples still on the old camera API** -- `lighting`, `model`,
  `post`, `primitives`, `skybox` -- are unchanged and still compile. Bringing
  them onto the rigs is Stage 6 of `cleanup.md` and was not started
