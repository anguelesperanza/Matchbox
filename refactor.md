# Refactor notes

A running file for the eventual big pass, so the reasoning behind decisions
made along the way doesn't have to be re-derived. Add to this as new areas
come up rather than starting a second file -- one place to check before
touching something load-bearing.

---

## 2D and 3D: the split is deliberate, not drift

**Origin:** Matchbox started 2D-only; 3D was added later for a separate
project. The two render paths ended up wholly separate, which read as
unplanned duplication worth collapsing -- reviewed 2026-09-04 and concluded
otherwise. Notes here so the question doesn't get re-opened from scratch, and
so a refactor that touches rendering knows which differences are the point.

### How the two actually work

**2D** has no camera matrix at all. `Camera` (`camera.odin:11`) is `position`
+ `zoom`; `screen_pos` / `screen_size` (`display.odin:53-79`) apply it on the
CPU along with the fixed-res letterbox scale and offset, so what reaches the
GPU is already a pixel coordinate. `quad.vert.hlsl` takes that straight in a
uniform, expands one shared unit quad (uploaded once, `render.odin:105`), and
does a single divide-by-screen-dims to NDC. No per-sprite vertex buffer, no
depth, no projection matrix. Sprites, rects, outlines and glyphs are all "the
same quad, described differently" -- which is what lets the bind-cache draw a
screen of 2000 rects as one pipeline bind (`render.odin:126-136`).

**3D** has real vertex buffers per mesh part, a genuine view-projection matrix
from `Camera3D`, a depth buffer, back-face culling, and its own render pass.
SDL3_GPU bakes target formats into a pipeline at creation time
(`render3d.odin:8-13`), so a depth-tested mesh pipeline and a colourless 2D
pipeline cannot be the same object -- that boundary is a backend constraint,
not a style choice.

### Why "make everything 3D, render 2D as a flattened/orthographic 3D scene"
### was rejected

Looks like it removes duplication; costs more than it saves:

- Every sprite/UI-only game would pay for a depth buffer and culling it never
  uses. `render3d.odin:11-13` says this was avoided on purpose: giving the 2D
  pipelines depth "would mean rebuilding every one of them and handing a game
  that draws nothing but sprites an 8MB depth buffer to go with it."
- 2D's sort order is pure painter's-algorithm today -- draw order is the
  order things composite in, and `begin_clip`/`end_clip`'s scissor stack
  (`clip.odin`) is a screen-space concept. Depth-tested quads trade that for
  z-fighting concerns that were never a 2D problem to begin with.
- The letterbox + high-DPI + zoom math in `screen_pos` doesn't disappear under
  an orthographic matrix -- it has to be re-encoded into one, which is more
  indirection for exactly the case (pixel art, the 13px-em font, see
  `CLAUDE.md`) that most wants pixel-exact placement.
- The shared-quad-plus-uniform-push trick has no per-quad vertex buffer today.
  Folding sprites into the 3D mesh path means either a real VBO per quad or an
  instancing scheme that does not exist yet -- more machinery, not less.

**Conclusion: keep the render-path split.** If a future refactor pass revisits
this, re-read the four points above first -- they were the reason, not an
oversight to fix.

### Where real, cheap overlap does exist

Small and already mostly realised, not a case for merging the render paths:

- The two animation systems (`animation.odin` 2D, `animation3d.odin`
  skeletal) mirror each other in shape on purpose --
  `update_animation`/`update_animator`, and now `playing`/`looping` on both
  (added 2026-09-04, see the 2D-animation-finished work). Same vocabulary,
  no shared machinery forced between them. This is the right amount of
  overlap -- keep extending it by analogy rather than trying to unify the
  types.
- `Camera` (2D) and `Camera3D` could likely share a couple of small concepts --
  `Camera` has `follow_speed` for a lerp-follow that `Camera3D` may want too.
  Worth a look, but as a small shared-field/behaviour question, not a
  render-path merge. **Not yet investigated in depth.**

### Places to check when a rendering refactor does happen

- `render.odin` / `render3d.odin` -- the pass-per-mode split and the pipeline
  bake constraint from SDL3_GPU (`render3d.odin:8-13`) that forces it.
- `display.odin` -- `screen_pos`/`screen_size`/`screen_dims`, the CPU-side
  letterbox + camera math that 2D leans on entirely.
- `shaders/quad.vert.hlsl` -- the one 2D vertex shader every 2D draw shares;
  any change to VertData's field order must stay byte-for-byte matched with
  `matchbox.VertData` in `types.odin`.
