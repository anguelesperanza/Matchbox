# Refactor notes

A running file for the eventual big pass, so the reasoning behind decisions
made along the way doesn't have to be re-derived. Add to this as new areas
come up rather than starting a second file -- one place to check before
touching something load-bearing.

---

## Decisions taken, 2026-09-04

Settled. The reasoning behind each is in the section named alongside it;
anything in this file *not* listed here is still open.

| area | decision |
|---|---|
| naming | Procedures `snake_case`; types (struct/enum/union) `Pascal_Snake_Case`; enum **values** `SCREAMING_CASE`, one per line. Now in `CLAUDE.md`; see **B. Naming drift** |
| `README.md` | **Stays.** Gets its own refactor later, once more of the above is settled |
| input enums | **Lean on SDL3's own values, don't wrap them.** Drop the custom `Mouse_Button`; see **A. Structural** |
| `Body` physics fields | **Keep.** Storage-only *by intent* -- games read and write them per-game. Not dead code; see **D** |
| `examples/TankMovement` | Bring in line with the other examples; `src/` is not used any more; see **E** |
| finished markdown | Deleted -- see below |
| code organisation | Group logically; the moves in **File organization** and the file splits stand |
| constructors / destructors | `create_x` and `destroy_x`; `load_x` reserved for importing a thing that already exists. See **Decisions, round two** |
| errors | Return `(value, err)` like `core:os`; replaces `ensure`. See **Decisions, round two** |
| caches | One generic LRU, carrying `Font_Cache`'s frame guard |
| `tiled.odin`, `procedural_generation.odin`, `maps.odin` | **Deleted** -- moved to other packages, or empty |
| `timer` / `lerp` / `look_at` | Fold into `utility.odin`, re-review later |
| `gltf2`, Android tooling | Keep; own re-review after this refactor |
| predicates / getters | `is_` on procs returning `bool`, `get_` on procs returning stored data; verbs and computations keep their names |
| `camera_follow`, parallax | **Build both.** See **Decisions, round two** |
| SDL3 / SDL3_GPU | Stay, unless the rendering backend itself changes |
| 2D / 3D render split | Stays as it is |

### Markdown removed, 2026-09-04

Deleted because the work they describe is finished and they were never
anything but plans for it. All recoverable from git history if a piece of the
reasoning is wanted back:

- `sdl3-gpu-migration.md` -- the no_gfx_api → SDL3_GPU migration, done.
- `cleanup.md` -- the previous cleanup/refactor pass, done. (`CLAUDE.md`'s
  pointer to it now points here instead.)
- `cleanup-testing.md` -- the by-hand test checklist for that same pass.
- `3d.md` -- the "adding 3D to Matchbox" plan. 3D is built. Note it also
  carried a risk register and a "not doing, and what each would take"
  section; if that list is still wanted, lift it out of git rather than
  restoring the whole file.
- `candidates.md` -- the intake list of things a game had written for itself.
  Every entry is DONE, "probably not" (decided against), or "already done".

**`improvements.md` stays, trimmed -- done.** The `# Completed` log was cut
separately, leaving only the live `# Not Started` backlog (the clip-aware hit
test, batching quads into one draw, the window-sizing entry, reducing system
usage) and the Android account `README.md` links into.

One dangling cross-reference went with the cut and has been repaired: the
batching entry pointed at "the Completed entry" for the removal of redundant
binds, which no longer exists. It now says what happened instead of pointing
at where it used to be written down -- the same repair the deleted planning
documents needed.

## Decisions, round two (2026-09-04)

The second pass of answers. Together with the table above, this leaves nothing
open.

### Constructors: `create_x`, and `load_x` means something different

`create_x` is the constructor, where `x` is the thing being made --
`create_sprite`. `load_x` is *not* a synonym for it: `load_model` imports a
thing that already exists whole, where `create_sprite` only imports the image
and leaves the rest of the values to be set here. Keep that distinction.

So the renames are: `sprite_cache_make` → `create_sprite_cache`,
`layout_make` → `create_layout`, `camera3d_at` → `create_camera3d`,
`transform_at` → `create_transform`, `first_person_camera` /
`third_person_camera` → `create_first_person_camera` /
`create_third_person_camera`, `point_light` / `directional_light` →
`create_point_light` / `create_directional_light`, `grid_fit` →
`create_grid`, and the `cube_model` / `plane_model` / `sphere_model` /
`cube_wires_model` / `grid_model` family → `create_cube_model` and so on.

`sprite_of` and `animated_sprite_of` build from a thing already in hand (a
`Mesh`, an `Animation_Clip`), and there is already a `_from_` suffix in the
package for exactly that -- `create_sprite_from_pixels`,
`create_mesh_from_pixels`. So: `create_sprite_from_mesh` and
`create_animated_sprite_from_clip`.

### Destructors: always `destroy_x`, and into the group

`destroy_x`, never `x_destroy`. So `sprite_cache_destroy` →
`destroy_sprite_cache`, `font_cache_destroy` → `destroy_font_cache`,
`shapes3d_destroy` → `destroy_shapes3d`.

**Every new `destroy_x` goes into the `destroy :: proc{...}` group** in
`destroy.odin`, so a game can call `matchbox.destroy(&thing)` and let the
compiler pick. One caveat to apply with judgement: `font_cache_destroy` and
`shapes3d_destroy` are `@(private)` and called by `cleanup`, not by games --
they still get renamed, but a private procedure has no business in a group
whose whole purpose is to be called from outside.

### Errors: return them, don't `ensure`

Follow the shape `core:os` uses -- return the value *and* an error, and let
the caller decide:

```odin
some_proc :: proc() -> (data: Data, err: Err)

result, err := some_proc()
if err != nil {
	// deal with it
}
```

The error type is whatever the situation calls for. Note `err != nil`
implies a `union` rather than an `enum` -- an enum would want `.None` and a
`err != .None` test -- so the error types here should be unions.

**This replaces the `ensure(...)` calls**, which currently abort the process
on a failure the caller was never given the chance to handle. Where the
failure comes from something we don't control and it reports differently --
an SDL call returning `bool` -- use whatever convention that thing offers
rather than wrapping it.

Worth knowing before starting: this is the widest-reaching change on the
list. `create_sprite`, `create_mesh`, `upload_buffer`, `create_gpu_texture`
and the rest currently return a bare value, so every call site in the package,
every example, and the README's front-page snippet all change shape with them.

### Caches: one LRU, with the frame guard

