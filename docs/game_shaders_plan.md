# Game shaders: opt-in, PC first (proposal)

**Status: built 2026-11-27, PC only. The user approved the API and answered D1-D5 (below).** This is the "custom shaders in the engine"
item of Phase S, brought forward because a game that wants the PSX look must not carry it when it does not.

## What exists today (read from the code)

- Five built-in pipelines (unlit, per-pixel lit, per-vertex lit, skinned, skinned lit), all `#load`ed and created in `create_pipeline`
  (`render_windows.odin`), so every game has them. The skybox's pipeline is created there too.
- `render_item` picks the pipeline per draw from the mesh (`item.mesh.skinned`, `item.mesh.lit`) and the lighting mode. A game cannot
  choose.
- `set_shader_value(name, value)` writes the uniforms declared in `mesh.mbs` only. No second texture per draw. `render_upscaled_target`
  draws the target with the sprite pipeline; no shader argument.
- mbsc writes HLSL plus a `.refl` file (where every uniform, texture and sampler is bound) for PC. The engine compiles the HLSL at
  startup with `d3dcompiler`. The `.refl` is all a runtime needs to bind a shader it has never seen, which is why this can be done
  without a new compiler.
- The handhelds take a `.shbin` (picasso) or `.gxp` (vito) made at build time. mbsc does not write either (S8a/S8b are open), so a
  game shader on a handheld is a build-script job, not only an engine one. **Out of scope here: PC first, as decided.**

## What the PSX look needs (from `main`'s `psx_geometry.odin` and `psx.frag.hlsl`)

1. **Geometry:** vertices snapped to a coarse grid, and affine (non-perspective) texture mapping. Both are done *while the model is
   drawn*: a vertex-shader and pixel-shader change, so it is a **mesh shader**, and it has to exist for the **skinned** character too.
2. **Screen filter:** coarse pixels, ordered dither, 15-bit colour, scanlines. A full-screen pass over a render target: a **post shader**.

## The design

**One principle: a shader exists only after the game loads it.** The built-ins stay (every game draws a mesh). Everything else is a
file the game names.

```odin
Shader :: struct { /* backend handles, kind, vertex layout */ }

load_shader :: proc(name: string) -> Shader      // stops with a message if missing, like load_model
load_shader_checked :: proc(name: string) -> (Shader, bool)
destroy_shader :: proc(shader: Shader)           // joins the `destroy` group

set_shader :: proc(shader: Shader)               // the shader for what is rendered next; Shader{} is the built-in
set_shader_value :: proc(name: string, value: any, shader := Shader{})   // zero Shader = mesh.mbs, as today
render_upscaled_target :: proc(target, fit, tint, shader := Shader{})     // a post shader
```

- **`set_shader` is immediate-mode state, like `set_lights`**: everything queued after it uses it until it is called again. The shader is
  stored in each `Render_Item` and goes into the sort key, so the item order does not change which shader draws it.
- **A mesh shader replaces the built-in for the vertex layout it declares.** One `load_shader("psx")` finds `psx` (static lit),
  and optionally `psx_skinned`; a mesh whose layout the shader has no pipeline for draws with the built-in. So the PSX shader looks
  the same on the character and the walls without the game choosing per model.
- **A post shader** takes the render target's texture as its first texture, and its uniforms (`resolution`, `grid`) are set with
  `set_shader_value("grid", {320, 240}, shader)`.
- **Files and where they live:** `assets/pc/shaders/<name>.pc.hlsl` and `.pc.refl` (the target folder first, then `assets/shaders/`,
  as models and images are found). Matchbox ships `psx.mbs`, `psx_skinned.mbs` and `psx_post.mbs` as **sources in
  `matchbox/optional/shaders/`**, with their generated PC files beside them, **not `#load`ed**: Odin embeds a `#load` in every binary,
  so an optional shader must be a file read at runtime or it ships in every game. A game copies the ones it uses into its assets
  (documented; `farlite` could automate it later).
- **Cost to a game that does not use it: none** (no pipeline created, no bytes in the binary). A game that does pays the HLSL compile at
  `load_shader`, between frames, like `load_model`.
