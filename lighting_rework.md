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
every review: *adding a shading model must touch only its own file, one enum
value, and one line in each dispatcher.* If it touches shared code anywhere
else, the seam is in the wrong place.

**The honest count is five, measured rather than predicted.** P2c added four
models and the footprint of each was: its own `.hlsli`; one `Shading_Model`
value paired with its `SHADING_*` define; one `#include` in
`lighting_core.hlsli`; one line in `brdf_light`'s switch; one line in
`brdf_resolve`'s switch. The `#include` is the one this section did not
foresee, and it is mechanical rather than a judgement -- but a count that
quietly omits it is a count nobody can check a diff against, so five it is.

Two things P2c proved rather than assumed. `pbr_common.hlsli` -- the GGX,
Smith and Schlick maths both PBR models share -- is a plain function library
neither dispatcher knows about, the same relationship `shadow/pcf.hlsli` has
to `shadow_visibility`; a shared helper is not a sixth place. And the only
edits to `mesh.frag.hlsl` and `surface.hlsli` across the whole phase were
comment corrections, which is the strongest evidence available here that
shared code really does not know which model is running.

### 2.1 The per-light contract -- what P0 shipped, and what P2 replaces it with

P0 shipped a weaker seam than this section describes, for a reason that
turned out not to hold. Recorded here in full because the fix is P2's first
job and the wrong conclusion is easy to reach twice.

**What P0 shipped.** Each model owns its whole light loop, reading `lights`,
the light count and `shadow_visibility` as ordinary globals. The reasoning was
that PsxGame's formula

	base_color * (1 + sum(specular)) * sum(diffuse)

carries a cross term between every pair of lights -- one light's specular
multiplies another light's diffuse -- and so cannot be expressed as a sum of
independent per-light contributions.

**Why that is wrong.** It is true only if a light's contribution has to be a
single `float3`. Both factors above are *plain sums*; only the final combine
is nonlinear. Split accumulation from resolution and the cross term is
expressed exactly, with no special case.

**The contract, in three pieces.** Today's `brdf_eval_blinn_phong` fuses three
jobs, and two of them are not model-specific at all.

*One -- sampling a light. Shared, written once.* What arrives at a surface
from light `i`:

```hlsl
struct Light_Sample
{
    float3 direction; // normalized, surface toward the light
    float3 radiance;  // color * attenuation * shadow -- what actually lands
    float  n_dot_l;   // clamped; every model wants it
};

Light_Sample sample_light(uint i, Surface surface);
```

That is the directional/point/spot resolution, the attenuation curve, the cone
smoothstep and the `shadow_visibility` call -- lines 39 to 79 of P0's
`brdf/blinn_phong.hlsli`, lifted into shared code verbatim. **Shadow and
attenuation are already multiplied into `radiance`**, which is the whole point:
a BRDF never learns whether a shadow map, a cone or distance dimmed the light.

*Two -- evaluating one light. The model's actual job.* Named channels rather
than one colour, which is what makes Blinn-Phong expressible:

```hlsl
struct Radiance
{
    float3 diffuse;
    float3 specular;
};

Radiance brdf_light_<name>(Surface s, Light_Sample l);
```

*Three -- resolving the sums.* Where a model's own weirdness lives:

```hlsl
float3 brdf_resolve_<name>(Surface s, Radiance total);
```

