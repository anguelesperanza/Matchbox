# Working in Matchbox

House style. Follow it for new code and when touching old code; `refactor.md`
tracks bringing the rest of the package into line.

## Scope: a complete framework, not a rendering layer

Matchbox covers the parts of building a game -- and of building software
around one -- rather than rendering and input alone. Audio, physics, an event
system and whatever else a game actually needs belong here, as first-class
parts of the framework, not as separate libraries a game is left to bolt on.

**This reversed an earlier narrowing, deliberately.** Matchbox began as an
all-encompassing framework, was cut back to rendering and input on the
reasoning that everything else could arrive as its own package, and was widened
again because those packages did not materialise and the split cost more than
it bought: a game still needed sound, so `sound.odin` sat in the package anyway
contradicting the stated scope, and `utility.odin` became an explicit "holding
pen" for helpers that were useful and had nowhere to live. `refactor.md`'s own
scope section has the full history.

**The narrowing came back once, as separate repositories, and was reversed
again on 2026-09-17.** Physics and audio *did* materialise as their own
projects -- **Tether**, over `vendor:box3d`, and **Eko**, over
`vendor:miniaudio` -- cloned beside Matchbox by whichever game wanted them. The
project owner moved both into this repository because the dependency problem
that split creates has no good answer:

- `level` wants to describe colliders that a game turns into Tether bodies.
  With Tether outside, `level` could only reach it by a path out of the
  repository -- broken for anyone who cloned Matchbox without cloning Tether
  beside it -- so the dependency had to be left to the game to wire up.
- And it only gets worse as the framework fills in: an animation system that
  wants footstep audio, a level that wants to place sound emitters. Every one
  of those is either a path out of the repository or a job pushed onto the game.
- A package reached by two different paths is two packages, with two copies of
  its global. One repository means there is only ever one path.

### Several packages, one repository

Matchbox is **not one Odin package**. It is one repository holding four:

| Package | Where | Depends on | What it is |
| --- | --- | --- | --- |
| `matchbox` | `matchbox/` | SDL3, stb | drawing, input, files, UI, the frame |
| `level` | `level/` | `matchbox`, as `../matchbox` | the level format Stargate's editor writes |
| `tether` | `tether/` | `vendor:box3d` | physics |
| `eko` | `eko/` | `vendor:miniaudio` | audio |

**All four are siblings at the repository root.** `level` lived at
`matchbox/level/` and imported Matchbox as `..` until 2026-09-18; when physics
and audio arrived as siblings, one package nested inside another was the odd one
out, and it moved up. Nothing about how it reaches Matchbox actually changed:
Odin resolves a relative import against the importing file's directory and
identifies a package by the full path it lands on, so `../matchbox` from `level`
and `matchbox/matchbox` from a game are two spellings of one directory and
therefore one package. That is the whole of what the nesting was protecting --
two paths to Matchbox would be two `mbi`s, and an `mb.Model` from one would not
be an `mb.Model` to the other -- and one repository already guarantees it.

A package depending on another inside the repository says so with one `../`,
and that is the point of them all living here.

**Why not fold them into `package matchbox`.** Three reasons, and any one of
them is enough:

- **Vendor cost.** `package matchbox` is what a game importing a sprite drawer
  gets. Folding Tether in would link Box3D into a 2D game that never asked for
  physics, and Eko would link miniaudio into a silent one.
- **Globals.** `mbi` is `package matchbox`'s only global and stays that way.
  Tether has `tpi` and Eko has `mac`, each for the same reason `mbi` exists --
  one world, one audio engine, and an argument at every call site buys nothing.
  Folded in, that would be three globals in one package, and the rule below
  would be a lie.
- **Churn.** A young subsystem changing weekly inside the package everything
  imports is a rebuild of everything, weekly.

**Where a new subsystem goes.** Into `package matchbox` by default -- that is
where a thing a game reaches for alongside `draw_model` belongs. Into a package
of its own beside it when it wraps a vendor library that not every game wants,
or when it needs a global of its own. It is never a repository of its own
again.

**What a wider scope does not license.** It is about *what* may live here, not
*how* it is built. Everything else in this file still governs, in every package:
no callbacks, one global per package and only where one is earned,
configuration as defaulted structs rather than loose constants, comments that
explain why. A subsystem that arrives ignoring those is a subsystem to send
back, whatever its subject. And breadth is not an invitation to speculative work
-- a thing belongs here when a game needs it, not because a complete framework
would plausibly have one.

## Naming

- **Procedures are `snake_case`** -- `draw_sprite`, `update_animation`,
  `camera3d_view_projection`.
- **Types -- structs, enums and unions -- are `Pascal_Snake_Case`** --
  `Animated_Sprite`, `Render_Target`, `Model_Part`, `Key_State`. This is Odin's
  own convention, and what `core:` and `vendor:` use.
