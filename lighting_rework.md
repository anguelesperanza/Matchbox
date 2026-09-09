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
every review: *adding a sixth shading model must touch only its own file, one
enum value, and one line in each dispatcher* -- three places under P0's single
dispatcher, four once §2.1's split contract lands. If it touches shared code
anywhere else, the seam is in the wrong place.

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
- **One wrinkle in the port.** P0 accumulates specular *uncoloured* (`spec *
  attenuation * shadow`) while diffuse carries the light's colour. Folding
  colour into `radiance` means specular would have to divide it back out to
  stay constant-for-constant. Since §7.4 has already released the old look,
  the right move is to let specular be coloured -- physically correct, and it
  deletes the awkward line. **This is a deliberate look change to
  `blinn_phong`, and the first one this rework makes.**

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

Then one worker per model, each writing one `.hlsli`, two enum-adjacent
one-line dispatcher edits, one test. They do not share files beyond those
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