Blinn-Phong's is `s.base_color * (1 + total.specular) * total.diffuse +
s.base_color * (ambient.rgb / 10.0)` -- arithmetic identical to P0's. PBR's is
`total.diffuse + total.specular + s.emissive + ambient * s.occlusion`, which is
the boring case this was designed for. Toon bands `n_dot_l` inside its own
`brdf_light_toon` and resolves trivially.

**The loop moves to shared code**, in `lighting_core.hlsli`:

```hlsl
float3 shade_lights(Surface surface)
{
    Radiance total = (Radiance)0;

    uint count = uint(flags.x);
    for (uint i = 0; i < count; i++)
    {
        Light_Sample l = sample_light(i, surface);
        Radiance r = brdf_light(surface, l);   // dispatches on surface.shading_model
        total.diffuse  += r.diffuse;
        total.specular += r.specular;
    }

    return brdf_resolve(surface, total);       // dispatches too
}
```

**What this buys, and it is the point of doing it:** P3 and P4 stop touching
BRDF files. Cube shadow maps, PCSS and CSM all land inside `shadow_visibility`,
which `sample_light` already calls -- so point-light shadows are one file
changed rather than five. Anything that changes attenuation is the same.

**What it costs, stated rather than discovered:**

- **The modularity test loosens from three places to four.** A new model is a
  new `.hlsli`, a new enum value, and one line in *each* of two dispatchers.
  Still bounded and mechanical, but §2's headline property is now four, not
  three.
- **The dispatch runs inside the loop.** `surface.shading_model` is uniform
  across a draw, so it predicts perfectly and is generally hoisted. If
  measurement ever says otherwise, the fix is a macro generating the loop per
  model -- not worth doing pre-emptively, and not worth assuming is needed.
- **Area lights (P4) do not fit this shape.** An LTC area light integrates over
  a polygon; there is no single `direction` and no single `radiance`. That
  needs either a second entry point on the contract or a representative-point
  approximation. Known now so P4 is not a surprise; it is not an argument
  against doing this for the four punctual-light models.

  **Answered by P4, and the contract held.** The representative-point route was
  taken: `area_light_representative_point` (`lighting_core.hlsli`) reduces a
  rect or disk to a single point by reflecting the view ray against the light's
  own plane and clamping onto its shape, which `sample_light` then packs into an
  ordinary `Light_Sample`. **No `brdf/*.hlsli` file mentions an area light** --
  verified by grep across the directory, not by assertion -- so `Light_Sample`
  needed no second entry point and no widening. The contract absorbed a light
  kind it was not designed for, which is the strongest evidence so far that the
  seam is in the right place. What it costs is stated rather than hidden: this
  is an approximation, not an integral, and an area light does not cast a shadow
  this phase.
- **One wrinkle in the port.** P0 accumulates specular *uncoloured* (`spec *
  attenuation * shadow`) while diffuse carries the light's colour. Folding
  colour into `radiance` means specular would have to divide it back out to
  stay constant-for-constant. Since §7.4 has already released the old look,
  the right move is to let specular be coloured -- physically correct, and it
  deletes the awkward line. **This is a deliberate look change to
  `blinn_phong`, and the first one this rework makes.**

**Known cost, accepted when P2b landed: `UNLIT` pays for the whole loop.**
`shade_lights` calls `sample_light` -- including its shadow lookup -- once per
light before dispatching into a model that, for `UNLIT`, throws every one of
them away. P0's `brdf_eval_unlit` did none of that. It bites in two places: a
material that chose `Shading_Model.UNLIT` inside a lit scene, and *every*
material when `Lighting_Settings.enabled` is false while lights are still set
-- which is meant to be the cheap path.

Left alone deliberately, for two reasons. Special-casing `UNLIT` inside
`shade_lights` reopens the exact seam this phase closed, and the
seam-preserving alternative -- a per-model "does this integrate lights"
declaration the loop consults -- is a fifth place to touch, bought for a cost
nobody in this environment can measure. There is no GPU capture here, so
"optimize it" would mean guessing, which §8 rules out. Revisit when it can be
measured, or when P6's deferred pipeline restructures this loop anyway.

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
pass resolves it to the swapchain.

**The machinery is less reusable than it first looks.** `render_target.odin`
creates every target in the swapchain's own format, and its doc comment says
why: SDL3 bakes target formats into a pipeline, so a target in another format
needs its own copy of every pipeline that draws into it. A float scene target
is exactly that other format. Three consequences, none optional:

1. **The five pipelines that draw inside the 3D pass get rebuilt against the
   HDR format** -- `mesh`, `mesh_skinned`, `line`, and both skyboxes. The
   format is fixed rather than variable, so this is five more pipelines and
   not a combinatorial explosion.
2. **The HDR target is internal, and `Render_Target` is left alone.** The
   scene target lives on `Renderer.lighting.targets` and is the destination of
   the 3D pass always; the tonemap resolve then writes into
   `current_color_texture()` -- swapchain or a game's own target, both still
   in swapchain format. This matters because `examples/post` draws 3D *into* a
   `Render_Target`, so both destinations are live paths today. Keeping
   `Render_Target` in the swapchain format also keeps every 2D pipeline valid
   inside one, which is the property its own comment exists to protect.
3. **`begin_drawing_3d`'s "load, do not clear" contract changes.** It
   currently loads whatever `clear_background` painted so the background shows
   through. A separate HDR target has nothing to load. The replacement is to
   clear the HDR target to the background colour converted to linear, and have
   the resolve write opaque across the viewport. Anything a game drew in 2D
   *before* its 3D pass would stop showing through -- check whether any example
   relies on that before assuming none does, and document it either way.

Consequence to state plainly: this changes what existing scenes look like.
`set_fog`'s colour is currently mixed *after* gamma, so it means "the colour
you picked". Under HDR that mix moves into linear space before tone mapping,
and a fog colour carried over from PsxGame will not land on the same pixel
value. See §6.

### 3.7.1 What P1 left open, found reviewing it

**Textures are never decoded to linear, and that now shows.** Every texture in
this package is uploaded as `R8G8B8A8_UNORM` (`upload.odin`), so a sampled
texel is the gamma-encoded value the artist authored, and every shader treats
it as if it were linear light.

That was already true before P1 and was half-wrong-but-consistent: albedo went
in encoded, lighting multiplied it, and `pow(1/2.2)` went on at the end. P1
changes the *other* paths, and there it is a visible regression rather than a
wash:

- `skybox_cubemap.frag` / `skybox_panorama.frag` sample a texture and return it
  straight. Before P1 that value went to the swapchain untouched -- encoded in,
  encoded out, a correct round trip. Now it lands in the HDR target and the
  resolve applies `pow(1/2.2)` on top, so **the sky is double-encoded and comes
  out washed out.**
- The same applies to `mesh_line.frag` (wireframes, `draw_grid`) and to any
  material choosing `Shading_Model.UNLIT`, which is also what every material
  becomes when `Lighting_Settings.enabled` is false.

**This blocks P2, not just the picture.** A metallic-roughness BRDF operating
on non-linear albedo is not physically based in any meaningful sense -- the
whole point of the model is that the arithmetic happens in linear light. So
the fix belongs *before* the PBR models land, not after.

The fix is sRGB-aware sampling: upload colour textures as
`R8G8B8A8_UNORM_SRGB` so the hardware decodes on sample, leaving data textures
(metallic-roughness, normal maps, occlusion -- all of which arrive in P2)
on plain `UNORM`, because those carry numbers rather than colours and decoding
them would be actively wrong. That means `upload.odin` needs to be told which
kind it is being handed rather than assuming one format for everything.

**Correction, from building it: the axis is not "colour versus data".** That
framing gets the data textures right and the interesting case wrong. A
sprite's pixels are colour by any definition and must still upload `UNORM` --
the 2D pass writes straight to an SDR swapchain with no resolve step, so a
sprite decoded to linear on sample would stay linear all the way to the screen
and every sprite in every 2D game would render dark. The rule that actually
decides it is **"does something downstream re-encode this exactly once"**,
which is true of the 3D pass (the tonemap resolve does it for the whole scene)
and false of the 2D pass. `Texture_Encoding`'s doc comment in `upload.odin`
carries this; P8 changes the answer for sprites when the 2D pass gains a
resolve of its own.

**`exposure` has no safe zero, and the same trap is waiting for every field
added after it.** P1 added `exposure: f32` to `Lighting_Settings`, whose zero
value multiplies the scene to black. Nine examples built the struct as a
partial composite literal and had to be edited to say `exposure = 1`; any game
doing the same goes black on upgrade, with nothing to point at.

P1 argued for keeping it, on the grounds that auto-defaulting a zero would mean
the value read back out of a struct is not the value that ran. That is a real
concern but the wrong trade, and this package has already made the opposite
call for the identical problem: `Body.tint` (`types.odin`) treats an all-zero
tint as "as it was painted" rather than "transparent black", and its comment
gives the reason -- *a struct that has not been filled in has to draw the
picture and not a hole*. Exposure is stronger still, because zero is never a
legitimate value there, so a sentinel cannot collide with one the way tint's
had to reason about.

The deeper point is that this recurs. Every phase adds fields to
`Lighting_Settings`, `Material` and `Shadow_Settings`, and every one of them
silently changes what an existing partial literal means.

**Settled: zero means the default, and the rule is now in the code.**
`lighting_settings_normalized` (lighting.odin) states it once and is the
place to read it; `shadow_settings_normalized` (shadow.odin) and
`material_normalized` (material.odin) apply it to their own structs. Three
things about it are worth carrying into later phases:

- **It is a per-field judgement, not a sweep.** Zero is replaced only where
  no caller could mean it. `metallic` and `roughness` are named exceptions --
  zero metallic is a dielectric and zero roughness is a mirror, both real
  answers -- and so are `Ambient{}`, `Fog{}` and a `Shadow_Settings` whose
  `enabled` is false. A phase that starts reading a field currently unread
  decides which side it falls on and says so at the field.
- **The sentinel must not collide with a legitimate value**, which is the
  test `Body.tint` already set. A black material is `{0, 0, 0, 1}` and keeps
  its alpha, so it cannot be confused with one nobody filled in.
- **Settings normalize on store; materials normalize at pack time.**
  `Lighting_Settings` and `Shadow_Settings` are Matchbox's own state, so the
  normalized value is what is stored and a read reports what actually runs --
  which answers the "the value read back is not the value that ran" objection
  by removing the divergence rather than accepting it. A `Material` belongs to
  the caller's `Model_Part` and there is nowhere to store a copy they would
  see, so it is normalized in `material_frag_data` on the way to the GPU.

`normalize_test.odin` covers both halves, and the half that matters is the
one where nothing happens: every default is paired with a test that a
deliberate zero survives, because an over-applied rule silently puts a value
somebody meant out of reach.

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

**First, before anything else: §3.7.1's sRGB decode.** A metallic-roughness
BRDF on gamma-encoded albedo is not physically based, so this is a
prerequisite for the models below rather than a tidy-up after them. It also
un-washes the skybox, the grid and every `UNLIT` material, which P1 left
double-encoded.

**Second, before any new model: land §2.1's split contract.** `sample_light`,
`Light_Sample`, `Radiance`, the shared loop in `lighting_core.hlsli`, and
`blinn_phong` rewritten into `brdf_light_blinn_phong` + `brdf_resolve_blinn_phong`
-- with specular becoming coloured, this rework's first deliberate look
change. This is one worker, and it blocks the rest of P2: every model below is
written against the new contract, so writing them first would mean writing
four light loops that then get deleted.

**Third, the models themselves -- and they are not as parallel as they look.**
`pbr_metallic`, `pbr_specgloss`, `toon` and `subsurface` each want their own
`.hlsli`, but all four also edit `shading.odin`'s enum, `contract.hlsli`'s
defines, and both switches in `lighting_core.hlsli`. Four workers on those
same three shared files is four conflicts, not four times the speed. One
worker takes all four; the formulaic part is the part that would have been
parallel anyway.

- `pbr_metallic` (Cook-Torrance GGX + Smith + Schlick)
- `pbr_specgloss`
- `toon`
- `subsurface`

Driven by `Material`'s existing scalar factors, which P0 already added in
full. **Textures are a separate job after it** -- see below -- so this one
needs no loader change, no new texture bindings, and no vertex-format change,
which is what keeps it to one worker and one seam.

**Fourth, and genuinely separate: the loader and the material textures.**
`model_load.odin` reads the full glTF material -- metallic-roughness factors
and textures, normal, occlusion, emissive -- and the renderer binds them.
Disjoint from the models above in everything but timing.

**It carried a problem, and it is settled -- see §7.5.** There are no
tangents: `Vertex3D` is position, normal, uv and nothing else, and nothing in
`model_load.odin` reads glTF's `TANGENT`, so a tangent-space normal map has no
basis to be applied in. The decision is to read metallic-roughness, occlusion
and emissive now -- none of which need a tangent -- and leave normal mapping
to a phase of its own.

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

**Built CPU-side, not compute -- the parenthetical above assumed the wrong
one.** There is no compute-shader path anywhere in this repo --
`build_shaders.bat`/`.sh` compile `*.vert.hlsl`/`*.frag.hlsl` only, nothing
calls `CreateGPUComputePipeline` -- and adding one would mean new build-script
and API surface for the one part of this phase hardest to verify without a
GPU. `light_cull.odin` assigns lights to a 16x9x24 grid on the CPU every
frame `CLUSTERED` is selected, uploaded as two storage buffers
(`cluster_ranges`/`cluster_light_indices`, t11/t12) the same way `set_lights`
already uploads the light list itself. `shade_lights` (lighting_core.hlsli)
branches on `Render_Pipeline_Kind` to loop either the full light list
(FORWARD) or one cluster's own slice (CLUSTERED) -- the only difference
between the two pipelines anywhere in the shader, per this file's own
section 3.6.

**Half the gate could not be run.** No GPU and no capture tooling in this
environment means neither "identical picture" nor a scaling curve is
measurable here -- what stands in for it is CPU-side cluster-assignment
correctness, swept across a whole grid and against hand-derived boundary
cases (`light_cull_test.odin`), plus a bookkeeping check that `cluster_build`'s
own flattened output matches a direct per-light recomputation for a mixed
scene. Both are checked; neither substitutes for actually seeing a frame.

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

**Not yet dispatched. Split recommended, for the reason every earlier split
had: these are three different jobs wearing one heading.** P2 became four
sub-phases and P3 grew a P3b, and in both cases the split was what kept each
piece verifiable. Proposed shape:

- **P7a -- the post chain: bloom and colour grading.** *Built. `post.odin`,
  `bloom.odin`, `shaders/bloom*.hlsl`, `post_test.odin`; the tonemap resolve
  grew a second sampler and the grade. See §7.8 for the two decisions it
  made and the four bugs its own tests found.*

  Pure consumers of the HDR colour buffer, needing no scene data beyond it.
  The real deliverable is the *chain* itself: `draw_post` (render_target.odin)
  applies one effect to a render target, and bloom is inherently multi-pass --
  threshold, downsample, blur, upsample, composite -- so it needs ping-pong
  buffers and an ordered chain that P1's tonemap resolve then ends. That
  architecture is what P7b and anything later reuses, which is why it goes
  first.
- **P7b -- screen-space effects needing scene data: SSAO and volumetrics.**
  *Built. `ssao.odin`, `volumetric.odin`, `shaders/ssao*.hlsl`,
  `shaders/volumetric.frag.hlsl`, and the depth prepass in
  `pipeline_forward.odin`; `ssao_test.odin` and `volumetric_test.odin`. See
  section 7.9 for what the asymmetry turned out to be worth.*

  Both want depth, and SSAO wants normals too. Note the asymmetry worth
  planning around: under `DEFERRED` the G-buffer already has both, while
  `FORWARD` and `CLUSTERED` would need a depth prepass or a normal target to
  supply them. That is the interesting design question of the phase and should
  be stated in its brief rather than discovered.
- **P7c -- reflection probes**, extending P4's `Environment_Probe` from one
  scene-wide bake to localized probes with blending between them. *Built.
  `reflection.odin`, `reflection_test.odin`, and the blend in
  `lighting_core.hlsli`/`brdf/pbr_common.hlsli`. See section 7.10.*

**Baked lightmaps and real-time GI are recommended out of P7 entirely**, on
the same grounds normal mapping left P2 (§7.5): a lightmap baker is an offline
tool, and lightmap UVs are a second UV set, which is a vertex-format change
touching every pipeline's vertex layout -- exactly the class of decision that
deserves its own briefing rather than arriving as a side effect. Real-time GI
is a research-scale feature next to everything else on this list.

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

5. **Normal mapping is its own phase, not part of the material loader.**
   Applying a tangent-space normal map needs a tangent basis, and this package
   has none -- no `TANGENT` read at load, no fourth vertex attribute. The two
   ways to get one are both real changes with real costs: widening `Vertex3D`
   touches every pipeline's vertex layout, and deriving the basis from
   screen-space derivatives is cheap but visibly worse on the low-poly
   geometry this renderer mostly draws. Neither is a decision worth making as
   a side effect of a loader task. So P2's loader job reads
   metallic-roughness, occlusion and emissive -- every map that needs no
   tangent -- and normal mapping gets briefed on its own merits later, with
   the vertex-format question asked out loud.

   `Surface.normal`'s doc comment already says "normal map already applied",
   which is the contract the BRDFs are written against and stays true: today
   nothing applies one, and when something does, no BRDF file changes.

6. **A loaded glTF gets the shading model its own file declares, with a
   loader-level override.** *Implemented after P3b, commit `8f988fe`. One
   refinement made while building it: `KHR_materials_pbrSpecularGlossiness` is
   deliberately **not** detected -- it is archived, its factors live in an
   untyped `json.Value` this package has no typed parse for, and glTF requires
   a file using it to also carry a `pbrMetallicRoughness` block precisely so a
   client without the extension has a correct fallback. Taking that fallback is
   the spec's own designed path rather than a gap. A primitive with no material
   at all also keeps `MATERIAL_DEFAULTS` rather than becoming PBR: that is the
   generated-shape case, and glTF's default material is metallic 1 roughness 1,
   a rough metal nobody wants an untextured primitive to turn into.*

   P2d left `read_material` assigning `MATERIAL_DEFAULTS`' Blinn-Phong to every
   loaded material, reasoning that `lighting_plan.md` says the game picks the
   shading model rather than Matchbox. The reasoning does not hold. A glTF
   material carrying a `pbrMetallicRoughness` block is *declaring* that it is
   metallic-roughness; assigning Blinn-Phong is not declining to choose, it is
   choosing on the game's behalf while discarding what the file said. The
   spec's principle is about not locking a game in, and honouring the file
   locks nothing -- `part.material.shading = .TOON` still works.

   The practical argument is stronger than the principled one: as P2d shipped
   it, the loader reads metallic, roughness, occlusion and emissive into a
   material where **nothing reads any of them**, because Blinn-Phong ignores
   all four. P2d's own report concedes the default path has no visual change
   at all, which is another way of saying the job is inert until a game
   hand-edits every loaded part.

   So:

   - `pbrMetallicRoughness` -> `PBR_METALLIC`
   - `KHR_materials_unlit` -> `UNLIT`
   - `KHR_materials_pbrSpecularGlossiness` (archived, still in the wild) ->
     `PBR_SPECGLOSS`
   - a `load_model` parameter forcing one model for the whole file, for a game
     that wants its old look back in one line rather than per part

   **Why it waits for P3.** P3 is running in the same working tree and on a
   branch off this one. Two actors editing one tree is the collision this
   rework has avoided by sequencing every phase, and there is no urgency here
   that would justify making an exception -- the change touches
   `model_load.odin`, which P3 is explicitly scoped away from, but a shared
   git index is enough of a hazard on its own.

---

## 7.7 P3's sampler count, and the wrong premise under it

**Correction, P7c: 16 is SDL's own hard cap and not only Vulkan's floor.**
Everything below -- and every sampler-count comment in the package -- frames
the number as `maxPerStageDescriptorSampledImages`, a Vulkan guarantee that
desktop drivers exceed and Android sits at. That is true and it is an
understatement. `SDL_CreateGPUShader` checks
`num_samplers > MAX_TEXTURE_SAMPLERS_PER_STAGE` (SDL_sysgpu.h: **16**) and
fires `SDL_assert_release`, which aborts rather than returning an error a
caller can report -- so `create_builtin_shader`'s own panic is never reached,
and a desktop GPU reporting a million sampler slots does not help. Both
numbers being 16 is why the Vulkan framing survived four phases. The rule this
section states is unchanged and firmer than it read.

SDL's siblings, from the same header and asserted the same way: **4** uniform
buffers per stage (which is what crashed P7c -- section 7.10), **8** storage
buffers, **8** storage textures. `tools/check_shader_layout.py` enforces all
four.

**Resolved by P3b.** `cascade_maps[8]`/`cube_maps[6]` are now one
`Texture2DArray` apiece (`mesh.frag.hlsl`, `t6`/`t7`), each layer rendered
into via `GPUDepthStencilTargetInfo.layer` rather than via a texture of its
own (`shadow_cascaded.odin`, `shadow_cube.odin`) -- the mesh fragment shader
is at **8** sampled textures/samplers, `t0`-`t7`, with the light
`StructuredBuffer` following at `t8`. `render_test.odin` pins the actual
value `init.odin` passes `CreateGPUShader` under Vulkan's floor of 16.

One correction to this section's own account, found while building the fix
rather than assumed going in: **`cube_maps[6]` became a `Texture2DArray`, not
a `TextureCube`.** This section suggested either was available with the array
"or" framing above. A real depth-format `TextureCube` may well work -- SDL_GPU
does have `GPUTextureType.CUBE` and nothing in the API forbids
`{.DEPTH_STENCIL_TARGET, .SAMPLER}` on one -- but there is no GPU in this
environment to confirm any backend actually creates one, and the array
sidesteps the question while collapsing the sampler count exactly as much:
`shadow_cube_face_index` already resolves a direction to a face number, so
indexing a `Texture2DArray` by it costs nothing but the hardware
seam-blending a real cube texture would have bought back. Revisit if that
seam ever turns out to matter more than it did when this was first written.

The two caveats below held up: the layer field is real and behaves as
documented in every backend `dxc`/SDL_GPU validation could exercise (compiling
successfully is not the same as rendering, and no frame was rendered to
confirm it), and the six render passes per cube caster are unchanged -- only
the sampling side collapsed.

<details>
<summary>Original write-up, kept for the record</summary>

P3 ships a mesh fragment shader with **20 sampled textures and 20 samplers**
(`t0`-`t19`/`s0`-`s19`, with the light `StructuredBuffer` pushed out to `t20`):
base colour, three material maps, two shadow maps, `cascade_maps[8]`, and
`cube_maps[6]`.

**Vulkan's guaranteed minimum for `maxPerStageDescriptorSampledImages` is 16,
and for `maxPerStageDescriptorSamplers` is also 16.** Desktop drivers report
far higher numbers and will not notice. Devices sitting at or near the spec
floor will fail at shader or pipeline creation -- and Matchbox targets Android
(`android.odin`, `android_apk.bat`), where near-the-floor is ordinary. Nothing
in `odin check` or `dxc` catches this; it is a runtime failure on a device
neither this session nor the phase that wrote it can test.

**The premise that produced those counts is false.** P3 reported, as its
headline finding, that "SDL_GPU cannot render into a specific face/layer of a
depth-stencil target -- `GPUDepthStencilTargetInfo` has no
`layer_or_depth_plane` field, unlike `GPUColorTargetInfo`", and built six
separate `D2` depth textures per cube caster and eight separate cascade
textures on that basis.

`GPUDepthStencilTargetInfo` does have the field. It is spelled `layer`:

	layer: Uint8,  /**< The layer index to use as the depth stencil target. */

