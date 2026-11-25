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
    **DONE 2026-11-25 (generated and tested; no runtime loads it yet, that is L4-4 and L4-5).**
    - `matchbox/shaders/mesh_lit.mbs`: `mesh.mbs` plus a `normal` attribute, fourth, in `Lit_Vertex`'s order (the 3DS
      loads it as attribute 3). The vertex stage writes the eye-space normal as a quaternion (`normalquat`) and the
      way back to the eye (`view`); the fragment is `light_diffuse * (texture * colour) + light_specular`, then the
      alpha cut. Normals are turned by the model matrix itself, not its inverse transpose: exact for a uniform scale,
      slightly off for a model stretched along one axis (said in the shader).
    - The 3DS plan came out as intended: stage 0 `texture * vertex colour`, stage 1 `MULTIPLY_ADD FRAGMENT_PRIMARY
      PREVIOUS FRAGMENT_SECONDARY`, the D0 table on N.H, highlights clamped, one-sided, `secondary_alpha_zero`.
    - `frame.view` is in mbsc's `FRAME_FIELDS` after `time`, at offset 80 (HLSL starts a matrix on a new row), so the
      block is 144 bytes and nothing before it moved. PC's `Frame_Constants` has it and `camera_start` fills it; the
      startup layout check (`reflection_windows.odin`) knows it. The 3DS and the Vita find uniforms by name and fill
      `frame_view` in L4-5. The unlit `mesh` outputs gained the declaration only: its `.gxp` programs are unchanged
      (psp2cgc does not reproduce a `.gxp` byte for byte, even from the old Cg; the 4 bytes that differ are the same
      header ones), so they were not rebuilt.
    - `mesh_lit_v.gxp` and `mesh_lit_f.gxp` compiled with psp2cgc and committed.
    - Fixed on the way in mbsc: the Cg backend wrote the lights uniforms and functions into the vertex program too
      (the built-ins are fragment only), and a local named `lit` shadowed Cg's built-in `lit()`; now `facing`.
    - Every committed generated file is guarded by a test for both shaders, the 3DS's `.v.pica` and `.tev` for the
      first time (`the_committed_3ds_shaders_are_what_mbsc_writes_now`, which also assembles with picasso).
    - Left for L4-5: `3ds_build.bat` assembles only `mesh.shbin`; `mesh_lit.shbin` needs a line there (a handheld
      file, shown to the user first).
  - L4-4. PC: a second pipeline, the lights buffer at b3, lit items drawn with it.
    **DONE 2026-11-25, PC only (seen on screen and measured; the handhelds are L4-5).**
    - `Render_Pipeline` on PC, as the handhelds have: `mbi.pipeline` (mesh.mbs) and `mbi.lit_pipeline`
      (mesh_lit.mbs), each with its shaders, input layout and reflection; the constant buffers are shared and each
      pipeline binds the ones its reflection lists. A lit mesh is drawn with the lit pipeline while
      `mbi.lighting.settings.enabled`; off, it goes through the unlit one as before L4.
    - The lights buffer is filled once per camera, at `camera_end` (`calculate_lights_block` with that camera's view),
      and only while lighting is on. `Render_Item` carries the part's `material` into `Render_Constants`;
      `render_mesh` and anything else not from a model get `mbi.model_settings.default_material`.
    - mbsc's PC reflection now lists the lights block (`block lights 3 3104` and its five values) whenever a shader
      calls a light built-in, found by walking the IR (`calls_light_builtin`), plus `render` when the shader left it
      out. The engine reads `lights` as a `Block_Kind` and checks it against `Lights_Block` at start, like `frame` and
      `render`. The vertex attribute table has `normal` at `Lit_Vertex`'s offset, marked lit-only: the unlit pipeline
      is refused it, since it also draws 36-byte vertices that have none.
    - Measured on screen (a scratch copy of model-check with one sun, captured from the window; the framebuffer is
      sRGB, so expected values were converted): with a light from (1, 2, 1) and 0.2 ambient, the cube's front and
      right faces are both (135, 163, 205) against (135, 161, 205) worked by hand, the top and the floor saturate to
      exactly the tint. A light from +x alone lights only right-facing sides, from +z only front-facing ones.
      I first read the cube's faces as different and the scene as mirrored in x; the pixels showed it wasn't.
    - Not done here: model-check itself still turns no light on (L4-6).
  - L4-5. 3DS and Vita runtimes (each file shown to the user first): a second pipeline; on the 3DS `C3D_LightEnv`,
    the lights, one D0 table per distinct shininess, bound for lit draws and unbound after.
    **DONE 2026-11-25 in the emulators (drafts shown to the user and applied on their OK; not on hardware yet).**
    - 3DS: `mbi.pipeline` and `mbi.lit_pipeline`, each with its `.shbin` and `.tev` plan; `3ds_build.bat` assembles
      `mesh_lit.shbin` too. `Lighting_Unit` (in `mbi.lighting_unit`) is set from the lit plan: clamped highlights, the
      zero FR table on the secondary's alpha, a light per slot with no ambient of its own. Lights are filled at
      `camera_end`, made unit length; a part's material goes in as ambient 1, diffuse 1, specular0 = strength, with
      a D0 table per shininess kept in a map and set only when the material changes. A pipeline is bound only when
      the next draw needs the other one; binding the unlit one unbinds the environment.
    - **citro3d's vertex uniforms are one array shared by both programs**, and the unlit program's constants start at
      c10, where the lit one keeps `frame_view`. The camera's matrices are set again after every switch. In Azahar
      the HUD and the print log drew correctly after lit draws; hardware has not been asked.
    - **o3dx's `C3D_FVec` binding names its fields x, y, z, w; citro3d lays it out w, z, y, x** (c3d/types.h), so
      `.x` through the binding is citro3d's w. The light position is built in citro3d's order by a helper in the
      render file; o3dx itself is unchanged, left for the user.
    - Vita: the same two pipelines, the lit one reading `a_normal` at stride 48. The camera's matrix and this
      camera's lights block live in `Backend_State` and are written into every lit draw's uniform buffers (GXM keeps
      none between draws), 400 bytes a draw. mbsc's Vita reflection now lists the lights uniforms.
    - Measured, one sun from (1, 2, 1) with 0.2 ambient, against the formula in linear colour: cube front and right
      (61, 93, 155) expected, (61, 93, 154) in both Azahar and Vita3K; top (102, 153, 255) expected, (101, 153, 254)
      in both; floor (102, 102, 115) expected, (100, 102, 114) and (101, 103, 115). Not checked: the highlight's
      value, a lit cut-out, lighting switched off with this code, and real hardware.
  - L4-6. `examples/model-check` lit on all three targets.
    **DONE 2026-11-25 on PC, in the emulators, and on the New 3DS LL and the Vita (the user ran the builds below
    on both and reported them good).**
    - model-check sets one sun from (1, 2, 1) with 0.2 ambient, and L or the bottom face button (FACE_DOWN: B on
      the 3DS, Cross on the Vita) switches lighting off and on. It adds a lit cut-out: a plane stood upright with
      an 8 x 8 checkerboard texture made in code, the dark squares alpha 0, cut at 0.5, two-sided.
    - Measured (PC in sRGB turned back to linear; the handhelds are linear): the sphere's brightest pixel, the
      highlight, has red 229 on PC, 228 in Azahar and 230 in Vita3K (green and blue saturate). The board's white
      squares are 155 expected (0.2 + L.N 0.41), 157 on PC, 155 in Azahar and 157 in Vita3K, and its holes show
      what is behind on all three: a highlight leaves the cut-out alone. Lighting off draws every model flat as
      texture times tint on all three, and back on lights again (checked both ways in Azahar).
    - A brightest-pixel reading of 172 for the board in Azahar was JPEG ringing at the square edges of a scaled
      screenshot; the median of the white squares is 155.
    - Hardware builds, each with its own name, title and first line ("model check lit (G2 L4-6)"):
      `build/hardware/model_check_lit.3dsx` (title ModelCheckLit) and `build/hardware/model_check_lit.vpk` (Model
      Check Lit, MBOX00046). Both looked good on hardware (2026-11-25): with L4-5's code that is the first lit
      draw on the real lighting unit and the real GXM, including the program switching and the zero FR table.

**L5. Per-vertex lighting** in `mesh.mbs` on all three targets, from the same uniforms. Done when: the same scene lit
both ways on each target.
- **Decided 2026-11-25, before starting, with the user:**
  - **The highlight is folded into the vertex colour:** colour = tint x vertex colour x (ambient + diffuse) +
    specular, then x texture, the same on all three targets. The 3DS passes one interpolated colour to the TexEnv
    stages (`PRIMARY_COLOR`), so a per-vertex highlight can't be added after the texture there as the per-pixel one
    is; folding it on every target keeps them alike. Exact on an untextured part; on a textured one the highlight
    takes the texture's colour, which per-pixel doesn't.
  - **A `.LIGHTS` block a shader declares** (decision 4), and per-vertex lighting written as ordinary code in a
    third engine shader, `mesh_vertex_lit.mbs`, not in `mesh.mbs`: `mesh.mbs` draws sprites and text, whose
    `Vertex` has no normal.
  - **The choice is global and per part, both now** (L6's per-part choice brought forward): a mode in
    `Lighting_Settings`, and a per-part override. Its exact shape is shown to the user before it is written.
- Steps:
  - L5-0. mbsc: `@(uniform = .LIGHTS) lights: struct { ambient: [4]f32, direction, diffuse, specular:
    [LIGHT_SLOT_COUNT][4]f32 }`, any subset, on every backend; `LIGHT_SLOT_COUNT` a predeclared constant, the
    target's `get_max_lights` (not `MAX_LIGHTS`, which in the engine is 8 on every target, PC included). The block is the same one the light built-ins read, so a shader can declare it and call them.
    **DONE 2026-11-25 (tests only).** `LIGHT_SLOT_COUNT` is added to every module as an ordinary constant, so array
    lengths, loop bounds and expressions read it like one the shader wrote; declaring it again is refused. The block
    must be named `lights`. HLSL writes one `cbuffer mbs_lights_block` at b3 whether the block is declared, a
    built-in is called, or both, and the built-ins' functions only with a built-in; Cg declares the uniforms in
    both programs when the block is declared (psp2cgc drops them where unread), the functions in the fragment one
    only; the PICA backend needed nothing new (a struct uniform is split per field, and the unrolled loop indexes
    by constant). Both reflection files list the block when declared. `lights_block_test.odin`: one test shader
    (`testdata/vertex_lights.mbs`) on all three targets, 64 slots on PC and 8 on the handhelds, the PICA program
    against the IR interpreter on random lights, psp2cgc, d3dcompiler, picasso, and the refused shapes.
  - L5-1. `mesh_vertex_lit.mbs`, generated for all three; checked against the formula: the IR interpreter and the
    PICA machine model run its vertex stage on vertices whose answer is worked out in f64.
    **DONE 2026-11-25 (tests only; no runtime draws it yet).** `matchbox/shaders/mesh_vertex_lit.mbs` and its
    outputs for every target (the Vita's `.gxp` compiled with psp2cgc), each guarded by the stale-file tests. The
    3DS program is 271 instructions of 512, and its `.tev` plan a single `texture x vertex colour` stage.
    - **The 3DS's 16 temporary registers shaped the shader:** written the obvious way it needed more. mbsc's PICA
      backend lets a variable's register go when its block ends, not after its last use, and the unrolled loop is
      one block; so the eye-space values are worked out in a block of their own, and the loop keeps only what more
      than one line reads. Said in the shader. A liveness-based allocator in mbsc would lift this.
    - `vertex_lighting_test.odin`: 400 random scenes (a model turned, scaled and moved, a look-at camera, 1 to 8
      lights of any length with the rest empty, random colours and materials), the colour from the IR interpreter
      and from the PICA program on the machine model against the model worked out in f64 from its description:
      1.03e-6 worst for both. Dropping the "only where L.N > 0" gate from the reference makes it 0.19 off, so the
      test sees it. The machine model's `rsq`, `lg2` and `ex2` are exact; the real unit's are not, which is the
      hardware pass's to see.
  - L5-2. The API (shown first), and PC drawing per-vertex.
    **DONE 2026-11-25, PC (measured on screen).** Decided with the user after asking what engines do (Godot puts
    a shading mode on the material, with a project setting that can force per-vertex): **on the material, with the
    scene's setting as the default.** `Lighting_Mode{PER_PIXEL, PER_VERTEX}` (per pixel the zero value),
    `Lighting_Settings.mode`, `Material.lighting:Maybe(Lighting_Mode)` (nil follows the scene; not stored in .mbm),
    `get_lighting_mode(material)`. PC has a third pipeline, `mbi.vertex_lit_pipeline`, chosen per draw.
    - Measured against per-pixel with the same scene: the cube's faces, the floor's tint and the board's squares
      are equal to the pixel (a flat face under a directional light has the same diffuse at every corner); the
      highlights differ as they should: the floor 2 levels brighter from its corners' highlights blended across it,
      the sphere's peak (237, 255, 250) against (243, 255, 255), 2 pixels off.
  - L5-3. The 3DS and the Vita drawing per-vertex (each file shown first).
    **DONE 2026-11-25 in the emulators (drafts shown and applied on the user's OK; not on hardware yet).** Each
    handheld has a third pipeline, `vertex_lit_pipeline`, and a pipeline's `lighting:Maybe(Lighting_Mode)` says
    which it is (nil unlit). 3DS: the camera's lights block is kept in `mbi.camera_lights` and set into the
    per-vertex program's registers after every switch, with the camera's matrices; shininess and strength per
    draw; `3ds_build.bat` assembles `mesh_vertex_lit.shbin`. Vita: the lights and material go into the vertex
    program's uniform buffer per vertex, the fragment one's per pixel.
    - Measured with a probe drawing everything per vertex but the sphere, whose material asks for per pixel, so a
      frame switches between all three programs: cube front and right (61, 93, 154) in both emulators, as per
      pixel; the board's white squares 156 and 157; the per-pixel sphere's peak red 228 in Azahar and 230 in
      Vita3K, its L4-6 values, so the switching leaves each program's registers right.
  - W6 and W8 (a workstream of `docs/g2_remaining_work.md`, not an L-step). mbsc's PICA register allocator frees by last use.
    **DONE 2026-11-25 (tests and Azahar; not on hardware).** `pica_block` works out, for each variable a block
    declares, the statement that touches it last (a statement that holds a loop or an `if` counts whole), and lets go
    of its registers after that statement, instead of at the block's end; a statement that returns is left to the
    caller as before. `mesh_vertex_lit.mbs` is back to the obvious form (the eye-space block and its comment are
    gone): 267 instructions, 13 temporaries of 16, against 271 with the hand structure. W8: `pica_safe_name` takes
    an allocator, and the test that called it passes `context.temp_allocator`, so its leak no longer prints (the
    other leaks the run lists, from `report.odin`, `diagnostic.odin` and the string builder, were there before).
    - New test `a_variable_lets_go_of_its_register_after_its_last_use` (24 chained variables); with the release
      switched off it fails with "needs more than 16 temporary registers". All 137 tests pass, the 400-scene
      per-vertex model still 1.03e-6 from f64. Regenerated: `mesh`, `mesh_lit`, `mesh_vertex_lit` `.3ds.v.pica`
      (register names only, in the first two), and `mesh_vertex_lit`'s HLSL and Cg (the same program without the
      block; its `.gxp` is unchanged, as the Cg is the same code).
    - Azahar, model-check forced per vertex (scratch edit, not committed), old and new `.pica` built separately:
      the static parts match to the pixel (blue cube (62, 93, 155), floor (105, 105, 118), sphere (89, 203, 108)).
      The crate and cylinder turn, so two runs of the *same* build differ by as much as old against new does;
      the old/new comparison there is the machine-model test's.
  - L5-4. model-check lit both ways on every target; hardware builds.
- **W7. o3dx's `C3D_FVec` fixed (decision D7).**
  **DONE 2026-11-25 in Azahar; hardware check pending.** o3dx declared `C3D_FVec` as `{x, y, z, w}` over citro3d's
  `{w, z, y, x}`, so `.x` wrote citro3d's w. Fixed in O3DX on its own branch (`fix-c3d-fvec-field-order`, PR
  anguelesperanza/O3DX#6 into `main`): the struct is `{w, z, y, x}` and `math.odin`'s helpers use the names. Matchbox
  has the same `c3d/types.odin` and `c3d/math.odin`, and `create_citro3d_vector` is gone: light positions are
  `c3d.C3D_FVec{x = ..., y = ..., z = ..., w = 0}`.
  - Measured in Azahar, model-check before and after: the cube's front and right, its top, the floor and the board's
    white squares have identical pixel counts at their reference values (4101, 848, 81210 against 81203, 1611); the
    rest of the frame differs only where parts rotate. Hardware build: `build/hardware/w7_fvec_fix.3dsx` (title
    `W7FVecFix`, model-check, which prints no test name of its own).
- **Paused 2026-11-25 after L5-3.** What is left of G2 (L5-4, L6, L7, point and spot lights, the open questions) is
  laid out for the next session's agents in `docs/g2_remaining_work.md`, with the decisions the user makes first.

**L6. The API's remainder.** *DONE 2026-11-25 (W3).* The API itself came forward into L4 and the per-part choice into
L5-2; what was left:
- `Lights_Block` and `calculate_lights_block` are package-private (D3): only the runtimes and tests use them, a game
  never fills a lights block.
- `set_lights` given more than `get_max_lights()` prints "set_lights: 9 lights given, this target takes 8" and panics
  with the same text (D2). The panic carries it because a 3DS crash screen replaces the print log, so the print alone
  would never be seen there.
- Measured with a deliberate 9-light scratch example (deleted): Azahar's crash screen shows the line; Vita3K's
  `ux0:data/matchbox.log` holds it, then the panic line. Not run on hardware.
- The cheatsheet is dropped from L6 (D1): it is regenerated once the API has stabilised.

**L7. Hardware passes.** The 3DS check and the Vita check grow a lighting step each; the user runs them.

**L8. Point and spot lights (W4 of `docs/g2_remaining_work.md`).** Written 2026-11-25 before any code, after merging W6 (the
liveness register allocator) and W7 (the `C3D_FVec` fix) into this branch. Follows `main`'s behaviour
(`git show main:matchbox/shaders/lighting_core.hlsli`, `sample_light`): a point or spot light fades with distance as
`1 / (1 + 0.09 d + 0.032 d^2)`, d in world units, fixed, no per-light range; a spot adds `smoothstep(cos(outer),
cos(inner), cos_angle)` on top; the highlight fades with distance too. The user approved this API (2026-11-25):
`Light_Kind{DIRECTIONAL, POINT, SPOT}` (directional the zero value), `Light` gains `kind`, `position`, `inner_angle`
and `outer_angle` (degrees, from the axis to the cone edge), `create_point_light(position, color = WHITE)` and
`create_spot_light(position, direction, color = WHITE, inner_angle = 20, outer_angle = 30)`; `MAX_LIGHTS` counts all
kinds together.
- L8-0. **3DS hardware spike**, `light_test4`, one feature a step, as L0 was; the app reads its own framebuffer back
  and prints measured against expected values, so the user's result is numbers. Steps: a directional control (the
  readback itself), a positional light (w = 1, no tables), the DA table with main's curve, the DA table's end (what
  happens past `to`), a spot light (the SP table), and both together. Settles: whether the unit's tables reproduce
  main's curve (if not, the nearest curve comes to the user before the formula changes), the SP table's input and
  signed layout, and the distance beyond the table. **Stops here until the user's result.**
  **DONE 2026-11-25: passed on the New 3DS LL (the user ran it), after passing 31 of 31 in Azahar.** Built as `build/hardware/light_test4.3dsx` (title LightTest4; source kept in `docs/spikes/light_test4_main.odin.txt`). In Azahar all 31 probes are within 3 of the formula: a positional light (w = 1) with no table gives L.N exactly; `LightLutDA_Quadratic(0, 100, 0.09, 0.032)` on DA reproduces main's curve to the level (164, 121, 68, 37 against 164, 121, 67, 37), so **the 3DS tables do reproduce main's curve and no nearest curve is needed**; a DA table ending at 6 holds its last value past the end (the clamp, not a wrap or a zero); a spot table of 256 entries (signed: entries 0 to 127 are cos 0 to 1, 128 to 255 zero) with `C3D_LightEnvLut(.SP, .SP, negative = true)`, `C3D_LightSpotDir` given the way the spot points (the reverse is dark) and `C3D_LightSpotLut` gives main's smoothstep (255, 241, 119, 0, 0 against 255, 241, 117, 0, 0), and spot with DA multiplies. Resolution to remember: the SP input has 128 steps over cos 0 to 1, so a cone narrower than about 7 degrees degrades to a step. The app reads its own framebuffer back and prints got and expected per step.
- L8-1. mbsc and the block: `LIGHT_UNIFORM_NAMES`, `LIGHTS_FIELDS`, `write_light_functions`, the f64 model in
  `lighting_model_test.odin` and the engine's `Lights_Block` layout check change together (a per-slot position and
  spot rows); the stale-file guards name every generated file to regenerate. `Light`, `Light_Kind` and the two
  constructors in `light.odin`; `calculate_lights_block` turns positions into eye space with w = 1.
- L8-2. Per pixel on PC and the Vita (the generated functions) and the 3DS (positional lights, DA and SP tables).
- L8-3. Per vertex everywhere (`mesh_vertex_lit.mbs`'s loop; the 3DS vertex program has 16 temporaries and 512
  instructions, 267 now).
- L8-4. Measured as L4 and L5 were: against an f64 model, and in Azahar and Vita3K; model-check gains a point light;
  hardware builds, and the user's check.

**L8 progress, 2026-11-25 (everything in L8-1 to L8-4 is in and measured except the user's hardware check).**
- Block: a `Lights_Block` row each for position (eye space, w = 0 sun, 1 point, 2 spot) and cone ({cos outer, cos inner,
  k = 1 / (cos inner - cos outer), -cos outer * k}); the directions the engine sends are unit length, so no shader normalizes
  them. 5152 bytes on PC. The mbsc tests (137) and the engine's (98) pass; the f64 model gained kinds, distance fade and cone.
- Per pixel, PC and Vita: `mbs_light_sample` in `write_light_functions`, **written without a branch on the kind**. With the
  distance and the cone inside `if`s, Vita3K drew the point light on a scatter of pixels only (the real Vita is untested
  either way); lerps by `step` give the same maths and a clean picture there and on PC.
- Per pixel, 3DS: positional lights on the unit, `LightLutDA_Quadratic(0, 100, 0.09, 0.032)` and a spot table per cone
  (built once, kept in `Lighting_Unit`). Azahar against PC's linear output: the floor's glow peak (199, 171, 157) against
  (202, 171, 156), a grid of floor points within a median of 2.2 levels (largest 15). The spot was looked at, not measured.
- Per vertex: the loop fits the 3DS vertex program at 501 of 512 instructions (it was 602 at first): unit directions and
  the cone's scale and offset come from the engine, the distance comes from one `inverse_sqrt`, the fade is in Horner form.
  Looked at in Azahar and Vita3K: it draws, the point light tints the crate and the board, the spot lights the cylinder; a big
  floor quad shows no glow because it has four vertices.
- To check on the hardware: whether the unit's DA and SP tables also scale the specular highlight (the PC and Vita shaders do
  fade it); the SP table's 128 steps limit a cone narrower than about 7 degrees. The user's build is
  `build/hardware/model_check_bulbs.3dsx` and `.vpk`; P or the right face button switches the two lights.

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
- *Answered at L6 (D2):* more lights than the target takes is an error, with a one-line reason printed first.
- **The real limits on PC and the Vita:** measured, not guessed, before either is raised above 8.
- *Closed (D6):* the built-ins are `light_diffuse` and `light_specular`, in use and tested since L2; nothing left to
  revisit.