Unify `Sprite_Cache` and `Font_Cache` onto one generic LRU, and the unified
one carries `Font_Cache`'s frame guard -- nothing asked for during the current
frame is ever what gets evicted. That closes the `Sprite_Cache` hole where a
second `get` in a frame can free what the first one returned.

### Files leaving now

- **`tiled.odin` -- deleted.** Moved out to a package that will handle Tiled,
  LDtk and other level formats together. No example used it, so nothing else
  went with it.
- **`procedural_generation.odin` -- deleted**, along with
  `examples/random-walk`, which was its only caller. The code now lives in
  `DreamCartographer/2d/randomwalk/randomwalk.odin`.
- **`maps.odin` -- deleted.** The empty placeholder.

### Files staying, in a utility file

`timer.odin`, `lerp.odin` and `look_at.odin` fold into a single
`utility.odin`, **marked for re-review after this refactor** rather than
moved out now.

Measured before deciding, since the question was whether removing them would
cost anything (hits inside `games/farlite-test/Matchbox/` are a vendored copy
of this repo and don't count):

| file | real use | verdict |
|---|---|---|
| `timer.odin` | `games/rpg-rougelike/main.odin` uses `start_cooldown`, `update_cooldown`, `is_cooldown_done` | **in live use** -- removing it breaks a real game |
| `lerp.odin` | nothing, anywhere | dead weight, but harmless |
| `look_at.odin` | only `examples/TankMovement` | near-dead |

So `timer.odin` is the one with an actual customer; the other two are being
kept on the strength of being small rather than used.

### Sprite math lives in `sprite.odin`

Any math that acts on a sprite goes in `sprite.odin`. That settles the
`look_at` split: `look_at_sprite` moves to `sprite.odin` next to
`sprite_forward_by_rotation` (its inverse), and `look_at_point` -- which takes
two plain vectors and knows nothing about sprites -- goes to `utility.odin`
with the rest.

### Marked for later, deliberately

- **`gltf2`** -- an external package brought in. Stays; **re-review after this
  refactor** to bring it in line with Matchbox conventions.
- **The Android build tooling** -- wants an audit of its own, after this
  refactor.

### `improvements.md`

Keep whatever is still an improvement waiting to be made; remove everything
else. That means the `# Completed` log goes.

### Predicates and getters: `is_` and `get_`

`is_` on procedures returning a `bool`; `get_` on procedures returning data.
This does not touch `create_x` / `load_x`, which have their own rule above.

The renames that follow, grouped so the sweep can be done in one pass:

**To `is_`** -- `cursor_locked`, `touch_active`, `lighting_active`,
`mouse_captured`, `scroll_needed`, `confirm_button_armed`, `dropdown_is_open`,
`modal_is_open`, `model_is_skinned`, `in_drawing_3d`, `sprite_cache_has`,
`point_in_rect`, `mouse_over_rect`, `mouse_over_button`, `mouse_over_sprite`,
`mouse_over_text_field`, `bounding_box_collision_check`,
`bounding_box_contact_check`, `modal_dismissed`.

**To `get_`** -- `delta_time`, `frame_count`, `screen_dims`, `status_text`,
`scroll_max`, `text_field_string`, `sprite_cache_len`, `font_cache_len`,
`current_target_size`, `base_path`, `pref_path`.

**Two carve-outs**, now written into `CLAUDE.md`, because both prefixes
describe *reading* and some procedures are not reads:

1. **Immediate-mode procedures that act and report** keep their verb.
   `button` draws a button and answers whether it was clicked -- `is_button`
   would describe it wrongly. Same for `button_confirm`, `dropdown`,
   `context_menu`, `slider`, `slider_int`, `modal_begin`, `hover_dwell`, and
   `play_animation` (which returns whether the clip was found).
2. **Computations are not getters.** `measure_text`, `measure_text_wrapped`,
   `wrap_text`, `line_height`, `text_block_height`, `rect_center`,
   `rect_top_left`, `model_center`, `model_size`, `sprite_bounds`,
   `sprite_center`, `screen_pos`, `screen_size`, `camera3d_forward`,
   `direction_from_angles`, `walk_direction`, `look_at_point`, `dimmed`,
   `slider_snap`, `hover_progress` and `status_alpha` all derive an answer
   from their arguments rather than fetch a stored one. `get_measure_text`
   would say the opposite of what it does.

The line is *reading stored state* versus *doing* or *deriving*.

### Build both: camera follow and parallax

**`camera_follow`.** Build it, so the easing maths lives in one place rather
than being re-remembered at each call site:

```odin
camera_follow :: proc(target: [2]f32, delta_time: f32)
// mbi.camera.position += (target - mbi.camera.position) * follow_speed * delta_time
```

`follow_speed` on `Camera` is what it reads. Recommended to give `Camera3D`
the same treatment in the same pass -- `camera3d_follow` currently snaps
straight to the orbit position with no damping term -- though that half was
not explicitly decided.

**Parallax.** Build it: `update_parallax` / `draw_parallax` scrolling each
layer by its `parallax_speed` against camera movement, so distant layers move
slower.

**And a correction to how it was flagged.** This file listed
`Sprite.parallax_speed` under "dead" because nothing in the package reads it.
That reasoning was wrong for the same reason it was wrong about `Body`'s
physics fields: a field the *game* drives is not dead just because the
framework does not read it. The genuine finding was narrower -- parallax has
no update or draw procedure at all, so the field cannot do anything yet. Once
those exist, Matchbox will read `parallax_speed` when rendering and updating
the effect, and the field is doing its job.

## Open questions

**None.** Every question this review raised has been answered -- see
*Decisions taken* and *Decisions, round two* above. New ones go here as they
come up.

---

# Execution plan

On branch `refactor`. Ordered so the mechanical, compiler-checked work lands
first and the risky work lands on a base that is already consistent.

**Two rules for the whole run:**

1. **Steps run one at a time, not in parallel.** A rename touches every file
   that names the thing, so two steps in flight would collide on the same
   files. Small and serial beats fast and tangled.
2. **Every step ends at the same gate:** `odin check matchbox -no-entry-point`
   clean, `odin check` clean on all 24 examples, **`odin test matchbox` green**,
   `python tools/gen_cheatsheet.py` re-run if any public procedure changed, and
   a commit of its own. A step that cannot pass the gate gets reverted rather
   than patched forward.

   The test run was missing from the first three steps' gate and was added
   after step 3 -- `matchbox/touch_test.odin` holds 7 real tests covering touch
   slots, the letterbox transform and pinch. They pass as of step 3, but three
   renaming steps went by without anyone checking, which is exactly the window
   where a silently broken test would have gone unnoticed.

### Progress

| step | state |
|---|---|
| 0 -- flatten TankMovement | **done**, `24c3cfe` |
| 1 -- type names | **done**, `69ff605` -- 74 renames, 21 files |
| 2 -- `create_x` / `destroy_x` | **done**, `669ce87` -- 20 renames, 27 files. `destroy` group audited: 15 public members, 4 privates correctly outside |
| 3 -- `is_x` / `get_x` | **done**, `0930c9e` -- 30 renames, 39 files |
| 4 -- file moves | **done**, `14fa9c7` -- `utility.odin` created, `timer`/`lerp`/`look_at` deleted, clock logic out of `poll_events` |
| 5 -- input onto SDL values | **done**, `415800f` -- `Mouse_Button` deleted for `sdl.MouseButtonFlag` |
| 6 -- small dedupe | **done**, `7477aee` -- one glyph walker, `linalg.length` ×3, net -17 lines |
| 7 -- one LRU with frame guard | **done**, `2770bac` + `1968429` -- `lru.odin` added, both caches on it, regression tests written |
| 8 -- build camera follow and parallax | **done**, `607fe34` -- 336 procedures, 20 tests |
| 9a -- errors, the `ensure` sites | **done**, `f931972` + `a937030` -- `errors.odin` added, 17 of 29 converted, 12 kept |
| 9b -- errors, the `ok: bool` sites | **done**, `05cb9e4` -- loaders migrated, "is there one?" queries kept |

**The plan is complete.** All ten steps landed, each behind the same gate.

### What the error convention settled on, and what it deliberately excludes

`Error :: union #shared_nil { Gpu_Error, Image_Error, Argument_Error,
File_Error, Model_Error, Skybox_Error }`. `#shared_nil` is what makes
`err != nil` work against enums whose `None = 0`; without it every test reads
`err != .None`, comparing against a named nothing.

Three things stayed as they were, and `errors.odin` documents each so they
read as decisions:

- **Broken invariants stay `ensure`** -- 12 of them. Drawing outside a pass,
  `end_clip` without `begin_clip`, using Matchbox before `init`. These are
  bugs in calling code, and handing them back as values means either every
  call site ignores them or the bug goes quiet. A quiet bug in a draw call is
  the expensive kind. `pixel_buffer_update`'s size check was converted during
  9a and moved back for exactly this reason -- the length is fixed by the
  buffer's dimensions and the caller's type, so right once is right always.
- **"Is there one?" keeps a `bool`** -- `get_pinch`, `get_primary_touch` and
  the two `pixel_buffer_pick` procedures. Fewer than two fingers down is not
  a failure, and an `Error` there would fire `err != nil` on the ordinary
  state of nobody touching the screen.
- **The private glTF readers keep theirs** -- they are threaded together with
  `or_return` over glTF's optionals, and `.? or_return` yields a `bool` that
  cannot propagate into an `Error` return (checked, not assumed). Converting
  them means hand-rewriting the unwrap chains in the most delicate parsing
  code here, for nothing a game can see: `load_model` already collapses the
  outcome into one error at the boundary.

`sprite_cache_get` also kept `^Sprite` + nil: everything it calls now returns
an error and each is logged with the path, but the answer at a call site is
the same for all of them -- there is no art for this key, draw nothing.

**Step 8's parallax convention, settled:** `parallax_speed` is *the fraction
of camera movement a layer follows* -- 1 moves with the world, 0.5 drifts at
half rate, 0 is pinned to the screen. The depth reading (0 = world plane,
1 = pinned) has the tidier zero value and was rejected anyway, because it
would invert a universally understood name: `parallax_speed = 1` meaning
"does not move" reads backwards to everyone. `parallax_add`'s `speed`
defaults to 1 so a layer added without one behaves like an ordinary sprite.

The offset is computed at **draw** time, not accumulated by an update
procedure -- it is a pure function of the current camera, so it cannot drift
out of step, survives a skipped or doubled frame, and leaves `position`
meaning where the layer sits in the world.

**A correction worth keeping:** the doc comment originally claimed the linear
easing in `camera_follow` is indistinguishable from the frame-rate-independent
`1 - exp(-speed * dt)` at sane frame times. That is wrong. They diverge by
roughly `speed * dt / 2` relative -- about 4% per step at 60fps with
`follow_speed = 5`, and 8% at 30fps -- which is why the comment states the
rule rather than a reassurance.

Step 7's guard was proved rather than assumed, twice over. The old code was
stashed and the same scenario run against it: it failed on the first
assertion with `len: 1` -- the first sprite freed while the caller still held
the pointer. That is the bug, reproduced. The fix was then verified
independently, and the three tests now living in `sprite_cache_test.odin`
keep it that way. Neither cache had any test coverage before this.

**Step 5 fixed a real bug, not just a naming inconsistency.** The old handler
switched SDL's button id into the three-member enum and set `valid = false`
for anything else, so `.X1` and `.X2` -- the side buttons, ids 4 and 5 -- fell
into the default arm and skipped the state update entirely. Side-button clicks
were silently discarded, and nothing else in the event switch caught them. They
work now. The replacement maps arithmetically (`MouseButtonFlag(button - 1)`,
since SDL numbers from 1 and the enum from 0) behind a range check that is
load-bearing: `button` is a `Uint8`, and a mouse with more than five buttons
reports ids with no enum member, which would index past the array.

Step 4's clock extraction was the one place a silent behavioural change could
have hidden, so it was checked line by line: `clock_wait_for_frame` and
`clock_tick` are byte-for-byte the original inline code, and the call order in
`poll_events` -- limiter, then `touches_end_frame`, then tick -- is preserved.
That order is a constraint, not an accident, and is now commented at both the
call site and in `clock.odin`.

Two judgement calls made during the run, easy to reverse if either is wrong:

- `sprite_cache_has` → **`is_sprite_cache_holding`**, not `is_in_sprite_cache`,
  to keep the `sprite_cache_*` family clustered under the mandated prefix the
  way `get_sprite_cache_len` does.
- The bounding box tests **dropped their `_check` suffix** --
  `is_bounding_box_collision` and `is_bounding_box_contact`. The suffix was
  doing the predicate work that `is_` now does, and `is_X_check` stutters.

| # | step | why here |
|---|---|---|
| 0 | Flatten `examples/TankMovement` | It is the one example the check sweep skips; every later step needs all 24 verifiable |
| 1 | Type names → `Pascal_Snake_Case` | Mechanical, compiler-caught, and makes everything after easier to read |
| 2 | `create_x` / `destroy_x` renames | Same, and the `destroy` group gets its missing members |
| 3 | `is_x` / `get_x` renames | Same again; finishes the naming sweep in one run so nothing is half-converted |
| 4 | File moves, no logic change | Now that names are settled, move procedures to the files they belong in |
| 5 | Input onto SDL's values | Drops `Mouse_Button`, gains X1/X2 |
| 6 | Small dedupe | The two text drawers, and `linalg.length` for the three hand-rolled ones |
| 7 | One LRU with the frame guard | Closes the `Sprite_Cache` eviction hole |
| 8 | Build `camera_follow` and parallax | New behaviour, on a settled base |
| 9 | Errors: `(value, err)` replacing `ensure` | Widest blast radius, so it goes last and lands on stable names |

### Step detail

**0. TankMovement.** `src/main.odin` → `main.odin`; drop `build/` and
`build.bat` (no other example ships one).

**1. Types.** `AnimatedSprite`, `AnimationClip`, `CooldownTimer`,
`FontFragData`, `OutlineFragData`, `VertData`, `LerpMove`, `MatchboxInfo`,
`ParallaxSprites`, `SpriteForward` → `Animated_Sprite`, `Animation_Clip`,
`Cooldown_Timer`, `Font_Frag_Data`, `Outline_Frag_Data`, `Vert_Data`,
`Lerp_Move`, `Matchbox_Info`, `Parallax_Sprites`, `Sprite_Forward`. Also
`Sprite_Forward`'s values (`.Top`, `.Right`, `.Bottom`, `.Left`) →
`SCREAMING_CASE`, since it is the one enum whose values break the rule. The
HLSL in `matchbox/shaders` names `matchbox.VertData` in comments -- update
those too, but do **not** rerun `build_shaders`: a comment cannot change
compiled output, and recompiling with a different `dxc` would churn every
`.spv` and `.dxil` for nothing.

**2. Constructors and destructors.** `create_x` per the rule, keeping
`load_x` for things that arrive whole. `sprite_of` →
`create_sprite_from_mesh`, `animated_sprite_of` →
`create_animated_sprite_from_clip`. `sprite_cache_destroy`,
`font_cache_destroy`, `shapes3d_destroy` → `destroy_x` form, and every
*public* `destroy_x` joins the `destroy :: proc{...}` group -- the two private
ones do not, since the group exists to be called from outside.

**3. Predicates and getters.** The two lists under *Predicates and getters*
above, with the carve-outs: procedures that act and report keep their verb,
and computations are not getters.

**4. Moves.** `draw_text_*` / `measure_text` / `draw_text_ui_*` / `trim_plus`
from `font.odin` to `text.odin`; `destroy_animated_sprite` from `destroy.odin`
to `animation.odin`; a new `utility.odin` absorbing `timer.odin`, `lerp.odin`
and `look_at_point`, with `look_at_sprite` going to `sprite.odin` instead; and
the frame limiter plus `delta_time` computation out of `poll_events` into a
`clock.odin` procedure.

**5. Input.** Delete `Mouse_Button`, use `sdl.MouseButtonFlag`. Check nothing
indexes `mbi.input.mouse.buttons` by integer, and let X1/X2 through the
`poll_events` switch that currently drops them.

**6. Dedupe.** One private glyph walker behind `draw_text_string` and
`draw_text_ui_string`. `linalg.length` at `gamepad.odin:293`,
`touch.odin:147` and `shapes.odin:35`, removing `vec_length`.

**7. Cache.** One generic LRU used by both caches, carrying the frame guard.

**8. Features.** `camera_follow(target, delta_time)`; `update_parallax` /
`draw_parallax`. Consider the same easing for `camera3d_follow`.

**9. Errors.** `(value, err)` with union error types, replacing `ensure`.
Expect every call site, every example and the README snippet to move with it.

### One thing step 1 left behind, deliberately

`quad.vert.hlsl` declares `cbuffer VertData`, and the Odin type it must match
is now `Vert_Data`. It was left alone, and should stay left alone until
someone is on Windows:

- The three other *vertex* shaders name their cbuffers exactly after their
  Odin types (`Mesh_Vert_Data`, `Skin_Vert_Data`, `Skybox_Vert_Data`), so this
  is a real inconsistency -- but every *fragment* shader uses a generic
  `FragData` regardless of its Odin counterpart, so name-matching was never
  universal.
- It is behaviourally inert. SDL_GPU binds uniform blocks by slot, not by
  name, so the two names never have to agree for the program to be correct.
- Renaming it needs a rebuild, and no rebuild can happen on the Linux laptop.

Change it on Windows, in a commit of its own carrying both rebuilt formats,
or leave it. Not worth doing halfway.

### Shaders and the two platforms -- worth fixing `build_shaders.sh`

Raised 2026-09-04. The working understanding was "dxc can't run because this
session is on Linux, and that's fine because SDL3_GPU uses Vulkan on Linux
anyway". **The conclusion is right -- nothing is broken -- but two parts of
the reasoning need correcting, and the second one matters.**

**1. Linux is not what stops `dxc`.** The Vulkan SDK ships `dxc` for Linux
too; it is simply not installed on this laptop. So this is a "not set up
here" problem, not a platform limit.

**2. "Vulkan on Linux, so it doesn't matter" is true for *running* and false
for *committing*.** Both formats are committed -- 17 `.spv` and 17 `.dxil` in
`matchbox/shaders`. On Linux, `build_shaders.sh` sets `WANT_DXIL=0` and emits
SPIR-V only. So a Linux machine that edits shader **code** and reruns the
script produces an updated `.spv` beside an untouched `.dxil`, and committing
that pair ships a `.dxil` that no longer matches its source. Locally
everything still looks right, because Vulkan reads the `.spv` that *was*
rebuilt. The person who finds out is whoever next runs the D3D12 backend on
Windows, and what they get is stale shader code rendering wrong pixels --
not a build error, which is the worse failure of the two.

So the rule is: **the platform protects the person making the change and
exposes everyone else.** Nothing is wrong right now -- step 1 edited shader
*comments* only, which cannot alter compiled output, so all 34 binaries are
still correct.

**Why DXIL is Windows-gated at all:** D3D12 requires DXIL to be signed, and
the signing library (`dxil.dll`) is shipped by Microsoft for Windows only --
unsigned DXIL is rejected outside developer mode. That is the constraint
behind the script's "DXIL is Windows-only in practice" comment. Reasonably
confident but not verified against this toolchain; worth a check before
relying on it.

**Left open on purpose.** Changing `build_shaders.sh` was considered and set
aside -- the problem is worth solving, but the script is only one of the
places it could be solved and the others have not been explored yet. So this
entry records the *hazard* rather than prescribing the fix.

Ideas that came up, none chosen, none ruled out:

- Have the script **say so loudly** when it skips DXIL, naming the `.dxil`
  files it has just left stale. It skips silently today.
- **Tell a comment edit from a code edit** -- hash the `.hlsl` with comments
  stripped and only warn when the code hash moved. That distinction is what
  made step 1's shader edits safe, and nothing automated can currently make
  it.
- **Gate committing rather than building** -- a check that fails when a
  tracked `.hlsl`'s code hash disagrees with what its `.dxil` was built from.

Other angles worth weighing before picking any of them: whether both formats
need committing at all, whether DXIL could be produced somewhere other than a
developer's machine, and whether the pair could be checked in CI rather than
by a script someone has to remember to run.

### Deferred past this run

The file splits (`ui.odin`, `camera3d.odin`, `init.odin`), batching load-time
uploads onto one command buffer, the `gltf2` conventions review, the Android
tooling audit, and the physics/audio packages that `collisions.odin` and
`sound.odin` are waiting on.

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
  (added 2026-09-04, see the 2D-animation-finished work). Extended again
  2026-09-05: `play_animation` is now idempotent for the clip already
  playing, the same way `switch_animation` is, and `replay_animation_3d`
  pairs with `replay_animation` as the explicit-restart verb neither
  idempotent form has. See `animation3d.md`. Same vocabulary, no shared
  machinery forced between them. This is the right amount of overlap --
  keep extending it by analogy rather than trying to unify the types.
- `Camera` (2D) and `Camera3D` could likely share a couple of small concepts,
  but **correction, 2026-09-04: it's not `follow_speed` as first noted here.**
  Checked and `Camera.follow_speed` is dead on the 2D side -- declared,
  documented as "used for lerp," never read by anything (see the redundancy
  section below). `Camera3D` doesn't have a lerp-follow either:
  `camera3d_follow` (`camera3d.odin:517`) snaps the camera straight to the
  orbit position every call, no damping term. So neither camera has a working
  smoothed follow today; if one gets built, build it once and decide which
  side owns the concept, rather than reading this note as "3D already has it."

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

## Scope: a complete framework again (superseded 2026-09-09)

**This section is history now. See CLAUDE.md's own "Scope" section for the
rule in force.**

Matchbox was originally meant to be an all-encompassing game framework. Scope
was later narrowed to rendering and input, with physics, audio, and an event
system meant to arrive as separate packages once they exist. Reviewed
2026-09-04 for what had crept in under the old, wider scope.

**Reversed 2026-09-09.** Those separate packages did not materialise, and the
narrowing cost more than it bought. The evidence was already sitting in the
package: `sound.odin` shipped a WAV loader because a game needs sound whatever
the stated scope says, and `utility.odin` had to describe itself as a "holding
pen" for helpers that were useful, used by a real game, and had nowhere else
to go. A scope that the code keeps contradicting is a scope that is wrong
rather than code that is undisciplined.

So audio, physics, an event system and the rest are in scope, and the audit
below is retained for what it recorded rather than as a standing instruction
to evict anything. The one finding worth carrying forward on its own merits is
the note on event systems: there is still no subscribe/publish API here, and
`sdl.Event` is still polled internally rather than exposed. That stays true
because CLAUDE.md's no-callbacks rule says so, which is a rule about *how*
this package is built and survives the scope change untouched.

**No event system exists today**, which is correct and worth confirming stays
true -- the only `Event` in the package is `sdl.Event`, polled internally by
`input.odin` / `gamepad.odin` / `touch.odin` to fill in `Input`'s own
per-frame snapshot. It is never exposed as a subscribe/publish API. If a
future change starts threading callbacks or a message queue through here,
that is the event package's job, not this one's.

**Status of everything this section flagged** (resolved in *Decisions, round
two* above):

| file | what happened |
|---|---|
| `tiled.odin` | **deleted** -- moved to a package covering Tiled, LDtk and other formats |
| `procedural_generation.odin` | **deleted** with `examples/random-walk`; now `DreamCartographer/2d/randomwalk/` |
| `maps.odin` | **deleted** -- empty placeholder |
| `timer.odin`, `lerp.odin`, `look_at.odin` | fold into `utility.odin`, re-review later. `look_at_sprite` goes to `sprite.odin` instead (sprite math lives there) |
| `sound.odin` (40 lines) | **still to move**, to an audio package once one exists |
| `collisions.odin` (41 lines) | **still to move**, to a physics package once one exists -- keep `mouse_over_sprite` here, see below |

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

---

## SDL3 and SDL3_GPU stay, unless the rendering framework itself changes

Considered 2026-09-04: dropping SDL3 as the window/input layer in favour of
native per-platform windowing (Win32, X11, Cocoa), while keeping SDL3_GPU for
rendering.

**Verdict: no, not while SDL3_GPU is the renderer.** Checked against the
actual `vendor:sdl3` bindings rather than assumed:

- `ClaimWindowForGPUDevice` (`sdl3_gpu.odin:895`) takes an `^Window` -- there
  is no variant taking a raw native handle instead. `GetGPUDeviceProperties`
  (`sdl3_gpu.odin:830`) only exposes name/driver-string metadata, not the
  underlying `VkDevice`/`ID3D12Device`, so there is no way to pull the native
  device out and build a swapchain by hand against a natively-created window.
  SDL3_GPU's presentation path is hard-wired to `SDL_Window*` with no
  supported escape hatch.
- A partial path exists -- `CreateWindowWithProperties` can *wrap* a window
  created with raw Win32/X11/Cocoa calls (`PROP_WINDOW_CREATE_WIN32_HWND_POINTER`
  etc., `sdl3_video.odin:289-297`) -- but whether a wrapped foreign window
  keeps correct size/DPI state for the swapchain without SDL's own event pump
  running is unverified (would need SDL's own source, not just the bindings,
  to answer).
- Input is the more expensive half regardless: `gamepad.odin` leans on SDL's
  controller-mapping database (`gamecontrollerdb.txt`) to turn whatever a
  physical pad reports into a consistent layout. Dropping SDL for input means
  reimplementing that per platform (XInput, evdev, macOS GameController) or
  keeping SDL for gamepads while hand-rolling keyboard/mouse -- worse than
  either alone.

**So: SDL3 and SDL3_GPU stay as they are.** This is only worth reopening if
the rendering framework itself changes -- e.g. a future move off SDL3_GPU to
something else for rendering would remove the constraint that forces the
window layer to stay SDL3 too. Don't re-litigate the windowing question on
its own; it's downstream of the rendering-backend question, not independent
of it.

---

## More redundancy, found on a broader pass (2026-09-04)

Went looking past the font.odin/text.odin case for other files doing the same
thing twice, or a package-level constant that had crept back in since the
earlier cleanup pass. The constants check came back clean -- every top-level
`::` left in the package is still one of the documented exceptions (array
sizes, a `*_DEFAULTS` struct, a colour, `DEFAULT_FONT_BYTES`). No TODO/FIXME/
HACK markers anywhere either. Three real things did turn up:

**`draw_text_string` and `draw_text_ui_string` are ~35 lines of near-identical
code** (`font.odin:175-211` and `font.odin:242-276`). Same `bind_quad_state`
call, same `FontFragData` push, same glyph loop calling `GetBakedQuad`, same
`pos`/`size` computation from the baked quad -- the *entire* difference
between them is one pair of lines inside the loop:

```
position = screen_pos(pos),   size = screen_size(size),   // world-space
position = pos,                size = size,                // UI-space
```

Worth collapsing into one private glyph-walking proc parameterised on
whether to apply `screen_pos`/`screen_size` (or taking the already-computed
`position`/`size` as a callback), with `draw_text_string` and
`draw_text_ui_string` becoming thin callers. This is the same fix as the
`draw_text_*` file-location one, just inside the proc bodies instead of
between files -- worth doing in the same pass since it's the same code.

**2D vector length is hand-rolled three separate times**, each slightly
differently, instead of calling `linalg.length` -- which the codebase already
uses correctly for 3D vectors (`math3d.odin:133`, `camera3d.odin:534`):

- `gamepad.odin:293` -- `math.sqrt(raw.x * raw.x + raw.y * raw.y)`
- `touch.odin:147` -- a private `vec_length` wrapping `sdl.sqrtf(v.x*v.x + v.y*v.y)`
- `shapes.odin:35` -- `math.sqrt(delta.x * delta.x + delta.y * delta.y)`

`linalg.length` is generic over vector size, so all three collapse to
`linalg.length(v)` -- which also removes `touch.odin`'s private `vec_length`
entirely and stops it being the one place in the package going through
`sdl.sqrtf` instead of `core:math` like everywhere else.

**`Camera.follow_speed` (`camera.odin:16`) is a dead field.** It's declared
and commented "How fast the camera will follow the position (used for
lerp)," but nothing in the package reads it -- no `camera_follow` proc exists
for 2D, no example sets it to anything but its zero value. See the corrected
note in the 2D/3D section above: `Camera3D`'s `camera3d_follow` doesn't lerp
either, it snaps, so this isn't a case of the field being 3D's job instead --
it's unimplemented on both sides. Either build the lerp-follow the comment
promises (`lerp.odin`'s `LerpMove` is the existing pattern to match) or pull
the field until it is built; a documented-but-inert field is the kind of
thing that costs someone an hour assuming it works.

**Checked and found already good, not a problem:** `ui.odin`'s three
timeout-driven widgets (`Hover`, `Confirm_Button`, `Status_Line`) all
correctly share the one private `seconds_since` helper rather than
reimplementing elapsed-time math each -- this is the redundancy check working
as intended, not everything it looked at turned up an issue.

---

# Full-package review (2026-09-04)

A pass over the whole package rather than one question at a time. Findings
are grouped by what kind of work they are, because they don't all want the
same pass: naming is one mechanical sweep, the dead fields are deletions, and
the structural ones each want thinking about separately.

## A. Structural

**`init` is 320 lines and `poll_events` is 215** (`init.odin:352`,
`input.odin:97`) -- the two procedures a game touches first are the two
longest in the package. `init` is window creation, device creation, shader
loading, six pipeline builds, sampler creation, quad upload, font baking and
logger install, in sequence, in one body. `create_pipeline` (156) and
`first_person_walk` (153) are next. These are the natural extraction targets;
see also the file-split list above, since `init.odin` splitting into
lifecycle + pipeline construction and `init` shrinking are the same job.

**`poll_events` does the clock's work.** `clock.odin` owns the `Clock` struct
and the accessors (`delta_time`, `get_time`, `set_target_fps`,
`frame_count`), but every line that *updates* those fields -- the absolute
deadline frame limiter and the `delta_time` computation -- lives in
`input.odin:248-306`. Same misplacement as `draw_text_*` in `font.odin`:
the file owns the data and a sibling owns the logic. A `clock_tick()` /
`clock_wait_for_frame()` in `clock.odin`, called from `poll_events`, would
put them back together and take ~60 lines out of the longest input procedure.

**Three error-handling conventions for the same class of failure.** Creating
a GPU resource that the driver might refuse is handled three ways:

| convention | used by | what a caller sees |
|---|---|---|
| `ensure(...)` -- abort | `upload_buffer`, `create_gpu_texture`, `create_mesh` | process dies at the failure |
| `(value, ok: bool)` | `load_image`, `load_model`, `load_skybox_*`, `read_entire_file` | handled at the call site |
| log + zero value | `create_render_target`, `sprite_cache_get`, `ensure_depth_texture` | nothing, until later |

`create_render_target` is the one that stings: it logs, returns a zeroed
struct, and the failure only surfaces as an unrelated-looking `ensure` inside
`begin_drawing_target` ("render target was never created") at the next frame.
Pick one rule -- "a resource the game asked for by name returns `ok`, an
internal one `ensure`s" is a defensible line -- and apply it.

**SDL types leak through the public API, inconsistently.** `Mouse_Button` is
Matchbox's own enum, but `is_key_pressed` takes `sdl.Scancode` and
`is_gamepad_button_pressed` takes `sdl.GamepadButton`. So two of the three
input devices hand SDL's vocabulary to games and one doesn't.

**Decided: lean on SDL3's values everywhere, don't wrap them.** SDL3 is
staying (see the SDL3 section above), so wrapping its enums buys nothing but
a translation layer to maintain. The work:

- Delete `Mouse_Button` (`input.odin:58`) and use `sdl.MouseButtonFlag`,
  which is already an enum with `.LEFT`, `.MIDDLE`, `.RIGHT`, `.X1`, `.X2`
  (`vendor/sdl3/sdl3_mouse.odin:43`).
- Call sites are unaffected -- `is_mouse_pressed(.LEFT)` still infers.
- **This gains the two side buttons for free.** `poll_events` currently
  switches SDL's button id into the custom enum and drops anything that
  isn't left/middle/right on the floor (`input.odin:170-177`, the
  `valid = false` path), so X1/X2 clicks are silently discarded today.