-- `vendor/sdl3/sdl3_gpu.odin`, in the same struct, two fields from the end.
The search was for the colour target's spelling (`layer_or_depth_plane`), and
its absence was read as the capability's absence.

So the array-and-cube approach the phase ruled out is available:
`cascade_maps[8]` becomes one `Texture2DArray` (1 sampler), `cube_maps[6]`
becomes one `TextureCube` or one array (1 sampler), and the shader drops from
20 sampled textures to **8**, comfortably under the floor.

Two honest caveats. The API affording a layer is not proof every SDL backend
honours it for depth targets, and that cannot be verified here either -- but
"the API does not offer this" and "the API offers this and a backend may be
weak" are different claims, and only the second one is true. And rendering
each cube face into a real cube texture still needs the six passes it needs
now; what changes is how the result is *sampled*, which is where the sampler
budget is actually spent.

</details>

---

## 7.8 P7a's two decisions, and what the tests found

**The chain does not hold every stage, and that is the design.** The obvious
reading of "post chain" -- an ordered list of effects, each its own pass, each
reading the last one's output through a ping-pong pair -- is the wrong shape
here. `post.odin` states the rule it went with instead: *a stage that needs a
pass gets one; a stage that is a per-pixel function of one texel does not.*
Bloom needs passes, because a kernel cannot see a neighbour's finished value
from inside the draw that produces its own. Colour grading does not, and a
ping-pong pair of full-screen `RGBA16_FLOAT` buffers to run it in would have
bought a texture, a pass and a round trip through memory in exchange for
nothing. So grading lives inside the resolve, alongside the exposure and the
curve that were already there.

