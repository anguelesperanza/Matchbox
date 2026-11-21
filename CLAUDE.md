> **Copied from the `main` branch on 2026-11-21 so the style rules are in this branch.** The rules about naming,
> grouping data in structs, no callbacks, constants and globals, comments that explain why, and verifying by measuring
> apply here unchanged. Parts of the text describe `main`'s setup and do not describe `full-rewrite`: SDL3 and `stb` as
> dependencies, the four packages (`matchbox`), `build_shaders.bat` with committed `.spv` / `.dxil`,
> and `refactor.md` and the generated `cheatsheet.md`. This branch targets PC (Windows, D3D11), the New 3DS LL and the PS Vita;
> its build and check commands are in `docs/next_session_handoff.md`. The body below is left as it was on `main`, except
> for the rules changed here on 2026-11-21: procedure names read action then thing, one verb per action (`render_`),
> full words rather than shorthand, the wider `get_` and the new `calculate_` prefix, settings structs in `mbi`, and
> how tests share `mbi`.

# Working in Matchbox

House style. Follow it for new code and when touching old code; `refactor.md`
tracks bringing the rest of the package into line.

## Naming

- **Procedures are `snake_case`** and read **action, then the thing acted on**
  -- `render_sprite`, `update_animation`, `destroy_texture`. The action comes
  first, so the procedures that do the same thing line up: every
  `render_*` draws, every `destroy_*` frees.
- **One verb per action across the package.** Matchbox draws with `render_`
  (`render_sprite`, `render_text`, `render_rectangle`), never a mix of `render_`
  and `draw_` -- two words for one action make a reader wonder what the
  difference is, and there is none.
- **Full words, not shorthand** -- `position` not `pos`, `camera` not `cam`,
  `delta_time` not `dt`, `rectangle` not `rect`, `description` not `desc`. A
  name should say what it is without the reader guessing what an abbreviation
  stands for. This covers procedures, parameters, fields and locals. Names that
  belong to someone else stay as they come: an API's own fields (`wParam`,
  D3D11's `DESC` types), a file format's keys (`ppu` in a `.meta` file).
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
not optional, so `Animated_Sprite` and `Vertex_Data` rather than running the
words together. The same goes for constants: `LIGHT_GRAY`, not `LIGHTGRAY`.

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
- **`get_x`** returns data that is not a `bool` (a `bool` is an `is_x`) --
  `get_delta_time`, `get_mouse_position`, `get_window_size`. It does not matter
  whether the value was stored or put together on the spot; what matters is
  that the caller is asking for a thing.
- **`calculate_x`** works a value out with maths -- `calculate_model_matrix`,
  `calculate_sprite_bounds`, `calculate_line_height`,
  `calculate_mouse_world_position`. When a procedure could be either, maths
  wins: `calculate_` tells the caller the answer is computed each call, so it
  is not free in a hot loop and may differ from one frame to the next.

One carve-out, because the prefixes describe *asking*:

- A procedure that **does** something and reports what happened keeps its verb.
  `button` draws a button and answers whether it was clicked; `is_button` would
  be a lie. Same for `button_confirm`, `dropdown`, `slider`, `modal_begin`,
  `hover_dwell`.

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
is polled rather than delivered, `render_sprite` retains nothing -- so anything
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

### Fixed values the engine itself works with

A value the engine uses internally -- not one a caller passes -- goes in a
settings struct named after what it belongs to (`Font_Settings`,
`Screen_Settings`, `Shader_Format`), held as a field of `mbi`
(`mbi.font_settings.line_spacing`). The struct is declared next to the code it
serves, with a comment on each field saying what it is for.

The values are written where `mbi` is declared (`mbi := Matchbox_Info{...}`),
**not** set in `init`. A value given there is right from the first line of the
program and under `odin test`, where `init` never runs; set in `init`, a test
would see zero. A default parameter can read one directly
(`spacing:f32 = mbi.font_settings.line_spacing`): Odin evaluates it at the call.

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
  Wrapping them in a struct buys nothing and complicates every call site. They
  are constants (`::`), never variables: a game could otherwise assign to
  `WHITE` and change what every later use of it means
- **`mbi`.** The one sanctioned global -- see below

## `mbi` is the only global -- one per package, and only where it is earned

Matchbox is an immediate-mode API: `render_rectangle` cannot take a renderer
argument without every call site carrying one. `mbi` is that state, and it stays.

`mbi` is a deliberate god struct: everything the engine holds lives in it --
device handles, input, timing (`mbi.timestamp`), and the settings structs
above. Everything else that has crept out to package scope belongs *inside* it.
Adding a new top-level `var` is not the answer; adding a field to the right
struct under `mbi` is. Keep it navigable by grouping: a new concern gets its
own struct and one field, not a dozen loose fields.

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
  not: most only read `mbi`, and the few that write it take a lock (next item)
- **Tests run in parallel and share the one `mbi`** (this is where
  `full-rewrite` differs from `main`, which made `mbi` thread-local under
  `odin test`). Odin refuses an initial value on a thread-local variable, and
  `mbi`'s settings structs need theirs (see "Fixed values the engine itself
  works with"), so `mbi` is an ordinary global here. A test that only reads
  `mbi` needs nothing. A test that **writes** to it takes a lock first and puts
  the fields back before letting go -- `save_state` / `restore_state` in
  `bottom_screen_windows_test.odin` is the pattern. `init` never runs in a
  test, so only the values written in `mbi`'s declaration are there; anything
  `init` sets is still zero
- **`cheatsheet.md` is generated**, by `python tools/gen_cheatsheet.py` from the
  repository root. Regenerate it after adding or changing a public procedure
  rather than editing it. Each entry's description is the first sentence of that
  procedure's doc comment, so a bad line there is a bad comment at the source.
  **It covers `matchbox/*.odin` only** -- not `level`, `tether` or `eko`, whose
  own doc comments and `.md` files are where their surface is written down
