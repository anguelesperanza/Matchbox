# Lighting Rework -- Implementation Plan

The spec is `lighting_plan.md`: every category (shading model, shadow
technique, render pipeline, GI method) is an interchangeable module behind a
shared contract, chosen by the game rather than by Matchbox. This file is how
that gets built here, in this package, against what is actually in the repo
today.

Read `lighting_plan.md` first. This document does not restate it; it answers
"how", "in what order", and "what breaks".

---

## 1. What is being ripped out

| File | Today | Fate |
| --- | --- | --- |
| `matchbox/light.odin` | `Light`, three constructors, `set_lights`, `set_light`, `clear_lights`, `set_ambient`, `set_fog`, `recompute_shadow_casters`, `push_lighting` | Rewritten whole |
| `matchbox/shadow.odin` | One `Shadow_Settings`, two hardcoded caster slots, ortho-or-perspective inline | Rewritten whole, split per technique |
| `matchbox/shaders/lighting.hlsli` | Cbuffer, one hardcoded Blinn-Phong-ish model, `fallback_shade`, fog, hardcoded shadow lookup | Deleted; replaced by a directory of contracts and modules |
| `matchbox/types.odin` | `Light_Uniform`, `Lighting_Data` (1248-byte cbuffer), `Mesh_Frag_Data` | `Lighting_Data` gone (storage buffer), `Mesh_Frag_Data` becomes `Material_Frag_Data` |
| `matchbox/render.odin` | `Pipelines` (flat list), `Shadow` struct on `Renderer` | Restructured -- see §4 |
| `matchbox/render3d.odin` | Pass orchestration hardwired to one forward pass + two shadow slots | Pipeline module dispatch |
| `matchbox/model_load.odin` | Reads base-colour texture only; everything else "ignored (D8)" | Reads a full material |
| `matchbox/shaders/mesh_flat.frag.hlsl`, `mesh_textured.frag.hlsl` | Two shaders differing only by a texture | Collapse to one -- see §3.4 |

Everything else in `matchbox/` is untouched except where it names a type that
moved.

### Two existing defects this rework is expected to fix