Which is also why `exposure` and `tonemap` did not move onto `Post_Settings`
beside `bloom` and `grade`: they are two parameters of the resolve stage, not
stages of their own. Moving them would also have silently changed what every
`Lighting_Settings{... exposure = 1 ...}` literal in the repo meant, for a
tidier-looking struct and no behaviour.

**Zero-means-default has a second answer, and it is the better one where it
is available.** §3.7.1 settled that rule and warned that every phase adding
fields to these structs re-opens it. `Color_Grade` is the case where the
sentinel does not work: zero saturation (greyscale) and zero contrast (flat)
are both values somebody legitimately means, so a sentinel would collide with
one, which is the test §3.7.1 sets for itself. The way out was to spell every
field as a *delta from identity* -- `saturation = 0` leaves it alone,
`saturation = -1` is greyscale -- which makes `Color_Grade{}` an exact no-op
and needs no normalization entry at all. Prefer that shape whenever a field
admits it; a normalization entry is what you write when it does not.
`Bloom.intensity` is one that does not, and it carries the wart to prove it:
a game animating intensity to exactly zero snaps back to the default.

**Four bugs, all found by the tests, none of them visible without a GPU.**
Worth listing because three are the same *kind* of bug -- an identity that is
only nearly an identity -- and that kind is invisible to `odin check`, to
`dxc`, and to looking at a frame.