- `mbi.input.mouse.buttons` is `[Mouse_Button]Key_State`, so the array
  changes shape with the enum -- check nothing indexes it by integer.

## B. Naming drift

None of these are bugs; together they're what makes the API hard to guess at.
One mechanical sweep fixes all of them, and it wants doing in one go rather
than opportunistically, because half-converted is worse than either end.

**Decided 2026-09-04, and now written into `CLAUDE.md`:**

- Procedures are `snake_case`.
- Types -- struct, enum, union -- are `Pascal_Snake_Case`.
- Enum **values** are `SCREAMING_CASE`, one to a line:
  `Player_State :: enum { LEFT, RIGHT, UP, DOWN }`, written out vertically.

That settles the first bullet below: every multi-word *type* not already in
`Pascal_Snake_Case` gets renamed. The value rule is mostly a matter of
writing down what the package already does -- 18 of the 19 enums are already
`SCREAMING_CASE` with one value per line.

**`SpriteForward` (`look_at.odin:10`) is the single exception, and it is wrong
on both counts:** the type name wants to be `Sprite_Forward`, and its values
(`.Top`, `.Right`, `.Bottom`, `.Left`) want to be `.TOP`, `.RIGHT`,
`.BOTTOM`, `.LEFT`. Four call sites in the same file. Note this file is also
slated to leave for a gameplay-utility package (see the scope section) -- fix
it wherever it ends up, not twice.

