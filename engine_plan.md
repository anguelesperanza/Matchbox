# Engine plan

**Status: planning. Nothing built.** Started 2026-09-10.

This is a living document. An open question gets closed by a dated entry in
section 7 that names the alternative it rejected, and the progress log at the
bottom records what has actually been done -- not what was intended.

**Where this lives.** In the Matchbox repository until the engine has a
repository of its own. When it moves, this file goes with it, and section 4
(*Matchbox gaps*) comes back here as entries in `improvements.md`.

---

## 1. What this is

A game engine -- in the Unity/Godot sense, with the basics and none of the
bells -- built as a **separate project on top of Matchbox**. Matchbox stays a
framework that a hand-written game uses directly; the engine is one more thing
that uses it.

The basics:

- a **scene**: objects with a position and components (sprite, model, light,
  camera, sound, game code)
- **save and load** of scenes to files
- **game code** attached to objects
- an **editor**: see the scene, select and move things, edit their values,
  play and stop
- **export**: the game without the editor

Out of scope until a real game asks for it: visual scripting, a material or
shader graph, terrain, networking, an asset store, a plugin system, animation
state-machine editors, multi-window docking.

### The non-negotiable

**Everything the engine draws, plays or reads goes through Matchbox.** The
engine does not import `vendor:sdl3` for rendering, audio or input, and does
not touch the GPU.

Why: improvements to Matchbox then reach the engine on its next build, which
is the whole reason to build on Matchbox. An engine that reaches past the
framework "just this once" grows a second renderer, and from then on every
Matchbox improvement has to be ported across to it by hand.

When the engine needs something Matchbox lacks, the fix goes into Matchbox
(section 4). If it has to be worked around in the meantime, the workaround is
marked `ENGINE WORKAROUND` with the id of its gap entry -- the same idea as
`MATCHBOX PATCH` in `matchbox/gltf2` -- so every one of them can be found and
removed once the gap closes.

---

## 2. The shape of the thing

Matchbox is immediate-mode and code-first. A game owns `main` and the loop,
and every frame it calls `draw_model`, `draw_sprite`, `button`. Matchbox keeps
almost nothing between frames.

An engine is the retained layer on top. The game is described by **data** (a
scene); the engine walks that data every frame and makes the Matchbox calls a
person would otherwise write; and the editor is a tool for changing the data.

```
   game code                  editor (Matchbox's own UI)
        \                      /
   engine: scene, components, loop, save/load, assets
                     |
      Matchbox: every draw, light, sound and input call
                     |
                   SDL3
```

### The dividing line

**If a hand-written Matchbox game would also want it, it belongs in Matchbox.
If only an editor wants it, it belongs in the engine.**

This is what keeps "the engine benefits from Matchbox" from turning into
"Matchbox bends to fit the engine". It is also CLAUDE.md's own scope test
restated: a thing belongs in Matchbox when a game needs it.

- In Matchbox: mouse picking, drawing a render target into part of the
  screen, physics, audio, a toggle widget.
- In the engine: the scene format, the inspector, undo, gizmos, play mode, the
  asset browser.

### Matchbox is not purely immediate -- the engine must own what it retains

A few things in Matchbox persist until they are replaced. The engine has to be
the one thing that sets them, or a scene and a piece of game code will fight
over them:

| retained in Matchbox | how | engine rule |
|---|---|---|
| the scene's lights | `set_lights` replaces the whole list and keeps it (light.odin:274) | collect light components, call it each frame |
| lighting settings | `set_lighting` | a scene-level setting, applied on load and when edited |
| reflection probes | `add_reflection_probe`, `clear_reflection_probes`, `bake_reflection_probe` | probe components; baked on demand from the editor |
| the 2D camera | `mbi.camera`, `begin_drawing_2d`, `camera_follow` | a camera component; one active 2D camera |
| shadow casters | `draw_model(..., casts_shadow = true)` outside a 3D pass is queued for the next `begin_drawing_3d` (render3d.odin:603) | the loop issues casters before opening the 3D pass |

Whether game code may call these directly at all is open question 6.

---

## 3. The pieces

Each piece: what it is, the options, a recommendation, and what is still open.
**A recommendation is not a decision** until it has an entry in section 7.

### 3.1 Scene and components

**Options:**