1. **The upsample summed levels instead of mixing them.** Both filter kernels
   sum to 1, so every level of the chain holds the same total light as the
   level below it; summing `n` of them into level 0 puts `n` copies of the
   scene's bright light there. A flat bright wall blooms half again as bright
   from a 6-level chain as from a 4-level one, and `intensity` stops meaning
   anything fixed. Fixed with a `scatter` mix weight written into the
   upsample's own alpha, which the ordinary source-alpha blend then applies --
   so `levels` controls how wide the bloom is, `intensity` how strong, and
   neither moves the other. It also took `Color_Blend.ADDITIVE` back out
   again: the upsample was its only caller and it turned out to want the blend
   that already existed.
2. **`pow(x, 1)` is not `x`.** It is `exp2(log2(x))` on both sides of the
   CPU/HLSL mirror, and 0.001 comes back as 0.0009999871. Never visible, and
   it made `Color_Grade`'s central claim untestable. The gamma step is skipped
   on a uniform branch when the delta is zero.
3. **`(c - 0.5) * (1 + contrast) + 0.5` cancels the same way**, and so does
   `lerp(luma, c, 1 + saturation)`. Both are written as deltas now --
   `c + (c - 0.5) * contrast` -- which is the identical arithmetic, the same
   single multiply-add, and exactly zero when the field is zero.
4. **A disabled `Bloom` grew four defaults nothing would read**, so `Bloom{}`
   was not a fixed point of normalization and `LIGHTING_DEFAULTS` could not be
   read off its own constant. `shadow_settings_normalized`'s own first line was
   already the answer.

**What was verified, and what was not.** Grading and the bloom knee are
checked in full against numbers derived independently in Python; the kernels
are checked for the one property everything downstream rests on -- that a
constant image survives the chain unchanged; the level sizing is swept across
1200 resolutions for its invariants rather than checked at three sizes. **No
frame was rendered.** Nothing confirms that bloom looks like bloom, that the
`scatter` alpha blend behaves as reasoned on any backend, or that
`BLOOM_DEFAULTS`' threshold of 1 shows anything in a scene as dark as
`examples/lighting` -- which is why that example's own B key steps through two
different tunings rather than toggling one.

**Deliberately not built**, each needing a frame to tune against: the Karis
luminance average inside the downsample (so a lone bright pixel can still
flicker as it moves), a lens dirt mask, and per-level weighting.

---

## 7.9 P7b, and the question the brief asked

**The asymmetry was real, and it was only half the phase.** Section 5 warned
that `DEFERRED` has depth and normals before it shades while `FORWARD` and
`CLUSTERED` do not, and asked that the phase confront it rather than discover
it. What building it settled is that the warning applied to *one* of the two
effects, and the two are otherwise not alike at all:

- **SSAO needs depth before shading**, because what it produces is a value for
  `Surface.occlusion` and occlusion multiplies the ambient term. Under
  `DEFERRED` the AO pass slots between the G-buffer fill and the lighting pass
  and costs one fullscreen pass. Under the forward family it costs a **depth
  prepass** -- the geometry drawn a second time with a fragment shader that
  writes nothing.
- **Volumetric light needs depth after shading**, because it *adds* light
  rather than modulating it. All three pipelines write depth by then, so it is
  pipeline-agnostic with nothing to design around, and `FORWARD` pays nothing
  extra for it.

So the answer to "depth prepass or normal target" is *neither, for half of
it*. A normal target was never built: SSAO reconstructs normals from depth
(`reconstruct_normal`, ssao.frag.hlsl), which costs accuracy at silhouettes
and buys one code path across three pipelines rather than a branch on which
pipeline drew the frame -- the property `lighting_plan.md` asks of every
module.

**What the prepass costs an immediate-mode API, which is the part worth
carrying forward.** A prepass has to draw every model in the frame before the
frame has said what its models are. So under the forward family with SSAO on,
`draw_model` and `draw_skybox` stop drawing and start queueing
(`Renderer.scene_deferred`), and `end_drawing_3d` replays the queue twice.
That is not a new mechanism -- P6 already queued the skybox and every
transparent part for a replay into a later pass -- but it is the first time
the *whole* frame goes through it, and it forced both procedures to grow a
branch **ahead of** their own "no pass is open" guards. With the scene
deferred there genuinely is no pass, and a guard written to catch a stray draw
would otherwise have silently eaten every model in the scene.

It is worth knowing that every 3D draw in this package funnels through those
two procedures -- `draw_cube`, `draw_sphere`, `draw_grid`, `draw_bounds_wires`
and the rest all call `draw_model` -- which is what made this tractable at
all. A single drawing path that bypassed them would have gone missing from
every AO frame with nothing to point at.

**`Surface` held a third time.** Both pipelines apply occlusion in one place:
`shade_surface` (lighting_core.hlsli) multiplies the AO sample into
`surface.occlusion` before the model dispatch. One line, one file, three
pipelines, every shading model. P4 tested that seam with a light kind it was
not designed for; P6 tested it with a pipeline; this tests it with a screen-
space input that is neither.

**And the light contract held a third time too, further out than P4 went.**
`volumetric.frag.hlsl` calls `sample_light` for a point in *mid-air* -- no
surface, no BRDF, nothing to shade -- and gets back a light's kind, its
attenuation, a spot's cone and its `shadow_visibility` lookup already folded
into one radiance. Shafts through a window are shadow maps seen edge-on, and
they cost one function call because that function was written for somebody
else. The `Surface` handed over is a stand-in with two load-bearing fields:
`position`, and a **zero** `normal` -- there is no surface, so there is no
normal to offset the shadow lookup along, and `Shadow_Bias.normal_offset`
multiplies by exactly that vector.

**Register renumbering, again, and this is the third phase it has bitten.**
The AO texture is declared in `lighting_core.hlsli` at a parametrized register
so that the one place which reads it serves both including shaders -- which
pushes all three storage buffers behind it up by one in each.
`MESH_FRAG_SAMPLER_COUNT` 10 -> 11, `DEFERRED_LIGHTING_SAMPLER_COUNT` 11 -> 12,
and `VOLUMETRIC_SAMPLER_COUNT` is 8. Both existing pins failed and were
consciously updated, which is what they are for.

**Those three counts were verified against the compiler rather than against
arithmetic**, which is a check this rework had not run before and should run
again whenever a sampler moves. Preprocessing each shader (`dxc -P`) and
counting the `register(tN, space2)` declarations that survive macro expansion
gives 11 samplers + 3 storage buffers for `mesh.frag`, 12 + 3 for
`deferred_lighting.frag`, 8 + 3 for `volumetric.frag`, and 4 + 0 for
`gbuffer.frag` -- each matching its constant, and each showing the storage
buffers landing exactly where the `LIGHTS_T` defines say. That is the actual
invariant; the pins only catch a *change*.

**One change to a resource every 3D game already had.** `pick_depth_format`
now requires `{.DEPTH_STENCIL_TARGET, .SAMPLER}` and the depth texture carries
the extra usage flag. P6 deliberately gave `DEFERRED` its own sampled depth
rather than widening this one, on the grounds that no forward game should pay
for a deferred-only feature; that reasoning does not survive a feature every
pipeline offers, and the alternative would have had to replace this texture
anyway, since SDL3 bakes a pipeline's depth format in at creation. The pass
still stores depth only when something is going to read it
(`scene_depth_is_read`), which keeps the tiler cost off a game using neither
effect.

**One bug found by reading rather than by running.** When the depth prepass
failed to open its pass, the scene pass still loaded depth -- handing it the
previous frame's contents, so every fragment would test against stale
geometry. A scene with holes punched through it, not an obvious failure.
`load_depth` follows whether the prepass actually ran now.

**Recorded, not fixed: `cluster_camera.xy` has been wrong since P5** for a
game that draws 3D into a differently-sized `Render_Target` -- it carries the
window's size where the pass's is wanted. P7b needed the correct value and
added it as `Scene_Frag_Data.screen_size` rather than repointing the old
field, because fixing that one means also checking `cluster_build`'s own
CPU-side use of the same two numbers (light_cull.odin), and that is P5's
territory rather than this phase's.

**What was verified and what was not.** The SSAO sample kernel is checked in
full -- every tap on the lit side of the surface, none longer than the unit
hemisphere, lengths rising toward the rim, directions spreading rather than
lining up -- across every sample count the settings allow, against a Python
derivation whose bit-reversal is re-derived the slow way rather than with the
same five-shift trick the implementation uses. Henyey-Greenstein is checked by
numerically integrating it over the sphere at seven anisotropies, which is the
property that *fixes* its `1/(4*pi)` rather than merely being consistent with
it, plus the sign of the anisotropy as an ordering, since a flipped sense
would pass every other test and put every shaft in the wrong half of the
screen. Beer-Lambert is checked at `1/e` and by its multiplicative property,
which a linear falloff would fail while passing the endpoints.

**Everything else is in the shaders and needs a GPU.** No frame was rendered.
Nothing confirms that the AO reads as contact shadow rather than as grime,
that the normal reconstruction holds up at silhouettes, that the raymarch's
step count is enough to hide its banding under the dither, or that either
effect's default numbers suit a scene at the scale `examples/lighting` is
built at.

**Deliberately not built**, each wanting a frame to tune against: a bilateral
(depth-aware) SSAO blur, half-resolution AO and volumetrics with a
depth-aware upsample, a G-buffer normal path for `DEFERRED`, and the second
half of the volumetric absorption -- light is attenuated on its way to the eye
but not on its way in, which needs a second march per light per step.