The constructor / destructor / predicate spellings below are **not** settled
by any of this and still want a decision each -- `create_X` versus `X_make`
versus `X_of` is a question about what reads best, not about case.

- **Two type-naming conventions.** ~60 types use Odin's `Snake_Pascal`
  (`Render_Target`, `Key_State`, `Model_Part`); ~15 multi-word types don't
  (`AnimatedSprite`, `AnimationClip`, `CooldownTimer`, `LerpMove`,
  `MatchboxInfo`, `ParallaxSprites`, `SpriteForward`, `TiledLayer`,
  `VertData`). Worst inside one family in one file: `types.odin` has
  `Sprite_Frag_Data`, `Shape_Frag_Data`, `Rect_Frag_Data`, `Mesh_Frag_Data`
  and `Post_Frag_Data` next to `FontFragData`, `OutlineFragData` and
  `VertData` -- same purpose, same file, two spellings.
- **Four constructor spellings:** `create_X` (`create_sprite`,
  `create_render_target`), `X_make` (`layout_make`, `sprite_cache_make`),
  `X_of` (`sprite_of`, `animated_sprite_of`), `X_at` (`camera3d_at`,
  `transform_at`). `load_X` is legitimately its own category (it reads
  bytes); the other four are the same operation under four names.
- **Two destructor orders:** `destroy_X` (15 of them) against `X_destroy`
  (`sprite_cache_destroy`, `font_cache_destroy`, `shapes3d_destroy`). The
  `destroy :: proc{...}` group in `destroy.odin` lists both orders together,
  which is where it's most visible.