- **Handhelds:** the names exist and stop with "custom shaders are PC only for now", as the skybox does. Making them real needs
  S8a/S8b or a build step that runs mbsc, picasso and vito per game shader; I would write that plan once the PC side is proven.

## Also proposed, same principle (small)

Move the **skybox** pipeline out of `create_pipeline` and make it on the first `load_skybox_*`, so a game with no sky does not
compile its shader at startup. This is the same complaint as PSX and the change is a few lines.

## Decisions (answered 2026-11-27)

1. **`set_shader` as state, or a `shader` field on the draw?** State matches `set_lights`/`set_shader_value` and keeps the render calls
   as they are; a field on `render_model` is more explicit but touches every draw. I recommend state.
2. **One name finds the static and skinned variants (`psx`, `psx_skinned`)?** The alternative is `set_shader` and
   `set_skinned_shader`. I recommend the one name: a game should not have to know which models are skinned.
3. **Where optional shaders are kept and how a game gets them:** a game copies them from `matchbox/shaders/optional/`, or `farlite`
   copies those named in a project file. I recommend copying by hand now, farlite later.
4. **Skybox made lazy as part of this?** I recommend yes.
5. **Do the PSX files go in this work?** The mesh and post shaders are the test that the design holds, so I would port them as the
   first two users (their pixel-shader changes are not part of the API). The user said the PSX port is theirs "later"; say if the
   PSX files wait and only a small test shader goes in.

## What I would verify

- A game that never calls `load_shader` creates five pipelines (and no skybox) and its binary contains no optional shader text.
- A shader with a uniform declared in its `.mbs` receives `set_shader_value` writes, read back by drawing into a target and
  asserting pixels (the way `gate-check` does).
- A mesh shader is used for a static mesh and the built-in for a mesh it has no layout for; a post shader changes a render
  target's pixels in the way its source says (a solid colour shader first, then the dither).
- Wrong use (a shader for the wrong kind, a missing uniform name) stops with a message that names the shader and the uniform.

## Order of work

1. API and PC backend (load, set_shader, per-item pipeline, reflection-driven binding) with a test shader.
2. Lazy skybox.
3. A post shader (the PSX filter), then the mesh shaders (static, skinned).
4. Documentation in `docs/api.md` and `docs/shader_language.md`.

## What was decided

D1 **state** (`set_shader`), D2 **one name** (`load_shader("psx")` also loads `psx_skinned`), D3 **copy by hand for now**, and once
this API works **farlite has to be taught to copy the shaders a game names** (not done: a follow-up), D4 **lazy skybox** (done),
D5 **the PSX files go in this work** (done: `psx`, `psx_skinned`, `psx_post`).

## How a game uses it

1. Copy `matchbox/optional/shaders/psx.pc.hlsl`, `.pc.refl`, `psx_skinned.pc.*` and `psx_post.pc.*` into `assets/pc/shaders/`
   (or `assets/shaders/`). Only the ones it uses.
2. `psx := mb.load_shader("psx")` and `post := mb.load_shader("psx_post")`, between frames.
3. `mb.set_shader(psx)` before drawing the scene into the target and `mb.set_shader({})` after it; `set_shader_value("psx_grid",
   [2]f32{320, 240}, psx)` and `set_shader_value("grid", [2]f32{320, 240}, post)`.
4. `mb.render_upscaled_target(view.target, .FIT, shader = post)`.

## What was measured, and what was not

Measured on a WARP device, pixel by pixel (`shader_windows_test.odin`): a loaded shader draws and takes its uniforms (a
mutation that skipped the dirty flag fails it); a shader given to one draw does not change the state; the queue groups by shader;
a mesh the shader has no pipeline for draws with the built-in; the sky's shaders and any game shader cost nothing until asked; the
PSX filter's dither, five-bit colour and scanlines match numbers worked by hand (mutation-checked); the PSX mesh shader's snap
collapses a quad on a coarse grid, each axis on its own (mutation-checked).

Not measured: the affine texture mapping (worked out on paper, in the header of `psx.mbs`; its only proof is the picture), the
skinned PSX variant drawing a posed character (it loads, and shares the code of the static one), a game's binary being free of
the optional shader text (nothing `#load`s them, so it should be), and anything on a handheld.