- **Enum *values* are `SCREAMING_CASE`** -- the type name follows the rule
  above, the values inside it do not:

```odin
Player_State :: enum {
	LEFT,
	RIGHT,
	UP,
	DOWN,
}
```

- **One value per line**, as above -- never several to a line, however short
  they are.

Single-word type names need no separator, so `Sprite`, `Camera`, `Font` and
`Mesh` are already right. It is the multi-word ones to watch: the separator is
not optional, so `Animated_Sprite` and `Vert_Data` rather than running the
words together.

SDL's own enums are used as they come -- Matchbox leans on `sdl.Scancode`,
`sdl.GamepadButton` and `sdl.MouseButtonFlag` rather than wrapping them, and
those are SDL's types to name.

### Procedure prefixes

- **`create_x`** makes one -- `create_sprite`. **`load_x`** imports a thing
  that already exists whole -- `load_model`. The difference is real: a model
  arrives finished, a sprite is an image plus values set here.
- **`destroy_x`** gives one back, never `x_destroy`. Every public one joins
  the `destroy :: proc{...}` group in `destroy.odin`, so `matchbox.destroy(&x)`
  resolves.
- **`is_x`** asks a question and answers `bool` -- `is_key_pressed`,
  `is_mouse_captured`, `is_dropdown_open`.
- **`get_x`** reads state that is already stored somewhere -- `get_delta_time`,
  `get_mouse_position`, `get_status_text`.

Two carve-outs, because the prefixes describe *reading*:

- A procedure that **does** something and reports what happened keeps its verb.
  `button` draws a button and answers whether it was clicked; `is_button` would
  be a lie. Same for `button_confirm`, `dropdown`, `slider`, `modal_begin`,
  `hover_dwell`.
- A procedure that **computes** a value from its arguments is not a getter.
  `measure_text`, `rect_center`, `model_center`, `line_height`, `screen_pos`
  and `wrap_text` derive an answer rather than fetch one, and
  `get_measure_text` would say the opposite.

**Why it matters here:** the package used to carry both spellings, and the
worst of it was inside one family in one file -- the uniform blocks in
`types.odin` were split between `Sprite_Frag_Data` and a run-together form,
same purpose and same file. That has been swept, so the rules above describe
what is there now rather than an aspiration. Keep it that way: a single new
type in the old shape puts the file back to two conventions.

## Group like data into structs

State that has to agree with itself belongs in one struct, not in loose
variables a caller keeps in step. A game holding a `Camera3D`, a yaw and a pitch
as three variables is a game that will one day update two of them.

The pattern, as `Third_Person_Camera` and `First_Person_Camera` do it:

- one struct holding the state
- one `create_` constructor named after it, with every argument defaulted
- procedures taking a pointer to it

```odin
rig := mb.create_first_person_camera(position = spawn, facing = -math.PI * 0.5)
mb.first_person_walk(&rig, &player, speed, dt)
```

Nest sub-structs when a group has its own job -- `Animator` holds
`Animation_Blend` and `Animation_Pose` -- and reach for `using` when a field was
already public and moving it would break callers (`Animator` embeds
`Animation_Playback` that way, so `animator.playing` still resolves).

**Why:** it is easier to hold in your head. One name to pass, one place to look,
and no chance of half-updated state.

## No callbacks

Matchbox does not hand a game's procedure back to it later. Nothing here takes
an `on_finished`, a listener, or a handler, and nothing should.

Ask instead. The framework is immediate-mode from end to end -- `is_key_pressed`
is polled rather than delivered, `draw_sprite` retains nothing -- so anything
that wants to know a thing happened asks on the frame it cares:

```odin
if !sprite.playing        { /* the one-shot finished */ }
if mb.is_key_pressed(.D)  { /* the key went down */ }
```

**Why:** a callback is tedious out of proportion to what it buys. It inverts
control, so the game reads inside-out; it drags in lifetimes, because a handler
outliving the thing it points at is a crash rather than a mistake; and it needs
answers about ordering and re-entrancy -- what happens when a handler starts an
animation, or destroys the sprite that called it -- that polling never has to
ask. The one thing callbacks genuinely give you is not missing an event on a
frame nobody looked, and that is cheaper to solve by keeping the answer
readable for the frame it belongs to.

This is a rule about Matchbox's own API, not about what a game does internally.

## No new package-level constants or globals

Configuration rides in as a defaulted struct, not as a top-level constant:

```odin
create_animator :: proc(
	model: Model,
	blend := Animation_Blend{enabled = true, duration = 0.2},
) -> Animator
```

Odin accepts all three of these as default parameter values, so there is no
excuse to reach for a loose constant:

```odin
proc(s := Settings{a = 1})        // a struct literal
proc(s := DEFAULTS)               // a named constant of struct type
proc(d: f32 = DEFAULTS.duration)  // a field of one
```

`BUTTON_STYLE :: Button_Style{...}` in `ui.odin` is the existing precedent.

