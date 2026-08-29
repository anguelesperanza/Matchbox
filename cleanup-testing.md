# Cleanup -- what was checked

Run 2026-08-29 against the `cleanup` branch. **72 of 72 assertions passed**, all
24 examples build, 20 of them ran under Vulkan validation with nothing reported,
and `games/third-person-game` builds and runs against the branch unchanged.

The strongest result is the one that mattered most: uploaded textures were
**pulled back off the GPU and compared byte-for-byte against the pixels that
went in**, which turns "the merged uploader works" from a hope into a fact.

**What is still unverified: how any of it looks.** Nothing here inspects a
rendered frame. Texture readback is stronger than looking for the skybox, and
the numbers behind the UI and the cameras are all confirmed -- but no one has
watched a widget draw or a character animate on screen since the refactor.

---

## 1. Skyboxes -- verified by readback

The cube path changed in three places at once: a merged creator, a merged
uploader, and a removed `nil` check.

- [x] all six cube faces read back off the GPU and compared against their cells
      in the source cross -- **0 mismatched pixels of 262,144, on every face**
- [x] `+Y` is brighter than `-Y` (176 vs 79), so sky is up and ground is down --
      the face ordering survived
- [x] the panorama read back against its source -- **0 mismatched of 2,097,152**
- [x] `examples/skybox` builds and runs under validation with nothing reported

That covers `create_gpu_texture(cube = true)`, `upload_texture_region` for a
cube layer, and `upload_texture` for a plain 2D texture, which is the whole of
what the merge touched.

## 2. Animation clips -- memory

`read_vec3_owned` was deleted and its caller now passes `context.allocator`.

- [x] the model loads: 80 nodes, 13 skins, 66 joints, **31 clips**
- [x] a palette sampled at a fixed time is bit-identical before and after
      **1,240 clip switches** -- a temp-allocated keyframe would have drifted
- [x] a blend still lands exactly on its destination: a blended and an
      un-blended animator agree to **0.000000** once the fade ends
- [x] the blend switches itself off at the end
- [x] `games/third-person-game` runs against the branch and prints all 31 clips

## 3. UI widgets -- twenty-two moved numbers

Each one asserted against the value its constant held before the move.

- [x] all 22: button dim, hover dwell, status fade, slider handle, the three
      confirm values, the three plate values, the six text-field values, the
      four scroll values, the two dropdown values
- [x] `BUTTON_STYLE` still reads the shared dim, and its padding is unchanged
- [x] `examples/ui`, `examples/layout`, `examples/clipping` run clean

## 4. Cameras, and the five ported examples

- [x] every `CAMERA3D_DEFAULTS` field matches the constant it replaced
- [x] each ported example opens at its **exact** old eye position:
      `lighting`/`post` at `{0, 1.8, 5}`, `model` at `{-2, 5, 18}`,
      `primitives` at `{0, 1.7, 10}`, `skybox` at `{0, 1.7, 6}`
- [x] and looks the same way: the reconstructed pitch gives a view direction
      matching the old position-and-target pair to 1e-7
- [x] `third_person_camera()` seeds from the defaults, steering and shoulder
      unchanged
- [x] all five ported examples run clean under validation

## 5. Fonts

- [x] `FONT_DEFAULTS` values unchanged
- [x] asking for nine sizes leaves **six** in the cache -- eviction still works
      through `mbi.font_cache`
- [x] `draw-text`, `render-text` run clean; `load-ttf-font` builds

## 6. Models and sprites

- [x] `examples/model` runs clean, all props load
- [x] `examples/framebuffer` runs clean -- the `pixel_buffer` path deliberately
      left out of the upload merge
- [x] 2D examples (`camera-2d`, `outline`, `ClickCoin`, `random-walk`) run clean

## 7. Shapes

- [x] `Shape_Kind.ELLIPSE` is still 0 and `.TRIANGLE` still 1, which is what the
      fragment shader switches on
- [x] `examples/shapes` builds and runs with nothing reported

## 8. Gamepad

- [x] `GAMEPAD_DEFAULTS` values unchanged
- [x] `examples/gamepad` runs clean

---

## Notes

- Four examples -- `TankMovement`, `load-ttf-font`, `pong`, `shapes` -- failed
  in the batch runner and then built and ran fine in place. The runner copies an
  example to a scratch directory, which breaks the relative path a `#load`
  resolves against. A harness artifact, not a finding
- The model moved: it is `assets/vroid/retargeted_animations.glb` now, not
  `exported-model.glb`, and carries 31 clips rather than 5
- **Android was not built.** Nothing in the refactor is platform-specific, but
  nothing here proves that