Both are recorded in `improvements.md` ("Lighting And Shadows Need A Ground-Up
Rework") and are the reason this is a rewrite rather than an extension.

1. **"Lighting is on" is emergent, not stated.** `flags.x` -- the count of
   lights handed to `set_lights` -- decides whether the real model runs or the
   hardcoded `fallback_shade` does. A game whose only light is a
   player-toggled flashlight therefore flips between lit and flat-lit shading
   as the player presses a key. After this rework, whether lighting runs is a
   scene-level statement (§3.1), and "unlit" is a shading model a material can
   choose, not an accident of list length.

2. **"Shadows are on" is emergent too.** `begin_shadow_pass` opens a real pass
   only if `recompute_shadow_casters` found something marked `casts_shadow` in
   *this frame's* list, so the same flashlight toggle silently switches the
   whole shadow system off while `enable_shadows` still reports true. After
   this rework, `enable_shadows` alone decides whether the shadow system runs;
   zero casters this frame means no shadows were cast, which is not the same
   statement.

---

## 2. The one hard constraint: Odin has no interfaces

`lighting_plan.md` asks for a strategy pattern. Odin offers procedure
pointers, tagged unions, and enums. CLAUDE.md rules out handing a game's
procedure back to the framework, and a GPU rules out calling a function
pointer per fragment anyway. So the contract is expressed twice, in the two
places the work actually happens:

- **In HLSL, the contract is a function signature.** A shading model is a
  `.hlsli` file that defines `brdf_eval` over a `Surface` and a `Light_Sample`
  and nothing else. A shadow technique is a `.hlsli` that defines
  `shadow_visibility`. Shared code `#include`s a dispatcher, never a specific
  module.
- **In Odin, the contract is an enum plus a table.** `Shading_Model`,
  `Shadow_Technique`, `Render_Pipeline_Kind` are enums; each has a table
  giving it its pipelines, its passes and its per-instance data. Shared code
  switches on the enum in exactly one place per category -- the dispatcher --
  and nowhere else.

**Why not procedure pointers in Odin.** They would satisfy "strategy pattern"
literally and buy nothing: the CPU side of a pipeline module is a handful of
pass-orchestration calls per frame, not a hot loop, and an enum switch in one
dispatcher is greppable, debuggable, and cannot be left dangling. It also
keeps the no-callbacks rule intact by construction rather than by discipline.

**The test for "is this actually modular"** is stated once and applied at
every review: *adding a sixth shading model must touch exactly three places*
-- a new `.hlsli`, a new enum value, and one line in each dispatcher. If it
touches shared code anywhere else, the seam is in the wrong place.

### Correction, found while building P0

The contract above was drafted as `brdf_eval(Surface, Light_Sample)` -- one
call per light, summed by shared code. **It does not fit the model P0 had to
port.** PsxGame's formula is

	base_color * (1 + sum(specular)) * sum(diffuse)

which carries a genuine cross term between every pair of lights: one light's
specular multiplies another light's diffuse. That is not decomposable into an
order-independent sum of independent per-light contributions, so a strict
per-light contract cannot express it.

What P0 shipped instead: each model owns its whole light loop, reading
`lights`, the light count and `shadow_visibility` as ordinary globals -- which
any included file can see, so nothing needs threading through a parameter
list. The three-places property still holds.

**This is a weaker seam than intended and should not be permanent.** Light
iteration, attenuation and the shadow lookup are now duplicated in every
model rather than written once, which is exactly the "shared code should only
assume the interface" property §1 of the spec asks for. The only thing forcing
it is a formula §7.4 has already released from being a constraint. So: when
P2 adds the physically-based models, restore `brdf_eval(Surface, Light_Sample)`
as the contract for every model that is an order-independent sum -- which is
all four of the remaining ones -- and let `blinn_phong` keep its own loop as
the documented exception rather than letting the exception set the contract
for everything.

---

## 3. Architecture

### 3.1 Scene-level state

One struct, set explicitly, replacing the "count of lights implies the mode"
arrangement:

```odin
Lighting_Settings :: struct {
	enabled:       bool,                 // does the lighting model run at all
	pipeline:      Render_Pipeline_Kind, // FORWARD / DEFERRED / CLUSTERED
	shadows:       Shadow_Settings,      // technique + its own parameters
	ambient:       Ambient,              // constant / hemisphere / environment probe
	exposure:      f32,
	tonemap:       Tonemap,              // NONE / REINHARD / ACES / AGX
	fog:           Fog,                  // its own `enabled`, not a flag bit
}

set_lighting :: proc(settings: Lighting_Settings = LIGHTING_DEFAULTS)
```

`LIGHTING_DEFAULTS` is the `BUTTON_STYLE` precedent from `ui.odin` -- a named
constant of struct type, which CLAUDE.md explicitly sanctions as a default
parameter value. Nothing here becomes a loose package-level variable.

### 3.2 `Surface` -- the abstraction that makes shading pipeline-agnostic

This is the centre of the design and the thing `lighting_plan.md` §3 is
actually asking for. A `Surface` is everything a BRDF needs to know about a
point, with nothing in it about how that point was reached:

```hlsl
struct Surface
{
    float3 position;      // world
    float3 normal;        // world, normalized, normal map already applied
    float3 view;          // normalized, toward the eye
    float3 base_color;
    float  alpha;
    float  metallic;      // metallic-roughness
    float  roughness;
    float3 specular;      // specular-glossiness
    float  glossiness;
    float3 emissive;
    float  occlusion;
    float3 subsurface;    // tint for the SSS model
    float  thickness;
    uint   shading_model; // which brdf_eval to dispatch to
    float  bands;         // toon
    float  rim;
};
```

A forward fragment shader fills it from interpolants and texture samples. A
deferred lighting pass fills the identical struct from G-buffer reads. Both
then call the same `shade_surface(Surface, ...)`. **No BRDF file ever learns
which of the two happened**, which is the property that lets step 2 of the
spec's build order ("port the validated modules outward") be a copy of an
include line rather than a rewrite.

Fields a given shading model does not use ride along unread, the same way
`Light_Uniform.cone` already does for non-spot lights.

**`Surface` must also be fillable from a 2D sprite fragment.** That is a
decision (§7.3) and it constrains this struct now rather than in P8: no field
may assume a 3D mesh produced it. A sprite fills `position` with its world
position at z = 0, `normal` with `{0, 0, 1}` or its normal map, and `view`
with the 2D camera's forward -- and every BRDF then works on it unchanged.
Anything that cannot be given a sensible value by a sprite does not belong in
`Surface`; it belongs in the pipeline module that needed it.

### 3.3 Lights

```odin
Light_Kind :: enum {
	DIRECTIONAL,
	POINT,
	SPOT,
	AREA_RECT,
	AREA_DISK,
}
```

Ambient/environment is not in this enum -- it is scene state (§3.1), because
it has no position and is not culled.

**The fixed 16-slot cbuffer goes.** Lights move to a `StructuredBuffer`, which
is the precedent `Skin_Vert_Data` already set in this package for exactly this
reason: the joint palette hit SDL's Vulkan 4096-byte uniform sectioning and
moved to a storage buffer, and `types.odin` documents the whole hunt. An
unbounded light list is a hard prerequisite for clustered culling (§3.6), so
this happens in the first phase rather than later.

`MAX_LIGHTS` therefore disappears as a shader constant. It survives only if a
fixed array bound is still needed somewhere on the Odin side, which is one of
CLAUDE.md's narrow exceptions.

### 3.4 Materials, and one shader instead of two

There is no material type in Matchbox today. `Mesh_Frag_Data` is a single
`tint`, and `model_load.odin` reads a glTF material's base-colour texture and
throws the rest away.

```odin
Material :: struct {
	shading:        Shading_Model,
	base_color:     [4]f32,

	// Per-model parameters, flat rather than a union: a cbuffer wants a flat
	// layout, and which fields mean anything is documented per shading model.
	metallic:       f32,
	roughness:      f32,
	specular:       [3]f32,
	glossiness:     f32,
	specular_power: f32,     // Blinn-Phong
	bands:          f32,     // toon
	rim:            f32,
	subsurface:     [3]f32,
	thickness:      f32,
	emissive:       [3]f32,

	textures:       Material_Textures, // base, metal-rough, normal, occlusion, emissive
}

create_material_pbr   :: proc(base_color := WHITE, metallic: f32 = 0, roughness: f32 = 0.5, ...) -> Material
create_material_phong :: proc(...) -> Material
create_material_toon  :: proc(...) -> Material
create_material_unlit :: proc(...) -> Material
```

Every argument defaulted, per CLAUDE.md's "configuration rides in as a
defaulted struct".

**`mesh_flat` and `mesh_textured` collapse into one shader.** They exist today
only because an untextured part has no texture to bind at `t0`, and that in
turn forces `lighting.hlsli`'s ugliest comment -- the one explaining that the
two shadow maps sit at `t0/t1` in one shader and `t1/t2` in the other, and
that `draw_model_immediate` has to compute `shadow_slot: u32 = 1 if textured
else 0` to match. Binding a 1x1 white texture for an untextured part removes
all of it. The 1x1 placeholder trick is already in this codebase -- `init`
makes exactly that for the shadow maps so the samplers always have something
valid bound.

This halves the mesh pipeline count before any of the new axes multiply it.

### 3.5 Shader permutations

Axes, and how each is handled:

| Axis | Values | Handled by |
| --- | --- | --- |
| Vertex layout | static / skinned | **Permutation** -- a different vertex layout is a different pipeline, no choice |
| Render pipeline | forward / gbuffer-fill / deferred-lighting / clustered-forward | **Permutation** -- different targets, different pass shapes |
| Shading model | 5 | **Uniform branch** in `shade_surface` |
| Shadow technique | 4 | **Uniform branch** in `shadow_visibility` |
| Textured / not | -- | **Gone** (§3.4) |

The BRDF and the shadow technique are branched, not permuted, and the reason
is specific to this repo: `build_shaders.bat` compiles committed `.spv` *and*
`.dxil` blobs, both checked into git, and CLAUDE.md calls a change to one
without the other "a broken build for somebody". Permuting five shading
models across four pipelines across two vertex layouts is 40 fragment shaders
= 80 committed binaries that must all be regenerated together. Branching costs
a scalar compare on a value that is uniform across an entire draw call, which
is not a measurable cost on any GPU this framework targets.

Permutation is still available per-axis if measurement later says a branch is
too expensive somewhere; the module contract does not change either way, which
is the point of having one.

### 3.6 Render pipeline modules

```odin
Render_Pipeline_Kind :: enum {
	FORWARD,
	DEFERRED,
	CLUSTERED,
}
```

Each owns: which passes run in what order, which render targets exist, and how
lights reach a fragment. Each conforms to the same CPU-side shape -- a
`begin`, a per-draw `submit`, an `end` -- called by `begin_drawing_3d` /
`draw_model` / `end_drawing_3d`, which stop containing pipeline-specific code
entirely.

- **Forward** -- built and validated first, per the spec's own build order.
  What exists today, cleaned up.
- **Clustered forward+** -- forward plus a compute-built cluster light list.
  Shares the forward fragment path; the only difference is which lights it
  loops over.
- **Deferred** -- a G-buffer fill pass writing `Surface` fields to MRT, then a
  fullscreen lighting pass reconstructing `Surface` and calling the identical
  `shade_surface`. Transparent draws fall back to the forward path inside the
  same frame; the spec says to expect this and it is not a design flaw.

**Sequencing rule, from the spec:** forward is finished and validated before
either of the others begins. Building three from scratch in parallel
multiplies bugs across codepaths.

### 3.7 HDR, early

`lighting_plan.md` §4 says the HDR pipeline should be established early, and
it has to be here for a structural reason: today `lighting.hlsli` does
`pow(color, 1.0/2.2)` *inside* the shading function, before fog. That bakes a
transfer function into the BRDF, which makes every BRDF module non-portable
and makes tone mapping impossible to add later without changing all of them.

So: the 3D pass renders into an `RGBA16_FLOAT` target, and a tonemap+encode
pass resolves it to the swapchain. `render_target.odin` and `post.odin`
already externalize a render-to-texture pass to the caller, so the machinery
exists; this makes the 3D path use it by default rather than by hand.

Consequence to state plainly: this changes what existing scenes look like.
`set_fog`'s colour is currently mixed *after* gamma, so it means "the colour
you picked". Under HDR that mix moves into linear space before tone mapping,
and a fog colour carried over from PsxGame will not land on the same pixel
value. See §6.

### 3.8 File layout

Flat, in `matchbox/` -- Matchbox is one package and a subdirectory would break
`mb.` for everything in it.

```
matchbox/
  lighting.odin           scene state, Lighting_Settings, the dispatcher
  light.odin              Light, the five kinds, the light storage buffer
  material.odin           Material, its constructors, Material_Frag_Data
  shading.odin            Shading_Model enum + per-model metadata table
  shadow.odin             Shadow_Settings, Shadow_Technique enum, shared state
  shadow_standard.odin    single depth map
  shadow_cascaded.odin    CSM
  shadow_cube.odin        point-light cube maps
  pipeline_forward.odin
  pipeline_clustered.odin
  pipeline_deferred.odin
  light_cull.odin         frustum + cluster assignment
  tonemap.odin            HDR resolve, exposure
  gi.odin                 probes, SSAO, reflection probes  (late phases)

matchbox/shaders/
  surface.hlsli           the Surface struct, shared by every pipeline
  lighting_core.hlsli     light iteration, attenuation, dispatch to a BRDF
  brdf/contract.hlsli     the signature every model below conforms to
  brdf/blinn_phong.hlsli
  brdf/pbr_metallic.hlsli
  brdf/pbr_specgloss.hlsli
  brdf/toon.hlsli
  brdf/subsurface.hlsli
  brdf/unlit.hlsli
  shadow/contract.hlsli
  shadow/pcf.hlsli
  shadow/pcss.hlsli
  shadow/cascaded.hlsli
  shadow/cube.hlsli
```

`build_shaders.bat` / `.sh` compile `*.vert.hlsl` and `*.frag.hlsl` only, so
`.hlsli` files in subdirectories are picked up by `#include` and compiled as
neither -- which is already why `lighting.hlsli` is spelled that way. `dxc`
resolves `#include` relative to the including file, so the subdirectories work
as written; the scripts gain an `-I` pointing at `shaders/` anyway, so a module
can include a sibling contract by a stable path rather than a relative one.

---

## 4. Renderer restructuring

`Renderer` (in `render.odin`) currently carries lighting and shadow state as
loose-ish fields alongside `Pipelines`' flat list. Per CLAUDE.md's "group like
data into structs", all of it moves under one `Lighting` field:

```odin
Renderer :: struct {
	// ... unchanged ...
	lighting: Lighting, // was: `lighting: Lighting_Data` + `shadow: Shadow` + `in_shadow_pass`
}

Lighting :: struct {
	settings:     Lighting_Settings,
	lights:       [dynamic]Light,     // CPU side
	light_buffer: ^sdl.GPUBuffer,     // GPU side, grown on demand
	shadow:       Shadow_State,
	targets:      Lighting_Targets,   // HDR colour, G-buffer, cluster grid
	pipelines:    Lighting_Pipelines, // the permutation table from §3.5
}
```

`Pipelines` keeps the 2D entries and loses every 3D-lighting one to
`Lighting_Pipelines`, which is indexed by the permutation axes rather than
being a flat list of named fields.

---

## 5. Phases

Each phase is a unit of work with its own verification gate. **A phase does
not start until the previous one passes `odin check matchbox -no-entry-point`,
builds every example, and passes its own tests.**

### P0 -- Foundations, and the demolition (blocking, single worker)

The only phase that touches nearly every file, so nothing else runs alongside
it.

- `Surface` struct and the two contracts (`brdf/contract.hlsli`,
  `shadow/contract.hlsli`).
- `Shading_Model`, `Shadow_Technique`, `Render_Pipeline_Kind` enums and their
  dispatchers.
- `Material` + constructors; `Mesh_Frag_Data` -> `Material_Frag_Data`.
- Lights to a storage buffer; `Lighting_Data` cbuffer deleted; `MAX_LIGHTS`
  retired as a shader constant.
- `Lighting_Settings` and explicit on/off (fixes both defects in §1).
- Collapse `mesh_flat`/`mesh_textured` via the 1x1 white default texture;
  delete the `shadow_slot` offset logic in `draw_model_immediate`.
- Port the existing shading into `brdf/blinn_phong.hlsli` **unchanged, constant
  for constant** -- the same attenuation curve, the same exponent of 16, the
  same ambient/10. Not because that look is being preserved (it is not, §7.4)
  but because it is the only way this phase gets a reference picture to be
  checked against: a refactor that also changes the maths cannot be verified.
- Port today's shadow mapping into `shadow_standard.odin` + `shadow/pcf.hlsli`
  behind the new seam, still two casters.
- `Renderer` restructuring (§4).
- Rewrite `examples/lighting` and `examples/post` against the new API -- §7.1
  is a clean break, so the phase that deletes the old procedures is the phase
  that fixes their callers.

**Gate:** `examples/lighting` renders the same as it does on `main` at the same
camera and the same toggles. Verified by capture and comparison, not by eye.

### P1 -- HDR and tone mapping

- `RGBA16_FLOAT` scene target, tonemap+encode resolve pass.
- `pow(1/2.2)` out of every BRDF; exposure and `Tonemap` in
  `Lighting_Settings`.
- Fog moves into linear space before the tonemap.

**Gate:** a known linear input value produces the expected encoded output for
each tonemap curve, asserted numerically. Documented before/after for
`examples/lighting` -- this phase changes the picture on purpose.

### P2 -- Shading models (parallelizable)

One worker per model, each writing one `.hlsli`, one enum value, one
dispatcher line, one test. They do not share files beyond the two one-line
edits.

- `pbr_metallic` (Cook-Torrance GGX + Smith + Schlick)
- `pbr_specgloss`
- `toon`
- `subsurface`
- `unlit`
- `model_load.odin` reads the full glTF material (metallic-roughness factors
  and textures, normal, occlusion, emissive) -- a separate worker; it touches
  the loader and no shader.

**Gate:** white-furnace test for both PBR models (uniform environment in,
energy-conserving out, no energy gain at any roughness), asserted against an
independent implementation the way the skinning palettes and skybox sampling
already were.

### P3 -- Shadows

- A bias framework as a first-class thing: per-technique, per-light, with
  normal-offset alongside depth bias.
- **An acne / peter-panning validation harness.** The spec is explicit that
  these are artifacts and not features. The harness renders a known scene at a
  grazing light angle, samples the shadow map, and asserts numerically: no
  self-shadowing on a lit surface, and a caster's contact point stays within N
  texels of its base.
- PCF (from P0) -> PCSS.
- Cascaded shadow maps for directional lights.
- Cube shadow maps for point lights -- this removes the "point lights cannot
  cast shadows" degrade that `shadow.odin` documents today.

**Gate:** the harness above, run for every technique.

### P4 -- Light types

- Area lights (rect and disk, LTC or a documented approximation).
- Ambient/environment as a module: constant, hemisphere, and an environment
  probe with prefiltered IBL feeding the PBR models.
- All kinds coexisting in one scene, asserted.

### P5 -- Clustered forward+

- Frustum culling, then cluster assignment (compute), then a per-cluster light
  list the forward fragment path loops over instead of every light.
- `light_cull.odin`.

**Gate:** identical picture to plain forward for a scene of N lights, plus a
measured light-count scaling curve for both.

### P6 -- Deferred

- G-buffer fill writing `Surface` fields; fullscreen lighting pass
  reconstructing them.
- Forward fallback for transparent draws in the same frame.

**Gate:** identical picture to forward for opaque geometry under every shading
model -- which is the real test of whether §3.2's abstraction held.

### P7 -- GI and post layers

SSAO, light probes, baked lightmaps, reflection probes; bloom, colour grading,
volumetrics as consumers of the HDR buffer. Each optional and layered, none
assuming a pipeline or a shading model upstream.

### P8 -- 2D

Only after 3D is done, per the brief. Both halves of §7.3, sharing the 3D
core:

- Sprites carry an optional normal map and fill a `Surface` (§3.2), so they
  run the same BRDFs the meshes do. A sprite with no normal map gets
  `{0, 0, 1}` and is lit as a flat card, which is the sensible default rather
  than a special case.
- 2D light volumes -- a radial falloff mask, and 2D occluder geometry casting
  into it -- for the stylised case where a real BRDF is more than the picture
  wants. This is a `Shadow_Technique` and a light kind, not a second lighting
  system.

---

## 6. What this breaks, and what is said about it

The rewrite changes how existing games look. This is stated up front rather
than discovered:

- **`set_lights` / `set_light` / `clear_lights` / `set_ambient` / `set_fog`**
  are deleted outright, with no deprecated wrapper -- §7.1. `examples/lighting`
  and `examples/post` are rewritten in the same phase that deletes them.
- **The fallback shading disappears as an implicit mode.** A scene that set no
  lights got a hardcoded direction; that behaviour becomes an explicit
  `Shading_Model.UNLIT` or `Lighting_Settings{enabled = false}`. Any example or
  game relying on the implicit version needs a one-line change.
- **Colours shift under HDR (P1).** Fog especially -- see §3.7.
- **`MAX_LIGHTS` and `Lighting_Data` leave the public surface.** `cheatsheet.md`
  is generated (`python tools/gen_cheatsheet.py`) and is regenerated at the end
  of every phase, not once at the end.
- **Both `.spv` and `.dxil` are committed for every shader touched, in the same
  commit.** CLAUDE.md: one without the other is a broken build for somebody.
- **`matchbox/light_test.odin`** tests `light_uniform`'s packing into a struct
  that will not exist. Rewritten in P0 against the storage-buffer layout.

---

## 7. Decisions

Answered once, and not re-litigated per phase.

1. **Compatibility: clean break.** `set_lights`, `set_light`, `clear_lights`,
   `set_ambient`, `set_fog` and the current `enable_shadows` shape are deleted
   outright. No deprecated wrapper -- a shim would have to reproduce the
   emergent "no lights means fallback shading" behaviour that §1 exists to
   remove, which would leave two contradictory answers to "is the lighting on"
   in the package at the same time. `examples/lighting` and `examples/post`
   are rewritten against the new API inside the phase that breaks them, so the
   repo compiles end to end at every phase boundary. Games port once.

2. **Breadth: P0 alone, then review.** The architecture is proved on a
   known-good picture before anything is built on it. If the seam is in the
   wrong place, it is in the wrong place exactly once. P1 onward is dispatched
   after P0's gate passes and the result has been looked at.

3. **2D (P8): both, sharing the 3D core.** Normal-mapped sprites filling a
   `Surface` and running the real BRDFs, *and* 2D light volumes for the
   stylised case. The consequence lands in P0, not P8: `Surface` is designed
   to be fillable from a sprite fragment from the start -- see §3.2.

4. **Look preservation: none.** P0 ports PsxGame's constants unchanged
   *purely as a refactor checkpoint* -- it gives the phase a reference picture
   to be verified against, which is the only reason to keep them. After that
   they are not a constraint on anything. The PBR models are physically
   correct rather than tuned toward the old picture, HDR and tone mapping
   choose sensible defaults rather than round-tripping existing scenes, and
   existing scenes get retuned by hand. `brdf/blinn_phong.hlsli` is still a
   real, supported module; it is just no longer a compatibility contract.

---

## 8. Verification standard

CLAUDE.md: verify by measuring, not by looking. For this system specifically:

- **Numeric, not visual, wherever possible.** BRDF outputs asserted against an
  independent implementation (numpy, as the skinning palettes and skybox
  sampling already were). Furnace tests for energy conservation. Shadow-map
  texel comparisons for the acne/peter-panning harness.
- **Synthetic input.** Lights driven by writing state directly, the way
  `mbi.input.keys[.W].pressing = true` already drives input tests.
- **Report what was and was not checked.** "I have not seen it render" stays a
  useful sentence. Every phase's report says which claims are measured and
  which are inferred.
- **Every phase gate is a command that either passes or does not**, not a
  judgement.
