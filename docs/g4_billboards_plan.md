# G4: billboards (plan)

Written 2026-11-25. Status: **API approved 2026-11-25** (names kept, `screen_size` kept, unlit only, separate example). Implemented; checked on PC, Azahar and Vita3K; hardware builds are waiting for the user's check. Ticked below.
Source of truth for the phase: `render_plan.md`, "G4. Billboards" ("sprites facing the camera in a perspective scene;
they reuse E1"). Camera conventions are `docs/g3_cameras_plan.md`'s: world units, +Y up, right-handed, looking down -Z.

## What `main` has

Nothing. `git grep -i billboard main` finds no hit, in any branch's Odin code or in `main`'s docs; the only mentions
in the repo are `render_plan.md` and the handoff doc. There is nothing to port, so this is new design. The nearest
neighbours are `main`'s `Sprite` (2D only) and `Camera3D` (ported in G3).

## What this branch already gives G4

- `render_sprite` (`matchbox/sprite.odin`) builds `model = T(position) * R * S(size) * T(0.5 - pivot)` and calls
  `queue_render(mbi.sprite_mesh, ...)`. `mbi.sprite_mesh` is one shared 1x1 quad on all three targets, drawn **unlit**
  (`Mesh.lit` is false) with `Cull_Mode.NONE`. A billboard is therefore the same call with a different rotation; no new
  mesh, shader, pipeline or per-target renderer code.
- The queue already does the rest: `.CUTOUT` goes in the opaque list with depth tested and written (alpha test at 0.5; the
  PICA alpha test on the 3DS); `.BLENDED` is sorted farthest first by `-(mbi.view * model * origin).z`, tested and not
  written. That sort key is already correct for a billboard.
- `mbi.view` is set in `camera_start` on all three targets (`render_windows`, `render_3ds`, `render_vita`), so the draw
  call can read the eye position and the camera's right/up/back axes from it **without being handed a `Camera`**:
  for a view matrix `V = [R | t]`, the camera's axes are the rows of `R` and the eye is `-Rᵀt`.
- `Animated_Sprite` embeds `Sprite` with `using`, and `render_animated_sprite` only shifts `position` by the clip's
  `offset` before calling `render_sprite`. A billboard cannot shift in world x/y (the art would slide the wrong way once
  it turns), so the animated variant applies the same offset along the billboard's own right and up axes.

## Proposed public API (needs the user's approval)

New file `matchbox/billboard.odin` (shared by all targets, no GPU code) and `matchbox/billboard_test.odin`.

```odin
Billboard_Mode :: enum {
	UPRIGHT,         // turns about +Y only, toward the eye: trees, characters, lamp posts. Never leans.
	CAMERA_POSITION, // turns fully toward the eye: it stays square-on to you from any angle (flares, markers)
	CAMERA_PLANE,    // lies flat to the screen: the camera's own right and up, however far off-centre it is (particles)
}

Billboard_Settings :: struct {
	mode:Billboard_Mode,   // UPRIGHT; the zero value is the usual choice, so `Billboard_Settings{}` is the default
	screen_size:bool,      // keep the size on screen the same at any distance (one image pixel = one window pixel x scale)
}

// Draws a sprite as a billboard, between camera_start and camera_end. Same Sprite_Mode meaning as render_sprite
render_billboard :: proc(sprite:Sprite, settings := Billboard_Settings{}, mode:Sprite_Mode = .CUTOUT)

// Same, for animated sprites: flip_x, the frame and the clip's offset (applied along the billboard's right/up) all work
render_animated_billboard :: proc(sprite:Animated_Sprite, settings := Billboard_Settings{}, mode:Sprite_Mode = .CUTOUT)

// The model matrix render_billboard uses, for a game that wants to place its own mesh facing the camera
calculate_billboard_matrix :: proc(camera:Camera, position:[3]f32, size := [2]f32{1, 1}, settings := Billboard_Settings{}, roll:f32 = 0) -> matrix[4, 4]f32
```

No new constants, no globals, no callbacks, no `create_`/`destroy_` (nothing is allocated; a billboard *is* a `Sprite`).
`Sprite_Mode` stays the one place alpha is chosen, so a billboard takes `.CUTOUT` / `.BLENDED` exactly like a sprite.

### Behaviour, as decisions

- **Sprite fields keep their meaning.** `position` is the world position of the pivot, `pivot` works (`{0.5, 0}` stands a
  tree on the floor), `scale`, `tint`, `flip_x/y`, `frame`, `source` and `pixels_per_unit` are read as in `render_sprite`.
- **World size is the default.** Size is `frame_px / pixels_per_unit * scale` world units, so a billboard shrinks with
  distance like anything else. `screen_size = true` makes the size on screen constant instead: the world size is
  multiplied by `2 * distance * tan(fov_y / 2) / window_height` per image pixel (the distance is measured along the view
  axis, so it does not swell towards the screen edge). Perspective cameras only; with an orthographic camera it is a
  no-op, since distance changes nothing there. The window height is the target being drawn to (400x240 top screen on
  the 3DS, 544 on the Vita).
- **`rotation` is a roll** about the facing axis for `CAMERA_POSITION` and `CAMERA_PLANE`. It is **ignored** by `UPRIGHT`
  (an upright thing that rolls is no longer upright); the doc comment says so.
- **`UPRIGHT` uses world +Y**, not `camera.up`. If the eye is (almost) straight above or below the sprite there is no
  horizontal direction to face; it faces the way the camera is turned (back along the camera's own horizontal heading; +Z if that is also vertical) instead of producing NaN. `CAMERA_POSITION` uses the camera's right made perpendicular to the normal.
- **Depth and alpha:** nothing new. `.CUTOUT` (default) writes depth and needs no sorting, `.BLENDED` is sorted and does
  not write depth, so billboards and meshes interleave correctly with the existing queue. A blended billboard is
  sorted by its pivot position, which is the same thing blended sprites do now.
- **Lighting is off**, and stays off in G4: the shared sprite quad is an unlit mesh, and a lit billboard needs a lit
  quad mesh per target (normals toward the camera) and would be a G2 follow-up. Tint is the way to shade one by hand
  until then. Flagged as an open question below.
- **Not for the HUD.** In a screen pass (`screen_start`) `render_billboard` asserts, since there is no eye to face;
  `render_sprite` already does that job there.
- **Animated sprites:** the animated variant reads `frame` and `flip_x` as the sprite does, so `update_animation` needs
  no change. The offset note above is the only difference.

### Hand-worked values the tests will assert (maths done independently first, then numpy)

| Case | Eye / sprite | Expected rotation columns (right, up, normal) |
| --- | --- | --- |
| `CAMERA_PLANE`, camera `(0,0,5)` looking at the origin | any sprite | `(1,0,0)`, `(0,1,0)`, `(0,0,1)` = identity |
| `UPRIGHT`, eye `(4,0,0)`, sprite at origin | | `(0,0,-1)`, `(0,1,0)`, `(1,0,0)` |
| `CAMERA_POSITION`, eye `(0,5,5)`, sprite at origin | | `(1,0,0)`, `(0,.7071,-.7071)`, `(0,.7071,.7071)` |
| `UPRIGHT`, eye `(0,5,5)` | same eye as above | `(1,0,0)`, `(0,1,0)`, `(0,0,1)`: it does not lean |
| `UPRIGHT`, eye straight above | | finite, right = camera right |
| `screen_size`, 64 px image, fov 60, distance 10, window height 240 | | world height 3.0792 (2*10*tan30°/240*64) |
| roll of pi/2 on `CAMERA_PLANE` | | right `(0,1,0)`, up `(-1,0,0)` |
| `UPRIGHT`, eye moving 90° round the sprite | | normal always horizontal, always toward the eye |

Also: the model matrix equals `render_sprite`'s for `CAMERA_PLANE` with a camera looking down -Z (so the 2D path is a
special case of the 3D one), the queued item for a `.BLENDED` billboard has the expected `depth`, and `flip_x` still
swaps the uv.

## Per-target notes

| Target | What changes | Risk |
| --- | --- | --- |
| PC (D3D11) | nothing in the renderer; the sprite quad, cutout discard and blending already work | none beyond the numbers |
| 3DS | nothing in the renderer: sprite quad, PICA alpha test (cutout), blended list. The maths is `+ - * /` and one `sqrt` per billboard (a normalise); **no trig and no libm call**, so it stays clear of the soft-float libm shims (`exp` is the only G3 one). `UPRIGHT` costs one horizontal normalise, `CAMERA_POSITION` two cross products | the 400x240 screen is small, so `screen_size` is where pixel-for-pixel readability can be seen on the console. Stereoscopic 3D (deferred, C6) will want a billboard per eye later |
| Vita (GXM) | nothing in the renderer; same shared quad and pipeline | per-pixel cost is the existing sprite's; large blended billboards overdraw, as large blended sprites do |

All three read `mbi.view`, so no `Camera` has to be threaded through `render_billboard`, and the maths is shared in
`billboard.odin`.

## Steps

- [x] G4-1. Read the code, search `main`, write this plan.
- [x] G4-2. **User approves the public API** (proposal with this file). Nothing below starts before.
- [x] G4-3. `billboard.odin`: the rotation / size maths from a view matrix, `calculate_billboard_matrix`, `render_billboard`,
  `render_animated_billboard`. Doc comments say why (UPRIGHT vs +Y, the roll rule, the offset axes).
- [x] G4-4. `billboard_test.odin`: the table above as assertions on numbers worked out by hand (not checked against numpy); queue-level tests
  with synthetic `mbi` state (the existing `render_test.odin` shows how).
- [x] G4-5. `examples/billboard-check`: a floor, a ring of upright billboards (a tree strip and an animated coin, three modes
  side by side), a blended one, a `screen_size` one, the orbiting/walking `Third_Person_Camera` from G3 to move round them.
  It runs a self-check of the matrix numbers on the target at start and prints `billboard-check: N passed, M failed`
  (the `camera-check` pattern, so the 3DS soft-float maths is exercised on the device).
- [x] G4-6. `odin check` for matchbox, level, tether, eko; `odin test matchbox`; `3ds_check.bat` and `vita_check.bat` for the
  example; regenerate `cheatsheet.md` only if the branch has the generator (it covers `main` only today).
- [x] G4-7. Run in Azahar (3DS) and Vita3K; read the self-check lines.
- [ ] G4-8 (builds done, committed; **waiting for the user's hardware check**). Hardware builds with their own names, `billboard_check_g4.3dsx` and `billboard_check_g4.vpk`, copied to the main
  checkout's `build\hardware\`. Commit, do not push. Then **wait for the user's hardware check**.

## Open questions for the user

1. **Names and modes.** Is `UPRIGHT / CAMERA_POSITION / CAMERA_PLANE` the vocabulary you want? (Alternatives: `CYLINDRICAL /
   SPHERICAL / SCREEN_ALIGNED`.) `UPRIGHT` is the zero value, i.e. the default.
2. **`screen_size` as a bool in the settings**, or left out of G4 (world size only)? It is cheap, and it is the only thing
   that makes a 3DS 400x240 marker readable at any distance, but it is the one part with no precedent in `main`.
3. **Lit billboards:** unlit only in G4 (proposed), or add a lit quad later as a G2 follow-up?
4. **Example:** extend `camera-check` or a separate `billboard-check` (proposed: separate, so it has its own hardware
   build name and does not make `camera-check` longer)?

## Answers (2026-11-25) and deferred

1. Names kept: `UPRIGHT / CAMERA_POSITION / CAMERA_PLANE`. 2. `screen_size` kept. 3. Unlit only; **lit billboards are deferred** (a lit quad with a
camera-facing normal, per target; also recorded in `docs/g2_remaining_work.md`). 4. Separate `examples/billboard-check`.

## What was done and how it was checked (2026-11-25)

- `matchbox/billboard.odin`, `billboard_test.odin` (15 numeric tests, 164 in the package pass), `examples/billboard-check` (13 on-target checks).
- `Matchbox_Info` gained `camera_fov_y` and `camera_window_height`, set in each target's `camera_start`, because `screen_size` needs the
  fov and the height of the target being drawn to (the 3DS bottom screen is not the top one). `sprite.odin` shares its uv and blend
  helpers with the billboards; `render_sprite` draws exactly as before (a test compares the two).
- `vita_build.bat` did not stage a game folder's own `assets\` (the 3DS script does); without it the example's images never reached the
  .vpk. Added the same block (images, audio, models).
- Run: PC (13/0, screenshot), Azahar (13/0, 60 FPS, scene drawn), Vita3K (13/0, scene drawn). **Not run on a real 3DS or Vita.**
- `level`, `tether` and `eko` do not exist on this branch (they are `main`'s), so their `odin check` could not be run.
- The test lock `render_queue_lock` in `collision_test.odin` is no longer file-private: the billboard tests queue items too. `mbi` is
  one global on this branch (CLAUDE.md's thread-local note describes `main`).

## Hardware findings, round 1 (2026-11-26) and the g4b build

1. **"CAMERA_POSITION goes the opposite way" -- not reproduced; the maths is right on every target we can run.** Nothing in the code was
   changed for it. What was measured: `every_mode_faces_the_eye_from_every_side_through_the_real_view` (billboard_test.odin) sweeps the eye
   round the sprite at three heights, with the camera aimed at it and aimed away from it, and asserts, for each mode, that the
   normal is the eye direction (position) / the camera's back (plane) / the horizontal eye direction (upright), that the right
   edge is on the screen's right, that up is not upside down and that the basis is not mirrored. The example runs the same
   sweep on the target through the real `camera_start` -> `render_billboard` -> `mbi.opaque_items` path ("through the queue", 16 checks): 16/0 on PC, Azahar and
   Vita3K. Every backend uploads `item.model` unchanged, as for models. So a billboard that faces the wrong way on hardware is not a maths or
   matrix-upload error that an emulator can show. Two things it may be, both for the user to say:
   - the 3DS circle pad and C-stick were drifting (round 1's second finding): a camera that yaws on its own while the character creeps looks
     like billboards turning the wrong way. Fixed below; the g4b HUD shows the stick values;
   - what "square" means. `CAMERA_POSITION` faces the **camera's eye**, which in the third person scene is behind and above the
     character, not the character; and in perspective a quad facing the eye looks turned relative to the screen when it is off to one
     side. A screen-parallel look is `CAMERA_PLANE`. If the user wants billboards to face the player, that is a different mode (a target
     position), not a bug.
   The g4b HUD line "middle faces the eye: x.xx" is that billboard's normal dotted with the direction to the eye, read from the queued
   matrix on the console; 1.00 means it faces the eye exactly.
2. **3DS stick drift: fixed.** `poll_events` (3DS) took the circle pad and C-stick as libctru gives them, scaled by 156 / 146. A pad rests a
   few counts off zero (about 15, which is 0.096), and nothing cut that off, so `get_movement_input` and the look read saw it on every frame.
   `get_thumbstick_value` does not latch anything: it returns the value of the current frame. New `Thumbstick_Settings.dead_zone` (0.15, in `mbi`'s declaration) and
   `calculate_thumbstick_dead_zone` (matchbox/thumbstick.odin): a circular dead zone with the rest of the travel stretched back to 0..1, applied
   to both sticks after the diagonal clamp. Tested on PC with the rest values (15/156 on either axis and diagonally), the stretch and full travel; **not
   measured on a real pad**: whether 0.15 covers this user's pad is what the hardware check shows (the HUD prints both sticks). The Vita
   already has a dead zone in vito; PC's XInput path has none and was not reported, so it is untouched.
3. `screen_size` is in window pixels, so a marker covers a larger share of the 3DS top screen (400 wide) than of the Vita's (960): expected, now in the example's header.

## 3DS crash of g4b (2026-11-26): bisect builds

`billboard_check_g4b.3dsx` crashed on a real New 3DS LL; `g4` ran; Azahar ran both. The difference is e7590e6. The suspect is the new first-frame
sweep: it called `camera_end` 216 times, so 216 real draws in one frame (a normal frame here is a few dozen), where Azahar is forgiving about a
full command buffer and hardware is not. **This is a hypothesis; the cause is not confirmed until the console runs g4d.** The builds, each one change
from g4b (all in `build\hardware\`):

| Build | Differs from g4b by | If it runs | If it crashes |
| --- | --- | --- | --- |
| `billboard_check_g4d.3dsx` | the sweep is kept but never drawn (`mbi.discard_pass = true` after each `camera_start`) | the 216 draws were it; this is the committed fix | not the draws: go to g4c |
| `billboard_check_g4c.3dsx` | no sweep at all (dead zone and HUD lines kept) | the sweep, drawn or not, is it | the dead zone or the new HUD lines: go to g4e |
| `billboard_check_g4e.3dsx` | g4c with the dead zone also removed | the dead zone was it | only the new HUD lines are left |

Azahar: g4d prints "through the queue, 16 passed, 0 failed". The committed example is g4d's. Nothing was found by reading the dead-zone code (a guard
on zero length, no trig, the `sqrt` was already in that path).