- `camera.odin` vs `camera3d.odin` -- candidate for a small shared-concept
  pass (see above), not a merge.
- `clip.odin` -- scissor-stack clipping is a 2D/screen-space concept; check
  whether a refactor plan assumes it also covers 3D (it doesn't today).

---

## Scope: Matchbox is rendering + input only

Matchbox was originally meant to be an all-encompassing game framework.
Scope was later narrowed to rendering and input, with physics, audio, and
an event system meant to arrive as separate packages once they exist.
Reviewed 2026-09-04 for what has crept in under the old, wider scope and is
still sitting here.

**No event system exists today**, which is correct and worth confirming stays
true -- the only `Event` in the package is `sdl.Event`, polled internally by
`input.odin` / `gamepad.odin` / `touch.odin` to fill in `Input`'s own
per-frame snapshot. It is never exposed as a subscribe/publish API. If a
future change starts threading callbacks or a message queue through here,
that is the event package's job, not this one's.

**Files to move out once their destination package exists:**

| file | lines | what it is | destination |
|---|---|---|---|
| `sound.odin` | 40 | WAV load/play via SDL audio | audio package |
| `collisions.odin` | 41 | grid-index helpers + `mouse_over_sprite`; no actual collision detection despite the name | **confirmed for removal** -- physics package, once it exists (keep `mouse_over_sprite` here -- see below) |
| `tiled.odin` | 242 | Tiled (TMJ) JSON map-format parser | a content/level package |
| `procedural_generation.odin` | 64 | drunkard's-walk cave/maze generator; its own comment already says "rendering data must be done on a game by game basis" | a world-gen or content package |
| `timer.odin` | 40 | `CooldownTimer` -- `clock.odin`'s own comment calls this "a gameplay utility built on top of delta_time" as distinct from engine timing | a gameplay-utility package |
| `lerp.odin` | 43 | `LerpMove`, position tweening | a gameplay-utility package |
| `look_at.odin` | 41 | angle-to-face-a-target math; draws nothing, reads no input | a gameplay-utility package |

**`maps.odin` (16 lines) is a clean delete regardless of the above** -- it is
an empty placeholder whose own comment says "WIP as may not need and may
remove... reminder to fill this out or to delete this later." Nothing
references it. This one doesn't need a destination package decided first.

**Judgement calls, not scope creep -- checked and left alone:**

- `ui.odin` / `layout.odin` -- widgets and layout combine `draw_rect`/
  `draw_text` with hit-testing and click, which is rendering *and* input
  together -- the stated scope, not beyond it.
- `destroy.odin` -- dispatches `destroy_*`, but every type it covers is a
  rendering resource (`Mesh`, `Sprite`, `Font`, `AnimationClip`,
  `Sprite_Cache`). Lifecycle management for rendering resources, not new
  scope.
- `files.odin` -- cross-platform asset reading (the reason textures, models
  and fonts load correctly inside an Android apk). Rendering's own loaders
  depend on it directly, so it stays as infrastructure under rendering.
- `collisions.odin`'s `mouse_over_sprite` specifically -- legitimate
  input+rendering hit-testing, the same family as `mouse_over_rect` in
  `ui.odin`. If `collisions.odin` itself moves out, carry this one proc
  along to wherever sprite-related input helpers end up rather than to the
  physics package.

**`collisions.odin` is not the only collision code -- it's the smallest of
three.** Confirmed 2026-09-04: the actual AABB tests live in `sprite.odin`,
not the file named for them --

- `sprite.odin:307` `sprite_world_collision` -- clamps a sprite to the
  letterboxed visible area.
- `sprite.odin:327` `bounding_box_collision_check` / `sprite.odin:338`
  `bounding_box_contact_check` -- the actual overlap tests, strict and
  touching-counts respectively.
- `tiled.odin:134,161` `tiled_resolve_x_collision` /
  `tiled_resolve_y_collision` call straight into those two `sprite.odin`
  procs to resolve a body against a Tiled level's object layer.

So when the physics package gets built, the three collision procs above move
out of `sprite.odin` alongside `collisions.odin`'s contents -- and
`tiled_resolve_x_collision` / `tiled_resolve_y_collision` in `tiled.odin` go
with them or need a new way to reach the physics package's replacement,
since they call these by name today. Moving `collisions.odin` alone and
leaving `sprite.odin`'s share behind would just relocate the mislabeling
rather than fix it.

**Not yet audited:** whether `gltf2` (vendored glTF loader) or the `android`
build tooling carry anything outside rendering/input scope -- both are large
enough that they want their own pass rather than a guess here.

---

## File organization: procedures living in the wrong file

Reviewed 2026-09-04, prompted by noticing `draw_text_*` lives in `font.odin`
rather than `text.odin`. That one is the clearest case, but not the only one.

### Confirmed -- same fix as `draw_text_*`, no design call needed

**`font.odin` should hold the `Font` type and asset management only; every
`draw_text`/`measure_text` procedure belongs in `text.odin`.** Right now
`font.odin` has both halves: `Font`, `load_font`, `destroy_font`,
`Font_Cache`/`get_font` and the `font_cache_*` eviction machinery (asset
management, matches the filename) *and* `draw_text_i64`, `draw_text_2_i64`,
`draw_text_2_float`, `draw_text_float`, `draw_text_string`, the `draw_text`
group itself, `measure_text`, `draw_text_ui_string`, `draw_text_ui_int`,
`draw_text_ui_f32`, the `draw_text_ui` group, and the private `trim_plus`
helper those lean on (`font.odin:107-299`). `text.odin` already exists as
the "drawing and measuring text" file -- it has `wrap_text`,
`draw_text_wrapped`, `draw_text_lines`, `measure_text_wrapped`,
`text_block_height`, `line_height` -- and even calls `draw_text` and
`measure_text` from inside itself (`text.odin:187-188`, `204`) despite them
living one file over. Move the block wholesale; nothing about it reads
`Font`'s private baking machinery, only the public struct fields.

**`destroy_animated_sprite` lives in `destroy.odin` instead of
`animation.odin`.** Every other `destroy_X` sits beside its type's
constructor -- `destroy_sprite` in `sprite.odin`, `destroy_font` in
`font.odin`, `destroy_model` in `model.odin`, `destroy_skybox` in
`skybox.odin`, `destroy_animator` in `animation3d.odin` -- and `destroy.odin`
itself says as much: *"every type that owns something has its own destroy_
procedure, and they are all still here."* Except this one, which is
implemented directly in `destroy.odin:54` rather than in `animation.odin`
beside `create_animated_sprite` / `animated_sprite_of` /
`destroy_animation_clip`. `destroy.odin` should hold only the `destroy ::
proc{...}` dispatch group; every body behind it, including this one, should
live with its type.

### Worth a look, lower priority

- **`sprite_forward_by_rotation`** (`sprite.odin:346`) and **`look_at_point`
  / `look_at_sprite`** (`look_at.odin`) are inverses of each other -- one
  reads a sprite's rotation and returns the direction it faces, the other
  reads a target and returns the rotation needed to face it -- split across
  two files. Not as clear-cut as the two above since `sprite.odin` is a big
  file already and `look_at.odin` is slated to leave for a gameplay-utility
  package anyway (see the scope section above); worth deciding where
  "facing direction" math lives as one thing when that package gets built,
  rather than moving it twice.

### Large files that may want splitting along their own section boundaries

Not misplacement -- these files are internally organized already, just long
enough that finding a specific widget or rig means scrolling past several
others that happen to share the file:

- **`ui.odin`, 2083 lines.** Already reads as separate widget families back
  to back: buttons, confirm-button, hover, text field, scroll view,
  dropdown/context menu, tooltip, status line, modal, slider, progress. Each
  section is already self-contained (its own struct, style struct and
  procedures) -- splitting along those boundaries (`ui_button.odin`,
  `ui_text_field.odin`, `ui_scroll.odin`, `ui_dropdown.odin`, ...) would cost
  nothing behaviourally.
- **`camera3d.odin`, 1136 lines.** Core `Camera3D` (position, projection,
  view) plus two fully worked-out rigs, `First_Person_Camera` and
  `Third_Person_Camera`, each with its own struct, constructor and
  input/walk/follow procedures. A natural three-way split
  (`camera3d.odin`, `first_person_camera.odin`, `third_person_camera.odin`).
- **`init.odin`, 800 lines.** Mixes app lifecycle (`init`, `cleanup`,
  `is_running`, `wait_idle`) with one-time shader/pipeline construction
  (`create_builtin_shader`, `Vertex_Layout`, `create_pipeline`,
  `load_shader`, `write_gpu_report`). The latter half doesn't depend on the
  former beyond both running once at startup -- a `pipelines.odin` could
  hold it, leaving `init.odin` as just the lifecycle.

None of these three are urgent; they're organization, not a bug or a scope
violation. Flagged so the big pass has a ready-made list rather than having
to rediscover the section boundaries from scratch.