---

## 7.10 P7c, and the first frame anybody looked at

**Localized probes, captured from the scene.** P4 baked one probe from a
skybox and every surface everywhere sampled it. P7c places up to four, each
with a position and a radius, blended per fragment by how far inside each
one's influence it sits -- and where the weights do not add to 1, the
remainder falls back to P4's scene-wide probe. So "probes where you placed
them, sky everywhere else" is the default rather than something a game has to
arrange, and a scene that places none gets exactly the picture P4 shipped,
which is why no existing example changed.

**Captured rather than baked from a sky, which is the part that makes them
worth having.** Probes baked from the same skybox are identical, and blending
identical probes is a no-op. So a probe renders the room from its own position
-- six faces at ninety degrees -- and the existing convolution shaders turn
that into the same irradiance/prefiltered pair. The game drives it, because
CLAUDE.md rules out handing a game's procedure back to it:
`begin_probe_capture`/`end_probe_capture` per face, then
`bake_reflection_probe`. That is `begin_shadow_pass`/`end_shadow_pass`'s exact
shape -- the framework owns the pass, the target and the camera; the game owns
what goes in it.

**One pair of arrays for every probe, not a pair each.** `probe * 6 + face`,
and `probe * 6 * levels + level * 6 + face`. Four probes cost the same two
samplers one does, where a texture pair per probe would have hit Vulkan's
floor of 16 at the third. The cost of that is arithmetic existing twice -- once
in Odin at bake time, once in HLSL at read time -- so it is named once on the
Odin side (`reflection_probe_layer`) and swept for uniqueness and range across
every probe, level and face rather than trusted. A collision there does not
fail; probe 2 quietly reflects probe 1.

**The sampler budget is now the thing to watch.** mesh 13, deferred **14**,
volumetric 10, against a floor of 16. That is the least headroom this package
has ever had, and it is said out loud beside `MESH_FRAG_SAMPLER_COUNT` rather
than left to be discovered. What a feature wanting the next slot should do is
what these two arrays already did: share one array with something already
bound rather than taking a slot of its own. Section 7.7's rule stands -- past
16 is a stop-and-ask.

All four shaders' counts and register layouts were verified against the
preprocessor, the check §7.9 introduced: 13+3, 14+3, 10+3, 4+0, with every
storage buffer landing where its `LIGHTS_T` define says.

**One bug, found writing the example rather than running it.**
`bake_reflection_probe` acquired its own command buffer and submitted it
immediately, while the capture it reads had been recorded into the *frame's*
buffer and not yet submitted -- so the bake was free to run first and convolve
whatever was in the texture beforehand. It records into the frame's buffer
when there is a frame now. This is the class of hazard that has no CPU-side
test: both orderings compile, and only one of them is a probe.

### The first frame anybody looked at

**The owner ran `examples/lighting-lab`.** Nothing in this rework had been
rendered before that, across P0 to P7c. Three things came back, and all three
were real:

1. **`A` was strafe-left.** Ambient cycled every time you sidestepped -- the
   scene relighting itself while you walked. The mistake was picking mnemonic
   letters before checking what `first_person_walk` reads. Moved to `K`.
2. **"Everything is white."** Two causes at once, and worth separating.
   Every structural surface was a near-neutral grey, deliberately, so the
   sphere row would be the only interesting material in the room -- and a
   near-neutral grey under a full-strength sun through ACES is white. The sun
   was also at 1.0 with a spot and a point light on top, which drives
   everything past the top of the curve, where every colour is the same
   colour. Fixed with saturated materials and a dimmer rig, and **exposure put
   on a key**, because "the materials are not reaching the shader" and "the
   scene is blown out" produce the same white picture and there was no way to
   tell them apart from inside the example.
3. **Fog looked broken and was not.** Its range (8 to 34) was wider than the
   room -- the back wall sits 17 units from the start position, so it was
   barely a third fogged, and the only thing visibly affected was the far
   corners of the 40-unit floor. Which is exactly what was reported. 3 to 22
   puts the whole room inside the ramp.

None of the three is a bug in the lighting engine. All three are the example
failing to *show* the engine, which is the only job it has -- and none of them
was findable without a screen. That is the strongest argument in this document
for the note now at the top of the handover: **run the lab before starting
anything else.**

A fourth, found while fixing those: the PBR sweep was fully metallic, and a
metal has no diffuse term at all. With no environment probe bound it reflects
the handful of lights and nothing else, and renders nearly black -- correct,
and a terrible default view. It is dielectric now, with the metal case one
keypress away behind the probes. That dependency is worth meeting once: it is
the most common reason PBR "looks wrong" in a renderer that is working.

**Still not verified.** No probe has been seen to capture anything, nothing
confirms a backend honours `layer_or_depth_plane` for a cube face (the one
unverifiable assumption here), and there is no parallax correction, so a
reflection is addressed as though the captured room were infinitely far away.

### The crash, and the four-phase-old bug under it

**P7c as first written did not start.** It put the probe block at `b4` -- the
fifth fragment uniform buffer -- and SDL allows four per stage. Nothing in the
package had ever exceeded four, and the three shaders that sat at exactly four
sat there for a reason nobody had written down.

**Confirmed against SDL's own source rather than inferred**, which is worth
the sentence because the first diagnosis was inference (the crash appeared
exactly when the fifth arrived) and inference is what section 8 exists to
distrust. `SDL_CreateGPUShader` (SDL_gpu.c) reads:

	if (createinfo->num_uniform_buffers > MAX_UNIFORM_BUFFERS_PER_STAGE) {
	    SDL_assert_release(!"Shader uniform buffer count cannot be higher than 4!");
	    return NULL;
	}

`SDL_assert_release` aborts. So this never reached `create_builtin_shader`'s
own panic or its log line, which is why the report was "crashes on startup"
with nothing to quote -- and is worth remembering when reading the next one.
The same function asserts the sampler cap, the storage-buffer cap and the
storage-texture cap identically; section 7.7 now carries the correction that
follows from it.

The fix freed a slot rather than finding one: `CASCADED`'s cascades and
`CUBE`'s six faces were a cbuffer each at b2 and b3, and `push_lighting`
pushed **both every frame regardless of which technique was running**. They
are one block now, which is the same bytes in one push rather than two, and
probes moved to b3. The `Scene`-splitting argument that produced two blocks in
P3 is untouched: it was about not making a PCF scene push cascade matrices,
and neither half of this was ever in `Scene`.