### The exceptions, and they are narrow

- **Array sizes.** Odin needs a compile-time constant for a fixed array bound.
  `MAX_LIGHTS`, `MAX_TOUCHES`, `MAX_GAMEPADS`, `MAX_TEXT_INPUT`,
  `MAX_CLIP_DEPTH`, `FONT_GLYPH_COUNT`, `STATUS_MAX_BYTES` all size arrays and
  stay as they are. (`MAX_JOINTS` was one of these and is gone: the joint
  palette moved to a storage buffer, which has no fixed size to declare --
  see `refactor.md`.)
- **Embedded data.** `DEFAULT_FONT_BYTES` is a `#load` and cannot be anything
  else
- **Colours.** `WHITE`, `BLACK`, `MAROON` and the rest stay loose on purpose.
  Wrapping them in a struct buys nothing and complicates every call site
- **`mbi`.** The one sanctioned global -- see below

## `mbi` is the only global -- one per package, and only where it is earned

Matchbox is an immediate-mode API: `draw_rect` cannot take a renderer argument
without every call site carrying one. `mbi` is that state, and it stays.

Everything else that has crept out to package scope belongs *inside* it. Adding
a new top-level `var` is not the answer; adding a field to the right struct
under `mbi` is.

**The sibling packages each have exactly one of their own**, for the same
reason and under the same rule: `tether.tpi` holds the one physics world, and
`eko.mac` the one audio engine. Every body and every ray belongs to a world, and
threading a world id through `create_box_body` and `cast_ray` would put an
argument at every call site that no game has ever wanted to vary.

The rule is therefore **one per package, and only where an immediate-mode API
makes an explicit handle pure cost** -- not "a global per subsystem". A second
one in any of these packages is the same mistake `mbi` was created to stop, and
a new package that wants one has to make the same case Matchbox made: that the
thing is genuinely single, and that passing it would be an argument everywhere
and a choice nowhere.

## Write the reasoning, not the mechanics

Comments here explain **why**, and especially why the obvious thing is wrong.
The code already says what it does. What it cannot say is that
`enable_depth_bias` is silently ignored for lines, that a cube map is sampled
left-handed, or that a glTF file's rest pose is not its bind pose -- and every
one of those cost hours to find.

When a decision was made against a plausible alternative, say which alternative
and what it would have broken.

## Verify by measuring, not by looking

Claims about behaviour want evidence:

- drive it with synthetic input (`mbi.input.keys[.W].pressing = true`) rather
  than by hand
- check maths against an independent implementation where one is cheap -- the
  skinning palettes and the skybox sampling were both checked against numpy
- for anything visual, simulate what the hardware will do and assert on the
  numbers

Report what was actually verified and what was not. "I have not seen it render"
is a useful sentence.

## Practical notes

- **Shaders.** Edit the HLSL in `matchbox/shaders`, then run `build_shaders.bat`
  (or `.sh`). Both the `.spv` and `.dxil` are committed; a change to one without
  the other is a broken build for somebody
- **Logging.** `init` installs a logger on its own context, which does not reach
  the caller. A game needs `context.logger = mb.mbi.logger` to see anything
  Matchbox logs
- **Vendored code.** Patches to `matchbox/gltf2` are marked `MATCHBOX PATCH` so a
  package refresh can find them
- **Check everything.** Every package, then the examples:

  ```
  odin check matchbox -no-entry-point
  odin check level -no-entry-point
  odin check tether -no-entry-point
  odin check eko -no-entry-point
  ```

  `odin check matchbox` does **not** reach the others -- they are four separate
  packages, none of them under `matchbox/`. A change to `Entity` that breaks
  `level` passes the first line
- **Tests.** `odin test matchbox`, `odin test level`, and
  `odin test tether -define:ODIN_TEST_THREADS=1`. **Tether's want the define**:
  every test there makes and destroys the one world in `tpi`, and the runner
  otherwise runs them side by side against that same global. `matchbox`'s do
  not, because `mbi` is thread-local under `odin test`; a package that grows a
  global without that trick inherits Tether's rule, not Matchbox's
- **Tests run in parallel, each with its own `mbi`.** Under `odin test`, and only
  there, `mbi` is thread-local (types.odin), so a test may set whatever fields
  it needs without another test seeing them. It starts zeroed, not initialised:
  `init` never runs in a test, so anything `init` sets to a non-zero default is
  still zero there. Prefer state whose zero value is already right, so that
  neither a test nor anything else has to know
- **`cheatsheet.md` is generated**, by `python tools/gen_cheatsheet.py` from the
  repository root. Regenerate it after adding or changing a public procedure
  rather than editing it. Each entry's description is the first sentence of that
  procedure's doc comment, so a bad line there is a bad comment at the source.
  **It covers `matchbox/*.odin` only** -- not `level`, `tether` or `eko`, whose
  own doc comments and `.md` files are where their surface is written down