- **A. A flat array of entities with a fixed set of optional components.** Each
  entity is a struct holding a transform, a parent handle, a `bit_set` of which
  components it has, and one field per component kind.
- **B. ECS** (archetypes or sparse sets).
- **C. A node tree** (Godot): everything is a node with children, and a node's
  type decides what it does.

**Recommendation: A.**

- It is the easiest of the three to save (one struct, one JSON object), to
  inspect (reflect over one struct), and to debug (print it).
- B buys iteration speed at tens of thousands of entities. "Just the basics"
  does not need that, and it makes saving, inspecting and debugging all
  harder. If a game ever proves the need, an API made of handles and component
  queries can survive a move from A to B underneath it.
- C's strength is composition -- a node tree *is* a prefab system -- but its
  node types lean on inheritance, which Odin does not have. A with a parent
  handle gets the hierarchy without it.

**What follows from A:**

- **Handles, not pointers.** An entity is referred to by index plus
  generation. A pointer into the array dangles as soon as the array grows, and
  a bare index silently points at whatever later reused the slot; the
  generation turns both into a detectable "that entity is gone".
- **Saved references use a stable ID** (a u64), not the array index, so
  deleting or reordering entities does not rewire the references in a saved
  scene.
- **Local and world transforms.** An entity stores its transform relative to
  its parent; world transforms are resolved once per frame, parents first.

**Open:**

- 2D and 3D in one scene kind, or two? Matchbox keeps 2D and 3D apart on
  purpose (`refactor.md`, *2D and 3D: the split is deliberate*). One scene
  kind, with a 3D `Transform` for everything and 2D using x/y and a rotation
  about z, is simpler to write one editor for. Two scene kinds is more honest
  about how differently the two draw. Open question 1.
- Prefabs -- a saved group of entities placed many times -- are wanted
  eventually and not in the first milestones.

### 3.2 The frame loop

Per frame, roughly:

1. `poll_events`
2. game code update
3. animation update -- `update_animation` for sprites, the `Animator` for models
4. resolve world transforms
5. sync retained state: `set_lights` from light components, scene lighting
   settings
6. `begin_drawing`, `clear_background`
7. queue shadow-casting models, `draw_model(..., casts_shadow = true)`
8. 3D: `begin_drawing_3d(camera)`, `draw_model` per model, `end_drawing_3d`
9. 2D: `begin_drawing_2d`, sprites, `end_drawing_2d`
10. game UI, then editor UI when running inside the editor
11. `end_drawing`

In the editor, steps 7 to 9 draw into a `Render_Target` and step 10 draws the
editor around it.

**Open:**

- **Fixed timestep.** `improvements.md` already records that Matchbox is
  frame-rate dependent. Physics wants a fixed step. Whether that belongs in
  Matchbox's clock (a hand-written game wants it too, so probably) or only in
  the engine's loop is open question 7.
- **Who owns `main`** changes the shape of this loop -- see 3.5.

### 3.3 Save and load

**Format: JSON**, through `core:encoding/json`. Text, so scenes diff in git and
can be repaired by hand. A binary format can come later, for export, if load
times ever call for it.

**Checked against the installed Odin (dev-2026-09):**

- marshal reads struct tags and skips a field tagged `json:"-"`
  (core/encoding/json/marshal.odin:484-486). So a component can carry a
  runtime-only field, such as the loaded `Model`, beside the path it came from.
- enums are written as integers unless `use_enum_names` is set
  (marshal.odin:567). Names are what a hand-editable file wants, and they
  survive the enum being reordered where integers do not.

**Not checked:** that unmarshal also skips `json:"-"` fields and reads enum
names back. That is the first spike: round-trip a component with both, and
assert that save, load, save gives identical bytes.

**Rules:**

- Components refer to assets by **path**, never by GPU handle. A `Model` or a
  `Sprite` is a runtime object and cannot be saved.
- Scene files carry a **version number** from the very first one, so a later
  format change can migrate old scenes instead of breaking them.
- Unknown fields are ignored on load, so a scene saved by a newer engine opens
  in an older one with a loss rather than a failure.

### 3.4 Assets

A table from path to loaded thing: model (`load_model`), sprite
(`create_sprite`), animation clip (`load_animation` and friends), sound
(`load_sound`), font. Ten entities using one model load it once.