**And merging them turned up something worse.**
`shaders/shadow/cascaded.hlsli` has declared `camera_forward` in that cbuffer
**since P3** and read it for cascade selection ever since. No field on the
Odin side ever backed it. The shader was reading sixteen bytes past the end of
what was pushed, so `CASCADED` has been choosing its cascade from undefined
memory for four phases -- which looks like cascades selected at random
distances rather than like a failure, and so was never noticed.

Nothing in this package could have caught it, and that is the part worth
carrying forward. `init` asserts `size_of(Cascade_Frag_Data) == 544` against a
literal, and **a literal cannot notice a field the shader has and the struct
does not.** Every check here was one-sided: the Odin struct against a number,
the sampler count against a pin. The two declarations were only ever compared
by eye, across a language boundary, in files that are read separately.

`tools/check_shader_layout.py` is the answer to that. It preprocesses every
shader, computes each cbuffer's size from the expanded declaration under HLSL's
own packing rules, and requires that size to match one of `init.odin`'s
asserts -- so a member on one side and not the other moves the number and is
reported. It also enforces the four-uniform-buffer limit, the sampler floor,
and the storage-buffer register sequence. Both of this phase's bugs would have
been caught by it before the program ran; run it after touching any shader.

### The second frame anybody looked at

The lab started, and the first thing in it was a **fine diagonal weave over
every lit surface** whenever SSAO was on. Two bugs, both measurable from a
machine with no GPU once there was a picture pointing at them.

**The sample kernel was a spiral.** `phi` came from `i/n` and the radius from
`0.1 + 0.9*(i/n)^2` -- both driven by the index, so a tap's angle around the
normal and its distance from it rose together. Measured correlation: **0.965**.

Every pixel rotates the whole tap set by its own angle before sampling, and
when the set is a rigid spiral the occlusion it measures is a strong smooth
function of that rotation -- so whatever structure the rotation has prints
straight through at full contrast. `interleaved_gradient_noise` has a great
deal of structure: a fine diagonal weave. The picture was showing the noise
function. The radius comes off a third independent low-discrepancy coordinate
now (Halton base 3), which drops the correlation under 0.25.

**And a test was holding it in place.**
`test_ssao_kernel_lengths_grow_toward_the_rim` required a tap's length to rise
monotonically with its index -- which, since the index also drives the
azimuth, *is* the statement "the kernel is a spiral". It passed for two phases
and pinned the defect. This is a new entry on §8's list of anti-patterns and
the least comfortable one: not asserting on source text, not copying the
implementation's output, not spot-checking -- and now, **a test can pin a
defect as firmly as a property, and a passing suite is not evidence the shape
is right.** What replaced it says what was actually wanted: azimuth and radius
independent, and the length *distribution* still leaning toward the origin.

**The second bug was in the terminal beside the screenshot**, which is worth
noting on its own -- the report was about shading, and the console visible at
the edge of the image had a column of repeated warnings in it.
`Shadow_State.warned` was a single latch guarding the "nothing to render"
message for `begin_shadow_pass`, `begin_cascade_shadow_pass` and
`begin_point_shadow_pass` alike. Every frame `begin_drawing_3d` runs the
map-based pass and then six cube faces; with a directional caster and no point
caster, the first cleared the latch and the second re-armed and fired it. The
mechanism built to turn one-per-frame into one-per-stretch was producing one
per frame. One latch each now.

That generalises past shadows: **a latch shared by several independent
conditions is re-armed by whichever of them is doing fine**, so the one that
is not reports continuously. It stayed hidden because no example combined
`casts_shadow` on a directional light with an unlit point light until the lab
did.

**Also from this round, and not a bug:** the SSAO bias now scales with view
depth (one depth texel covers more world space further away, so a position
reconstructed from it is proportionally less exact -- a fixed bias tuned up
close leaves a grazing surface self-occluding at distance), and the lab has
`1/2` and `3/4` on SSAO's radius and bias with the numbers on screen. Those
two genuinely cannot be chosen from here: `radius` is in world units so it
depends on the scale a scene is built at, and `bias` depends on the depth
format the device handed back.

### The third frame, and the bug the other two were standing on

The weave was gone and the picture was worse: every surface pale, a red box
rendered pink, a floor rendered lavender, and SSAO doing something that read
as a grey smudge rather than as contact shading.

**Both PBR models were adding ambient light instead of reflecting it.**

	// brdf_resolve_pbr_metallic, through P7c
	return total.diffuse + total.specular + surface.emissive +
	    (ambient_light(surface) + ambient_specular) * surface.occlusion;

`ambient_light` is irradiance *arriving*. What a surface sends back is that
times its own albedo. Added raw, it lays the ambient colour over every pixel
whatever the pixel is made of -- so with `HEMISPHERE` and a pale blue sky,
every material washes toward pale blue and **a black surface comes out pale
blue**, which is the form of it that admits no argument.

**And it is why SSAO looked broken twice.** Occlusion multiplies the ambient
term. With ambient a large flat addition rather than a modulation of the
surface, AO darkened a uniform wash laid over the picture instead of shading
anything -- and it gave the spiral kernel (above) maximum contrast to print
itself into, which is why that artifact was as stark as it was. Two rounds of
looking at SSAO were looking at the wrong module.

**Why it survived two phases, which is worth more than the bug.** Three of the
five models did it correctly: `blinn_phong`, `toon` and `subsurface` all
multiply by `base_color`. The two that did not are exactly the two with no CPU
mirror. `pbr_test.odin` sweeps a white furnace through
`brdf_light_pbr_metallic` -- the per-light half, which was right --
and `brdf_test.odin` mirrors `brdf_resolve_blinn_phong`, a different model's
resolve. **No test ever reached either PBR resolve.**

So the rule this adds to §8 is not "test the resolve". It is: **where there is
no mirror there is no check, and the phases that build a mirror for one half
of a contract should say which half is left.** P2's split contract
(`brdf_light` / `brdf_resolve`) was tested thoroughly on one side and not at
all on the other, and nothing in the plan noticed that the gate it named
covered half of what it had built.

`brdf_test.odin` now checks a *property* across every model rather than one
model's arithmetic: a black surface reflects no ambient, the response is
proportional to albedo, and a metal has no diffuse ambient at all.

**Also reverted this round: P7c's depth-scaled SSAO bias.** The reasoning was
sound -- a depth texel covers more world space further away, so the
reconstruction is proportionally less exact -- and the constant was not: at the
default radius and a scene ten units deep it made the effective bias
comparable to the whole sampling hemisphere, and almost no tap could clear it.
It removed the effect rather than cleaning it up. That was a fix aimed at an
artifact nobody could see from the machine it was written on, which is exactly
what §8 exists to rule out, and it is recorded here rather than quietly
dropped.

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
