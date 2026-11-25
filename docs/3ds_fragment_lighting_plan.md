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
     *Raised for PC on 2026-11-25 (L4-1):* `MAX_LIGHTS` stays 8, the count every target takes; `MAX_PC_LIGHTS` is
     64 and exists only in a Windows build, so a game naming it doesn't compile for the handhelds (checked: "not
     declared by 'mb'" on both). PC's block ends with `lights_count` and its loops stop there, so a scene with one
     sun doesn't pay for 64 slots; the Vita's loops still run all 8.
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

**L3. The built-ins on PC and Vita.** `light_diffuse` / `light_specular` written as HLSL and Cg over the lights block. Done when: the
IR interpreter, the HLSL (pixel tests on the D3D software device) and a model of the 3DS's table lookup agree within a
stated tolerance on random normals, views and lights.
- **DONE 2026-11-25 (tests only; nothing lit on screen yet, the runtimes fill the blocks in L4 and L6).** Decided
  with the user first: material per model part (specular strength and shininess, a 3DS D0 table cached per
  distinct shininess in L4), **separate diffuse and specular colours per light**, and unused slots left at zero
  colour with no count.
  - The lights block: `lights_ambient`, then `lights_direction`, `lights_diffuse` and `lights_specular`, each
    `[4]f32` per slot, 8 slots (`get_max_lights` in mbsc's `lighting.odin`, one answer per target). Directions are
    towards the light, in eye space. HLSL `cbuffer` at b3, after the game's b2; Cg uniforms found by those names.
    A shader doesn't declare it yet: calling a light built-in brings it in. Declaring it in a shader of one's own
    (decision 4) comes with per-vertex lighting (L5), the first code that reads it directly.
  - The `render` block gains `shininess` and `specular_strength` (in the row `alpha_cutoff` starts, so still 112
    bytes); `Render_Constants` on PC has them, zero until L6 fills them. When a lit shader doesn't declare
    `render`, mbsc declares it for the specular's material.
  - The formula is in `lighting.odin`'s comment: ambient + diffuse * max(L.N, 0); specular * (N.H)^shininess
    only where L.N > 0 (the unit's clamp highlights), times the strength; each clamped, alpha 1.
  - `lighting_model_test.odin` holds the formula in f64 and a model of the 3DS unit (8-bit colours and results,
    LightLut_Phong's 12-bit entries and 11-bit steps read between entries by |N.H|). On 3,200 random visible pixels
    with 1 to 8 lights the two agree within (lights + 1)/255 + 1/256; the worst seen was 0.0110 against 0.0118
    allowed (one light). `lighting_pixels_windows_test.odin` runs the generated HLSL on the D3D software device: 3e-7
    from the formula. The built-in tests compile both built-ins with the HLSL compiler and psp2cgc.
  - The IR interpreter has no part: the built-ins are fragment only, so there is no PICA program to check against
    it, and the f64 formula is the definition instead.
  - Found on the way: a pixel seen from behind (only drawn with culling off) gets a highlight on the 3DS and not
    on PC, because the unit indexes D0 by |N.H|. L4 decides whether two-sided drawing needs a signed table.

**L4. The 3DS runtime.** `render_3ds` fills `C3D_LightEnv` from `set_lighting` and `C3D_Light`s from `set_lights`
(directions moved into eye space per camera), builds each table once, and binds the environment for lit draws and
unbinds it for unlit ones (sprites, text, the HUD). Done when: a model check lit per pixel on all three targets.
- **Decided 2026-11-25, before starting:** L4 as written needs more than the 3DS runtime. Nothing uploads normals
  (`Vertex` is position, uv, colour), there is one unlit shader and one pipeline per target, and `set_lights` is L6.
  So, with the user:
  - **Models get a vertex of their own with a normal** (`Lit_Vertex`, 48 bytes). Sprites, shapes and text keep the
    36-byte `Vertex`, so 2D pays nothing. Two input layouts per target.
  - **L6's API comes forward into L4:** `Light`, `create_directional_light`, `set_lights`, `set_lighting`,
    `get_max_lights`. L6 keeps the per-vertex choice, the examples and the cheatsheet.
  - **`Light` has `diffuse` and `specular` colours** (not main's single `color`); `create_directional_light(direction,
    color = WHITE)` sets both from one, so the common call reads as main's.
  - **A part's material** (specular strength, shininess) comes from the glTF material's roughness and metallic
    factors, with a soft default (0.5, 16) for a part with none, and is stored in `.mbm`.
- **Found while planning:** the `.tev` plan combines whole colours, and both of the unit's results have alpha 1, so
  `diffuse * texture + specular` would push alpha to 1 and break cut-outs and blending. So `light_specular`'s alpha
  becomes **0** on every target: a highlight adds colour and leaves alpha alone. On PC and the Vita that is the
  generated function. On the 3DS the Fresnel selector can put the FR table's value in the secondary alpha, and an
  all-zero FR table makes it 0. Confirmed on hardware in L4-0.
- Steps:
  - L4-0. A 3DS spike, `light_test3`: L0's scene with the texture's alpha cut out after `primary * tex + secondary`,
    with and without the zero FR table in the secondary alpha. Done when: the cut-out survives the highlight on the
    New 3DS LL.
    **DONE 2026-11-25, on the New 3DS LL:** without the table no holes, with the zero table holes, with a table of
    ones no holes again (the control). Recorded in `docs/shader_pica.md`; `light_specular` returns alpha 0 on PC and
    the Vita, and the `.tev` plan says `lighting_fresnel secondary_alpha_zero`.
  - L4-1. The API above, shared, holding its state in `mbi`; directions are turned into eye space at `camera_end`
    from the camera's view. `Lighting_Settings` holds the ambient colour.
    **DONE 2026-11-25 (tests only; no target uploads the block yet, that is L4-4 and L4-5).** `matchbox/light.odin`:
    `Light{direction, diffuse, specular}` (direction is the way the light travels, as on main),
    `create_directional_light(direction, color = WHITE)`, `set_lights` (more than `get_max_lights()` is an
    `ensure`, not a silent trim; 8 on the handhelds, `MAX_PC_LIGHTS` = 64 on PC), `set_lighting(settings = {enabled = true, ambient = 0.2})`, `get_max_lights`, state in `mbi.lighting`, off
    until a game calls `set_lighting`. `calculate_lights_block(lighting, view)` is the one place directions are
    reversed and turned into eye space; each target's `camera_end` will call it. `light_test.odin` checks it against
    directions worked by hand from two cameras, and the block's layout against the HLSL's.
    `lighting_pixels_windows_test.odin` puts a bright light in the first slot past `lights_count`: with the count
    the HLSL is 3e-7 from the formula; with the loop made to run all 64 it was 0.79 off, so the test sees the count.
  - L4-2. `Lit_Vertex`, `create_lit_mesh` per target, `Model_Part.material`, `.mbm` version 2 (the normals it already
    stores are uploaded; the material is added), the glTF loader building lit meshes.
    **DONE 2026-11-25 (models still draw unlit; the lit pipelines are L4-4 and L4-5).** Decided with the user first:
    every model lights, generated ones too; `Lit_Vertex` is `using vertex:Vertex` plus `normal`, and `mesh_cube`,
    `mesh_plane`, `mesh_sphere`, `mesh_cylinder` return it with exact normals; `Mesh` has a `lit` field on every
    target. `Material{shininess, specular_strength}` per part, default (16, 0.5) in `mbi.model_settings`; a glTF
    material maps by `calculate_material_from_roughness` (2/r^4 - 2 kept to 1..128; (1 - r)(1 + m) kept to 0..1).
    glTF without normals is split and lit flat, as the spec asks. `.mbm` version 2 stores whole `Lit_Vertex` and
    the material. A lit mesh draws through the unlit pipeline with stride 48: PC sets the stride, the Vita has a
    second vertex program of the same shader, the 3DS steps over the normal with a 12-byte padding component
    (`0xE210`, 4 components). model-check on Azahar draws the crate (from a version 2 `.mbm`) and the cylinder
    as before. **Not caused by L4-2, found while checking:** on Azahar the floor, cube and sphere don't show,
    before this change as after (the commit before it built and run side by side). Not run on Vita3K or hardware.
  - **Found 2026-11-25, the missing models:** not the 3DS. `render_model(model, {x, y, z}, ...)` resolves to
    `render_model_transform` on every target: an untyped `{x, y, z}` also fits a `Transform` (position `x` on every
    axis, rotation `y`, scale `0`), and Odin picks the overload with fewer defaults left unfilled
    (`render_model_at` leaves two, scale and tint; the transform form one). The model is queued at zero size.
    Measured on the 3DS by printing the queue, and reproduced standalone on PC; with equal defaults Odin reports
    the call as ambiguous instead. model-check now types its positions (`[3]f32{...}`) and all five models draw
    in Azahar. **Decided with the user:** `render_model_at` loses its `scale` (a scale goes in a Transform,
    `create_transform(position, scale = 2)`), so it leaves as many defaults as the transform form and a bare
    `{x, y, z}` is now a compile error ("ambiguous") rather than an invisible model. Checked against the package:
    the bare literal fails with and without a tint, typed positions and variables compile. An instance struct
    holding placement, as `Sprite` does, was considered and not taken: `Model` owns its meshes, so placement on
    it would mean copies per drawn thing and a double free on destroy.
  - L4-3. `mesh_lit.mbs`, per pixel, generated for all three targets; `frame` gains `view`, which the lit vertex
    stage needs for eye space.
  - L4-4. PC: a second pipeline, the lights buffer at b3, lit items drawn with it.
  - L4-5. 3DS and Vita runtimes (each file shown to the user first): a second pipeline; on the 3DS `C3D_LightEnv`,
    the lights, one D0 table per distinct shininess, bound for lit draws and unbound after.
  - L4-6. `examples/model-check` lit on all three targets.

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