- **Three predicate shapes:** `is_X` (17 procs), `X_is_Y`
  (`dropdown_is_open`, `modal_is_open`, `model_is_skinned`), and bare
  adjective (`cursor_locked`, `mouse_captured`, `touch_active`,
  `lighting_active`, `scroll_needed`).
- **`get_` prefix only in the input subsystem.** `get_mouse_position`,
  `get_gamepad_stick`, `get_touch`, `get_text_input` -- but `delta_time()`,
  `screen_dims()`, `measure_text()`, `model_center()`, `status_text()`
  elsewhere. That split is *almost* a rule ("input reads use `get_`"); it
  just isn't written down anywhere, so it reads as inconsistency.

## C. Redundancy

**Two LRU caches, and they disagree about safety.** `Sprite_Cache`
(`sprite_cache.odin`) and `Font_Cache` (`font.odin:339`) are the same
structure -- a map, a `[dynamic]` order list, a limit -- and
`sprite_cache_touch` / `font_cache_touch` are line-for-line the same
algorithm. The difference is the one that matters: `font_cache_trim`
**never evicts something used during the current frame**, and says why
("a screen drawing seven sizes would otherwise free the atlas belonging to a
pointer it handed out moments earlier"). `sprite_cache_trim` has no such
guard, so with `limit = 1` the second `sprite_cache_get` of a frame frees the
sprite the first one returned. The docs cover it ("copy it before moving it
about") so it isn't a live bug, but one sibling learned a lesson the other
hasn't. Either unify them onto one generic LRU, or at minimum give
`Sprite_Cache` the same frame guard.

**Every load-time upload gets its own command buffer.** `upload_buffer` and
`upload_texture_region` each `AcquireGPUCommandBuffer` → copy pass → 
`SubmitGPUCommandBuffer`. A game loading a hundred sprites does a hundred
submits. `load_animation_frames` already packs frames into one sheet
specifically to avoid per-frame binds, so this cost is clearly on the radar;
batching startup uploads onto one command buffer is the same idea one level
down. Note the warning already in `upload.odin:84-88` -- `pixel_buffer.odin`
deliberately does *not* share this path, and must keep not sharing it.

Also note the two upload procs share ~12 lines of identical
create/map/copy/unmap/submit around a single differing SDL call. Borderline
against the "three similar lines" rule; worth folding only if the batching
work above touches them anyway.

## D. Dead and half-built

Three things declared but never wired up. **All three are resolved** -- the
first two by building them, the third by recognising it was never a problem:

- **`Sprite.parallax_speed` (`sprite.odin:15`) and `Parallax_Sprites`**
  (`types.odin:299`, a `[dynamic]Sprite` whose only implemented procedure is
  `destroy_parallax`). **Decided: build it** -- `update_parallax` /
  `draw_parallax`, scrolling each layer by its speed against camera movement.
  Note the original framing here was wrong: "nothing reads `parallax_speed`"
  was offered as evidence it was dead, but the field is game-facing storage,
  so the framework not reading it proves nothing -- the same mistake this file
  made about `Body` below. The real finding was only that there is no update
  or draw procedure, so the field cannot do anything yet.
- **`Camera.follow_speed`** -- declared and documented, never read.
  **Decided: build it**, as `camera_follow(target, delta_time)`, so the easing
  maths lives in one place. `Camera3D` should probably get the same, since
  `camera3d_follow` snaps.
- ~~**`Body`'s physics fields**~~ -- **raised and resolved 2026-09-04: these
  stay.** `velocity`, `speed`, `jump_force` and `on_ground` are never read
  inside the package, but that is the design, not an oversight: they are
  storage the *game* reads and writes, which is what `examples/camera-2d`
  and `examples/TankMovement` do. Not dead code, and not something the
  physics split should strip out. Left here so the next review doesn't
  re-flag it.

## E. Repo hygiene

**`examples/TankMovement` is laid out unlike the other 24.** It has
`src/main.odin` plus `build/` and `build.bat`, where every other example is a
flat `main.odin`. The consequence is not cosmetic: `odin check
examples/TankMovement` fails with "empty directory that contains no .odin
files", so the one example with a different shape is the one silently skipped
by the "then the examples" check `CLAUDE.md` asks for.

**Decided: flatten it to match the others.** `src/` is the old project
structure and is not used any more. Move `src/main.odin` up to
`examples/TankMovement/main.odin`, and take `build/` and `build.bat` with it
-- no other example carries a build script. After that it is covered by the
same `odin check examples/*` sweep as everything else.

**Root markdown: done, 2026-09-04.** Five finished planning documents removed
-- see *Markdown removed* at the top of this file for what went and why.
`improvements.md` is the one left needing a decision (live backlog on top of a
long completed log, and `README.md` links into it).

---

## The joint palette moved to a storage buffer

Recorded 2026-09-06, after a Vulkan-only skinning artifact that took six wrong
theories to corner. **Done, same day.** Left here as the record of the ceiling
that motivated it and what actually got built, for whoever next touches
skinning and wonders why the palette is shaped the way it is.

### The ceiling

**SDL's Vulkan backend binds a uniform buffer with `range = MAX_UBO_SECTION_SIZE`,
which is `4096`** (`src/gpu/vulkan/SDL_gpu_vulkan.c:71`). That is 4KB — exactly
**64 matrices** — however much is pushed. The constant exists only in that
backend; D3D12 uses `UNIFORM_BUFFER_SIZE` of 32768 with no sectioning.

Measured rather than inferred: forcing every vertex to joint **63** renders a
clean bind pose, and forcing every vertex to joint **64** destroys the whole
model. And the consequence is asymmetric in the worst way — an out-of-range
uniform read is *defined* on D3D12, returning zero, and *undefined* on Vulkan.
So the same file skinned correctly on Windows and threw geometry across the
room on Linux, with nothing in either log.

### The stopgap that came first

For about a day: `MAX_JOINTS` at 64, each part carrying a palette of only the
joints it uses (`Model_Part.joint_map`), so a rig with more joints than that
still worked as long as no single primitive touched more than 64 distinct
ones — real for an ordinary rig (the character that found this has 66 joints
in its skin and no primitive using more than 37) but still a cap, enforced
with a log line rather than a guarantee. The shader's declared array was
shrunk from `joints[128]` to `joints[64]` to match, on Windows, since Linux's
`dxc` cannot sign a `.dxil`. All of this is superseded by what follows and is
kept here only as the step between the bug and the fix.

### The fix, built 2026-09-06

The palette is a `StructuredBuffer<float4x4>` now, bound per character with
`SDL_BindGPUVertexStorageBuffers`, not pushed per part with a uniform. Storage
buffers have no 4KB sectioning, so the cap is gone outright and `joint_map`
is purely an optimisation -- a part compacts to the joints it actually uses,
but nothing is dropped if it doesn't fit, because there is no longer a "doesn't
fit".

What that touched, against the three points raised when this was only a plan:

- **The shader.** `cbuffer Skin_Vert_Data` (4096 bytes of matrices) became
  `StructuredBuffer<float4x4> joints` at `t0, space0` -- SDL_GPU's fixed HLSL
  slot for a vertex stage's first storage buffer, the same way vertex uniforms
  are always `space1`. `Skin_Vert_Data` itself didn't disappear; it shrank to
  one `uint joint_offset`, still pushed at `b1` -- see the next point.
- **The pipeline.** `create_builtin_shader` gained a `num_storage_buffers`
  parameter; the skinned vertex shader declares one.
- **The upload.** This was "the real work" and the reason a uniform was tried
  first. One buffer per *character* (`Animation_Pose.joint_buffer`), holding
  every skinned part's palette back to back -- `Model_Part.joint_offset` is a
  running sum over a model's parts, computed once at load since it is the
  model's number, not any one animator's, and `joint_offset` in the shader is
  what turns a part-local vertex index back into a real one. `update_animator`
  rewrites the whole buffer every frame through a persistent transfer buffer
  (`rewrite_buffer` in upload.odin), on its own command buffer rather than the
  frame's -- which is what let this drop into every existing call site with
  no ordering change: `update_animator` still runs wherever it always did,
  before `begin_drawing` included, because the upload never touches `r.cmd`
  and SDL_GPU's one queue keeps it ordered ahead of the draw that reads it
  by submission order alone. The alternative -- piggybacking the upload on the
  frame's own command buffer, the way `pixel_buffer_update` does for a texture
  -- was rejected because `draw_model` is the only place with a render pass
  reliably open, and a copy pass cannot be recorded while one is; doing it
  there would mean closing and reopening the 3D pass mid-model, invalidating
  every cached bind (`bind_cache_reset`) and needing the interrupted pass's
  depth target to have been opened with `store_op = .STORE` instead of the
  `.DONT_CARE` it uses today. Solvable, but a second render-pass edge case for
  a benefit (sharing one command buffer) that submission ordering already
  gives for free.
- **The nil-animator fallback.** `draw_model`'s "no animator draws the bind
  pose" promise had nowhere to read from once the palette lived on the
  animator rather than being pushed fresh each call -- an all-identity uniform
  doesn't exist to fall back to any more. Replaced with a grown-not-shrunk
  global identity storage buffer (`ensure_identity_joint_buffer`), sized to
  whatever model has needed it so far and reused across every model that hits
  this path, since it is content-free: identity is identity regardless of
  which model's `joint_offset` indexes into it.

### Worth keeping from the hunt

- **A zero matrix is not a harmless default in a palette.** `make` zeroes, and
  a zero matrix collapses every vertex using it onto the origin. Unresolvable
  slots are filled with the identity, and `animation3d_test.odin` pins that.
- **Platform-specific bugs with clean data want bisection, not theory.** Six
  mechanisms were proposed and rejected; what found it was four one-run
  experiments that each halved the search space — bind pose, then object
  visibility, then which vertex attribute, then a single joint index against
  its neighbour. Two earlier tests proved nothing because they carried hidden
  preconditions, which is worse than no test: they took the right answer off
  the table for several hours.
