# Working in Matchbox

House style. Follow it for new code and when touching old code; `refactor.md`
tracks bringing the rest of the package into line.

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
  `MAX_JOINTS`, `MAX_LIGHTS`, `MAX_TOUCHES`, `MAX_GAMEPADS`, `MAX_TEXT_INPUT`,
  `MAX_CLIP_DEPTH`, `FONT_GLYPH_COUNT`, `STATUS_MAX_BYTES` all size arrays and
  stay as they are
- **Embedded data.** `DEFAULT_FONT_BYTES` is a `#load` and cannot be anything
  else
- **Colours.** `WHITE`, `BLACK`, `MAROON` and the rest stay loose on purpose.
  Wrapping them in a struct buys nothing and complicates every call site
- **`mbi`.** The one sanctioned global -- see below

## `mbi` is the only global

Matchbox is an immediate-mode API: `draw_rect` cannot take a renderer argument
without every call site carrying one. `mbi` is that state, and it stays.

Everything else that has crept out to package scope belongs *inside* it. Adding
a new top-level `var` is not the answer; adding a field to the right struct
under `mbi` is.

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
- **Check everything.** `odin check matchbox -no-entry-point`, then the examples
- **`cheatsheet.md` is generated**, by `python tools/gen_cheatsheet.py` from the
  repository root. Regenerate it after adding or changing a public procedure
  rather than editing it. Each entry's description is the first sentence of that
  procedure's doc comment, so a bad line there is a bad comment at the source
