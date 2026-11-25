# Plan: G2 lighting, and the 3DS's fragment lighting unit

Written 2026-11-23, before any G2 code, at the user's request. **A plan, not a record of work.** Decisions the user has
made are marked *decided*; open ones are at the end. Facts about the PICA200 that this plan rests on but nobody has
measured here yet are marked *to confirm* and are checked in L0, on hardware, before anything is built on them.

## What was decided (2026-11-23)

- *Decided:* **both** per-vertex and per-pixel lighting, on **all three** targets.
- *Decided:* per-pixel on the 3DS uses its **fixed-function fragment lighting unit** (citro3d's `C3D_LightEnv`), not
  per-vertex as the old G2 text said. The user wants this route because the same unit and its neighbours open more:
  procedural textures, advanced environment mapping, lighter vertex work, and stereoscopic 3D if Matchbox adds it.
- *Decided:* the API ports main's names, trimmed to G2: `Light`, `create_directional_light(direction, color)`,
  `set_lights([]Light)`, and `set_lighting(Lighting_Settings)` for the ambient colour.
- *Decided (later the same day), the open questions:*
  1. A game picks per-vertex or per-pixel **per model part**, defaulting from a global setting in `Lighting_Settings`.
  2. **8 lights to start, as a per-target limit that is easy to change.** The 3DS is the weakest target and sets the
     floor every target supports, but Matchbox also makes PC-only and Vita-only games, so PC and the Vita may take
     more once measured. The limit lives in one place per target (an array size, which CLAUDE.md allows as a
     constant), the shader language reads it from there, and a game can ask for it (`get_max_lights`).
  3. **Specular in G2**, with diffuse and ambient.
  4. The built-ins (`light_diffuse` / `light_specular`, first planned as one `light_surface`) and the `.LIGHTS` uniform block **as recommended**: the block is
     engine-defined and a game's own shader may declare it, so custom shaders are lit by the same `set_lights`. The user
     hasn't done lighting before; the shape is revisited once L3 shows how it fits.
  5. **Directional first, then point and spot lights** under main's names (`create_point_light`, `create_spot_light`).
- *Decided:* after the G2 lighting core, Matchbox **will do** normal and bump maps, environment mapping, procedural
  textures and fog (see "What the same unit opens"). **Stereoscopic 3D is deferred:** the user isn't sure it is wanted.

## Why the 3DS needs its own plan

On PC and the Vita a fragment shader is a program: per-pixel lighting is code in `mesh.mbs`, and mbsc writes it as
HLSL or Cg. The 3DS has no fragment program (`docs/shader_pica.md`, "The fragment stage"). mbsc already turns a
fragment shader into TexEnv stages, but lighting is a different block of fixed hardware that feeds the TexEnv:

```
vertex shader (mbsc PICA) --position, color, texcoord0..2, normalquat, view--> rasteriser
   --> fragment lighting unit (C3D_LightEnv: up to 8 lights, lookup tables)
         gives FRAGMENT_PRIMARY_COLOR (ambient + diffuse) and FRAGMENT_SECONDARY_COLOR (specular)
   --> TexEnv stages (mbsc's .tev plan): combine them with textures and the vertex colour
   --> alpha test, fog, blending
```

So per-pixel lighting on the 3DS needs four things nothing in Matchbox does yet:
1. the vertex shader writing the two outputs the unit reads, `normalquat` and `view`;
2. the TexEnv plan naming the unit's two results as sources;
3. a description of the light setup (which tables, which inputs, Fresnel, clamping) that the runtime applies;
4. the runtime filling `C3D_LightEnv` / `C3D_Light` from `set_lights` and `set_lighting` each frame.

o3dx already binds all of it (`matchbox/o3dx/c3d/base.odin`): `C3D_LightEnvInit/Bind/Material/Lut/Fresnel/BumpMode/
ClampHighlights`, `C3D_LightInit/Enable/Position/Color/TwoSideDiffuse/SpotLut/DistAttn`, `LightLut_Phong`,
`LightLut_FromFunc`, `LightLutDA_Quadratic`, fog, gas, procedural textures (`C3D_ProcTex*`) and cube textures
(`C3D_TexInitWithParams`), with the float-taking calls bridged.

## How the unit works (what the plan builds on)

- **Lights:** up to 8 (*to confirm*: 8 on the New 3DS LL), each with ambient, diffuse and two specular colours, and a
  position or a direction (w = 0), given in **eye space**: the runtime transforms each light by the camera's view.
- **Lookup tables, not formulas.** Distribution (D0, D1), Fresnel (FR), reflection (RR, RG, RB), spot (SP) and
  distance attenuation (DA) are each a 256-entry table indexed by a dot product (N.H, V.H, N.V, L.N, ...). Blinn-Phong
  is "D0 = x^shininess, indexed by N.H" (`LightLut_Phong`). Tables are uploaded to the GPU, so changing one has a cost:
  build them once and switch rarely.
- **The normal arrives as a quaternion** (`normalquat`), the rotation that takes +Z to the surface normal, written per
  vertex and interpolated. That is also what makes bump mapping possible: a normal map from a texture rotates it.
- **The view vector** (`view`) is the vertex's eye-space position negated, also interpolated.
- **Two results:** primary (emission + ambient + diffuse) and secondary (specular), each a TexEnv source.
- **Precision:** 8-bit colours out of the unit, table entries quantised. The PC and Vita reproduce the model, not the
  bits, so the three targets match closely, not exactly; the tests say how closely.

## The shared shape: one lighting model, written once in `mesh.mbs`

Per-pixel lighting is a **built-in of the shader language**, not engine code, so `mesh.mbs` stays the one place the
look is defined (Phase S's rule: one shader, three targets, a compile error rather than a silent difference).

- Two built-ins, `light_diffuse(quat, view)` and `light_specular(quat, view)`, each `-> [4]f32`, read the engine's
  light uniforms (a new `.LIGHTS` uniform block mbsc knows the layout of). The plan first named one,
  `light_surface`, returning both; the language has no multiple returns, so it became two (L2). Their arguments are
  the `normalquat` and `view` varyings, unchanged (MBS-E20 otherwise): on the 3DS the unit reads those outputs
  directly, so a value computed from them in the fragment stage could not reach it.
  - **PC and Vita:** mbsc writes it as code: for each enabled light, Lambert diffuse plus Blinn-Phong specular, plus
    ambient. The specular power and the 8-bit clamping are chosen to follow what the 3DS's tables give.
  - **3DS:** mbsc writes no code for it. The vertex program gets the `normalquat` and `view` outputs; the `.tev` plan
    gets a `lighting` section and the two results become the sources `FRAGMENT_PRIMARY_COLOR` and
    `FRAGMENT_SECONDARY_COLOR`. Anything the unit can't do is an MBS-E error naming the line, as the TexEnv plan does.
- **Per-vertex lighting** is the same model written as ordinary vertex-shader code (`dot`, `max`, `pow`), which mbsc
  already compiles for all three targets; its result is the vertex colour, so on the 3DS it is `PRIMARY_COLOR`.
- One model for both paths, so a game switching between them changes smoothness, not colours.

## Steps

Each step has a done-when, and the hardware rule from today stands: anything that changes what the PICA is asked to
do gets a hardware test build with its own name, stepping one feature at a time (`docs/shader_pica.md`).

**L0. Spike on hardware, by hand.** A throwaway test, like `gpu_test5`: a hand-written picasso shader writing
`position`, `normalquat`, `view`, `color`, `texcoord0` (every register whole), one directional light set with citro3d
calls, TexEnv `FRAGMENT_PRIMARY_COLOR * TEXTURE0 + FRAGMENT_SECONDARY_COLOR`. Steps add one feature each: the unit on
with no light, one light diffuse only, specular through D0, a second light, a texture.
- Settles the *to confirm* items: the normalquat formula and its degenerate case (a normal pointing straight away
  from +Z), the light count, the eye-space convention, what Azahar gets right, and what a table upload costs.
- Done when: a lit, textured cube looks right on the New 3DS LL and in Azahar, and the findings are written into
  `docs/shader_pica.md`.
- **DONE 2026-11-24.** `light_test1` ran all eight steps on the New 3DS LL (the user) and in Azahar, which lit the
  faces as expected. Findings are in `docs/shader_pica.md`, "Fragment lighting (L0)". Settled: the normalquat formula
  and its degenerate case, eye-space light directions, that the unit's two results work as TexEnv sources with a
  texture, and that unbinding the environment lets the engine's own draws through. Not settled, left to later steps:
  the light count (two lights were used, not eight) and the cost of uploading a table (measured in L4).

**L1. mbsc, PICA outputs.** Output tags `normalquat` and `view`, and a built-in that makes the quaternion from a
normal (the formula from L0). Both written whole. Done when: assembled with picasso, checked against the IR
interpreter, and L0's hand-written shader can be replaced by a generated one with the same result on hardware.
- **DONE 2026-11-24:** `light_test2` passed on the New 3DS LL (the user). The tags were already allowed; mbsc now type-checks them
  (`normalquat` `[4]f32`, `view` `[3]f32`, MBS-E15), accepts the vertex attribute `normal`, and has the built-in
  `normal_quaternion(n)` on all three targets (a helper function in HLSL and Cg, L0's instruction sequence on the
  PICA). The built-in tests compile it with the real HLSL compiler, psp2cgc and picasso, and check the PICA program
  against the IR interpreter on random inputs. `light_test2` is `light_test1` with its shader written in the
  language (`light2.mbs`) and generated: the same eight steps pass in Azahar.

**L2. mbsc, the `.tev` plan. DONE (2026-11-24, tests only; nothing new drawn yet).** Sources `FRAGMENT_PRIMARY_COLOR` / `FRAGMENT_SECONDARY_COLOR`, and a `lighting` section
(`mbs-tev` version 2): tables and their inputs, Fresnel, highlight clamping, two-sided diffuse. `shader_tev.odin` reads
it. Done when: golden-plan tests in `tev_test.odin`, and the runtime reads it.
  - What landed: `light_diffuse` and `light_specular` (fragment only), the sources `FRAGMENT_PRIMARY` /
    `FRAGMENT_SECONDARY` (citro3d's names, not the `_COLOR` spelling above), and the lines below, written whenever a
    shader calls either built-in. Only the values L0 measured are written or accepted: table D0 indexed by N.H,
    highlights clamped, one-sided, no Fresnel. The other tables, inputs and Fresnel arrive with the steps that use them
    (L4 and the bump, environment and fog work), so the reader refuses anything else rather than ignoring it.
  - On PC and the Vita the built-ins are MBS-E1 ("isn't written for PC and the Vita yet") until L3.
  - `tev_test.odin` has the golden lit plan; `shader_tev_test.odin` reads it back and refuses each bad lighting line.
    `mesh.3ds.tev` is now `mbs-tev 2` with no lighting (it doesn't light). The 3DS runtime only maps the two sources
    to citro3d's; applying the `lighting` section is L4.

**L3. The built-ins on PC and Vita.** `light_diffuse` / `light_specular` written as HLSL and Cg over the `.LIGHTS` block. Done when: the
IR interpreter, the HLSL (pixel tests on the D3D software device) and a model of the 3DS's table lookup agree within a
stated tolerance on random normals, views and lights.

**L4. The 3DS runtime.** `render_3ds` fills `C3D_LightEnv` from `set_lighting` and `C3D_Light`s from `set_lights`
(directions moved into eye space per camera), builds each table once, and binds the environment for lit draws and
unbinds it for unlit ones (sprites, text, the HUD). Done when: a model check lit per pixel on all three targets.

**L5. Per-vertex lighting** in `mesh.mbs` on all three targets, from the same uniforms. Done when: the same scene lit
both ways on each target.

**L6. The API.** `Light`, `create_directional_light`, `set_lights`, `set_lighting` (main's names), and the way a game
picks per-vertex or per-pixel (open question 1). Done when: examples/model-check shows both, and the cheatsheet lists
the new procedures.

**L7. Hardware passes.** The 3DS check and the Vita check grow a lighting step each; the user runs them.

## What the same unit opens (after the G2 core)

*Decided 2026-11-23:* normal and bump maps, environment mapping, procedural textures and fog **will be done**, after
L0-L7; stereoscopic 3D is **deferred**. Each gets its own steps when it starts, with a hardware test as L0 had. Notes
so the G2 design doesn't close them off:
- **Normal and bump maps:** `C3D_LightEnvBumpMode` / `BumpSel` read a texture as a normal or tangent map. Needs
  tangents in the vertex (a `.mbm` format version 2 when it comes).
- **Environment mapping:** reflection tables (RR, RG, RB) with Fresnel give cheap view-dependent colour; cube textures
  (`C3D_TexInitWithParams` with a cube) give real reflections from a reflection-vector texture coordinate.
- **Procedural textures:** the procedural texture unit (`C3D_ProcTex*`) makes noise and patterns from tables, sampled
  as texture unit 3, with no image in memory. A shader-language built-in would map it to code on PC and Vita.
- **Fog:** `C3D_FogLut` after the TexEnv; an easy one once the lighting work has shown how fixed-function sections
  enter the `.tev` plan.
- **Stereoscopic 3D (C6), deferred:** the unit works in eye space, so each eye needs its light directions in that eye's
  space, or both eyes share the centre eye's and accept the small difference. Decided if C6 is ever taken up.
- **Resource use:** per-pixel quality with no per-pixel program, and the vertex unit freed of lighting maths.

## Open questions

The five asked on 2026-11-23 are answered under "What was decided". Still open, for the steps that reach them:
- **More lights than the target takes:** when a scene sets more than the limit, which are kept (the nearest, the
  brightest, the first given) or whether it is an error. Decided at L6.
- **The real limits on PC and the Vita:** measured, not guessed, before either is raised above 8.
- **The built-in's final name and shape:** revisited after L3.