- Every read goes through Matchbox's `read_entire_file`. That is what makes a
  path work inside an Android apk as well as on a desktop; reading files any
  other way would quietly make the engine desktop-only.
- **Lifetime, first version: the scene owns everything it loaded,** and all of
  it is released on a scene change. Reference counting is the obvious
  alternative and has more ways to go wrong; it waits until a game needs assets
  shared across scenes.
- Matchbox's `Sprite_Cache` is an LRU and **evicts**. That is right for a cache
  and wrong for something a scene is still drawing, so it is not the scene's
  asset table unless eviction can be switched off.
- **Import settings** -- a sprite sheet's frame size, a model's facing and
  scale -- live in the component, or in a sidecar file beside the asset? Open
  question 8.
- Reloading an asset when its file changes on disk: editor-only, later.

### 3.5 Game code

The biggest design question in this plan, because it decides who owns `main`.

**Rejected up front: an embedded scripting language** (Lua or similar). Every
Matchbox procedure would need a binding, so every Matchbox improvement would
need one too before a game could use it -- directly against the non-negotiable
in section 1. It also brings a second language and a second debugger.

That leaves game code written in Odin, in one of two shapes.

**A. The engine owns `main` and calls game code.** A game registers kinds of
script -- a procedure per kind, or an enum and a `switch` -- and the engine
calls each entity's update. This is Unity's shape.

- *Gains:* the editor can run a game without the game's help; a game is data
  plus procedures.
- *Costs:* it is a callback relationship, with every problem CLAUDE.md lists
  for callbacks: code that destroys its own entity, or spawns new ones, while
  the engine is iterating; ordering between scripts; re-entrancy.

**B. The game owns `main` and drives the engine.** The game calls
`engine.update(&world)`, walks its own entities, and asks the engine questions
on the frame it cares -- `engine.is_just_spawned`, `engine.get_contacts` --
exactly as it already asks Matchbox `is_key_pressed`.

- *Gains:* Matchbox's philosophy carries straight through. No lifetime,
  ordering or re-entrancy questions. The engine is a library and reads like
  one.
- *Costs:* the editor cannot run a game it was not compiled with. The editor
  becomes something the game's own `main` enters
  (`when EDITOR { engine.run_editor(&world) }`), so each game builds its own
  editor binary.

**Leaning B.** It is the shape the rest of Matchbox already has, and "each game
builds its own editor" is a build detail rather than a design cost. Open
question 2.

**Hot reload** -- recompiling game code without restarting -- is wanted
eventually and blocked on a spike; see 3.8.

### 3.6 Editor

Built entirely with Matchbox's UI. What exists today and is enough to start
with: `button`, `dropdown`, `context_menu`, `slider` and `slider_int`,
`Text_Field`, `begin_scroll`/`end_scroll`, `Modal`, `draw_tooltip`,
`Status_Line`, `create_layout` and `create_grid`, plus `is_key_repeated`, text
input and the clipboard for editing.

**Panels, first version -- a fixed layout, no docking:**

- **Viewport** (centre): the scene drawn into a `Render_Target` and shown in a
  rectangle. Needs gap G1.
- **Hierarchy** (left): the entity list, indented by parent. A collapsible
  tree later.
- **Inspector** (right): the selected entity's components and their fields.
- **Assets** (bottom): the files under the project's asset folder.
- **Toolbar:** play, pause, stop, save.

**The inspector works by reflection.** `core:reflect` walks a component struct
and picks a widget for each field's type: a number field for `f32`, a toggle
for `bool`, a `dropdown` for an enum (`reflect.enum_string`), a colour field
for a `[4]f32` tagged as a colour. Ranges and hints come from struct tags
(`reflect.struct_tag_get`, checked present). The point is that **a new
component type shows up in the inspector without any editor code written for
it.**

**Widgets missing today**, placed by the dividing line:

- a toggle/checkbox, and a number field that changes when dragged: **Matchbox**
  (a game's settings menu wants both) -- gap G8
- a colour picker, a collapsible tree, a three-number vector row: **the
  engine** first, promoted to Matchbox if a game asks

**The editor camera** is separate from the game's camera and never saved into
the scene. Matchbox's orbit and first-person camera procedures already cover
it.

**Selection and picking:**

- 2D: `get_mouse_world_pos` and `is_mouse_over_sprite` exist.
- 3D: nothing yet -- gap G2.

**Gizmos** (move, rotate and scale handles): Matchbox has no 3D line drawing
-- only 2D `draw_line`/`draw_lines`, and wire cubes, bounds and a grid in 3D.
Projecting a handle's points through `camera3d_view_projection` and drawing 2D
lines over the viewport is enough, and it is how many editors keep gizmos
visible through geometry anyway.

**Undo:** before an edit starts, snapshot the component being edited -- it is
already serialisable, see 3.3. An undo entry is entity, component kind, before
and after. It works for every component for the same reason the inspector
does.

**Play mode:** on play, serialise the scene to memory; on stop, load it back.
Everything changed during play is thrown away. That is Unity's behaviour and a
well-known surprise, so the editor should look obviously different while
playing.

**Input while a game runs inside the viewport** -- a problem to solve, not yet
solved:

- Keyboard: which has focus, the editor or the game? It needs a focus rule.
- **Mouse: `get_mouse_position` is in window space.** A game drawn into a
  viewport rectangle inside the editor would get positions that are offset and
  scaled wrongly for everything it does with the mouse. Matchbox already maps
  window space to logical space for letterboxing (`draw_scale`,
  `draw_offset`); a viewport is the same mapping onto a different rectangle.
  Gap G3.

### 3.7 Export

The same game built without the editor (`#config(EDITOR, false)` or similar),
loading its scene files from its assets. Matchbox runs on Android and scenes
are read through `read_entire_file`, so an exported game should work there
too -- to be checked at milestone 5, not assumed.

### 3.8 Hot reload (later, spike first)

The usual Odin shape is a small host executable that loads the game as a DLL
and reloads it whenever it is rebuilt. Matchbox makes that harder in two
specific ways:

- **`mbi` is a package-level global** (types.odin:538, and checked to be the
  only one). A DLL that imports Matchbox gets its *own* `mbi`, blank. The state
  would have to be handed from the old DLL to the new one on every reload. The
  GPU objects inside it should survive, since they belong to `SDL3.dll`, which
  stays loaded.
- **`mbi.logger` holds a procedure pointer** into whichever module installed
  it; after a reload it points into unloaded code. Anything else in `mbi`
  holding a procedure has the same problem.

Plausible and unverified. A spike -- init, draw, reload, draw again -- comes
before anything is built on it.

### 3.9 Physics and audio

Both are engine components wrapping **Matchbox** systems; neither is engine
code. CLAUDE.md already puts physics and audio inside Matchbox's scope.

- Physics: today there are 2D AABB tests in `sprite.odin` and sprite
  hit-testing in `collisions.odin`, and nothing more. Gap G5.
- Audio: `sound.odin` has `load_sound`, `play_sound` and `destroy_sound`; the
  fuller audio API is merging in from separate work. Gap G6. Wait for that
  rather than designing a component around the current three procedures.

---

## 4. Matchbox gaps the engine will need

Every entry passes the dividing line: a hand-written game wants it too. Each
gets verified -- is it really missing, does the workaround really work --
before it is built, and moves to `improvements.md` or a plan of its own when
someone picks it up.

| id | gap | why a game wants it too | notes |
|---|---|---|---|
| G1 | draw a render target into a rectangle | split-screen, in-game monitors, minimaps | `draw_post` only covers the whole window (render_target.odin:232). Possible workaround: wrap `target.texture` in a `Mesh` for `create_sprite_from_mesh` -- but that needs a sampler from `mbi.renderer`, which is internal. **Untried.** |
| G2 | 3D picking: a screen-to-world ray, ray against box | clicking things in any 3D game | nothing exists; `model_center` and `model_size` give a model's box |
| G3 | input mapped into a sub-rectangle | a game drawn into part of the window | the same mapping as the letterbox's `draw_scale`/`draw_offset` |
| G4 | window settings passed to `init` | borderless, transparent or always-on-top windows (desktop-pet games); a remembered editor window size | `init` hard-codes `{.HIGH_PIXEL_DENSITY, .RESIZABLE}` (init.odin:499), and `.TRANSPARENT`/`.UTILITY` only work at window creation |
| G5 | physics | any game with collision | in scope per CLAUDE.md |
| G6 | audio beyond load and play | any game with sound | merging in from separate work |
| G7 | fixed timestep | frame-rate-independent gameplay | already in `improvements.md` |
| G8 | toggle and number-field widgets | settings menus | |

---

## 5. Milestones

Each milestone ends usable on its own, with a small **real game or example
driving it**. `improvements.md` exists because building real things is what
finds the gaps; building engine features for no game in particular is the
speculative work CLAUDE.md warns against.

**M0 -- decide and spike.**

- close open questions 1 to 3, at least
- spikes: the JSON round trip (3.3) and a render target in a rectangle (G1)
- *done when:* both spikes have a measured answer, and the decisions are
  recorded in section 7

**M1 -- the runtime, no editor.**

- a scene with handles, parents and transforms; components for sprite, model,
  light and camera
- the loop from 3.2; JSON save and load; scenes written by hand
- *done when:* an existing example (`third-person` or `lighting`) is rebuilt as
  a scene file and draws the same picture -- checked by comparing frames, not
  by eye

**M2 -- game code.**

- in whichever shape open question 2 settles on
- *done when:* a small game, around `pong` size, is playable from a scene file

**M3 -- the editor shell.**

- viewport, hierarchy, reflection-driven inspector, save
- *done when:* the M2 game's scene opens, a value is changed in the inspector
  and saved, and the change survives reopening it

**M4 -- editing for real.**

- selection and picking, gizmos, undo, play and stop, input routing (G3)
- *done when:* a level for the M2 game can be built in the editor without
  touching the scene file by hand

**M5 -- the rest.**

- asset browser; export for desktop, then Android; hot reload if its spike
  passed; prefabs

---

## 6. Open questions

1. **2D and 3D:** one scene kind or two? Which comes first?
2. **Game code:** does the engine own `main` (A) or the game (B)? See 3.5.
3. **Repository:** Matchbox as a git submodule (pinned, updated deliberately)
   or as an Odin collection pointing at a Matchbox checkout,
   `-collection:matchbox=../Matchbox` (always current, breaking changes
   included)? Leaning collection while both are under active work.
4. **House style:** does the engine adopt Matchbox's CLAUDE.md wholesale?
   Naming, grouped structs, comments that explain why, and verifying by
   measuring all carry over naturally. "No callbacks" depends on question 2.
   "One global" rests on Matchbox's reason for it -- an immediate-mode API --
   which the engine may or may not share.
5. **The engine's name.**
6. **Retained state:** may game code call `set_lights`, `set_lighting` or
   `camera_follow` directly, or only through components? Allowing it is
   flexible, and it means the scene and the code can disagree about what is
   lit.
7. **Fixed timestep:** in Matchbox's clock, or in the engine's loop?
8. **Import settings:** in the component, or in a sidecar file beside the
   asset?
9. **Level formats:** Tiled and LDtk support moved out of Matchbox into a
   package of its own (`refactor.md`). Does the engine import those levels, or
   is its editor the only way to build one?

---

## 7. Decisions

Each entry: the date, the decision, the alternative rejected, and what that
alternative would have broken.

*None yet.*

---

## 8. What has been checked, and what has not

**Checked in source, 2026-09-10:**

- `mbi` is the only package-level variable in Matchbox (types.odin:538)
- `draw_post` draws a render target over the whole window and nowhere else
  (render_target.odin:232)
- `create_sprite_from_mesh` takes a `Mesh`, which is a texture, a sampler and a
  size (types.odin:439, sprite.odin:111)
- `set_lights` replaces and keeps the whole light list (light.odin:274)
- `draw_model` with `casts_shadow` outside a 3D pass is queued for
  `begin_drawing_3d` (render3d.odin:603)
- no ray, picking or 3D line procedures exist; 2D `draw_line` and `draw_lines`
  do
- the UI widgets listed in 3.6 exist (ui.odin)
- Odin's JSON marshal honours `json:"-"` and writes enums as integers by
  default; `core:reflect` has `struct_tag_get` and `enum_string`

**Not checked:**

- JSON unmarshal of `json:"-"` fields and of enum names
- the `create_sprite_from_mesh` workaround for G1
- hot reload with `mbi` living inside a DLL
- whether a reflection-driven inspector, rebuilt every frame, is fast enough
- anything on Android

---

## 9. Progress log

- **2026-09-10** -- plan written. Nothing built, no decisions taken.
