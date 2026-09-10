# Using the lighting system

Every name here is public. A game importing the package as `mb` writes
`mb.set_lighting(...)`.

---

## 1. Call order

Per frame, outside in:

```odin
mb.set_lights(lights[:])          // whenever they change; cheap enough per frame
mb.set_lighting(settings)         // only when settings change

mb.begin_drawing()
mb.clear_background(colour)

  // models that should cast shadows, submitted BEFORE the 3D pass
  mb.draw_model(model, transform, casts_shadow = true)

  mb.begin_drawing_3d(camera)
      mb.draw_skybox(skybox)      // first, if any
      mb.draw_model(model, transform)   // everything else
  mb.end_drawing_3d()

  mb.draw_text(...)               // 2D goes after end_drawing_3d, never inside
mb.end_drawing()
```

Rules that are enforced with an assertion rather than a warning:

- 2D drawing cannot happen between `begin_drawing_3d` and `end_drawing_3d`.
- `draw_model` must be inside a 3D pass, a shadow pass, or a probe capture --
  except with `casts_shadow = true`, which is the one call made outside.
- `draw_skybox` must be inside a 3D pass.

`casts_shadow = true` holds the call and lets the framework replay it into
every shadow map that wants it and then into the scene. Prefer it to opening
shadow passes by hand: `begin_shadow_pass` is PCF and PCSS's shape only, and
CASCADED needs a pass per cascade per slot while CUBE needs six.

`set_lighting` and `set_lights` each replace the whole thing rather than
patching a field, so keep your own `Lighting_Settings` value and re-submit it
with one field changed.

---

## 2. Turning lighting on

```odin
settings := mb.Lighting_Settings{
    enabled  = true,
    exposure = 1,
    tonemap  = .ACES,
    ambient  = {kind = .HEMISPHERE, color = SKY, ground_color = GROUND},
}
mb.set_lighting(settings)
```

`enabled = false` draws every material through `Shading_Model.UNLIT` -- its
base colour, flat. This is a statement about the scene, not something that
happens when the light list empties.

**A field left at zero that has no sensible zero gets its default**
(`exposure = 0` becomes 1, and so on), so a partial literal is safe. Fields
whose zero is a real answer are taken literally: `Ambient{}` is no ambient
light, `Fog{}` is no fog, `metallic = 0` is a dielectric.

**A struct with `enabled = false` is left entirely alone**, so
`Shadow_Settings{}`, `Bloom{}`, `Ssao{}` and `Volumetric{}` all stay off and
untouched.

---

## 3. Lights

```odin
lights: [8]mb.Light
count := 0

lights[count] = mb.create_directional_light({-0.3, -1, -0.4}, {1, 0.95, 0.85, 1}, casts_shadow = true); count += 1
lights[count] = mb.create_point_light({0, 2, 0}, {1, 0.5, 0.2, 1});                                     count += 1
lights[count] = mb.create_spot_light(pos, dir, mb.WHITE, inner_angle = 14, outer_angle = 26);           count += 1
lights[count] = mb.create_area_rect_light(pos, normal, right, width = 2, height = 1);                   count += 1
lights[count] = mb.create_area_disk_light(pos, normal, radius = 1);                                     count += 1

mb.set_lights(lights[:count])
```

There is no light limit -- they upload as a storage buffer. Area lights use a
representative-point approximation and **cannot cast shadows**.

---

## 4. Materials and shading models

One per `Model_Part`. Generated shapes and glTF parts without one get
`MATERIAL_DEFAULTS` (lit, white, Blinn-Phong).

```odin
for &part in model.parts do part.material = mb.create_material_pbr_metallic(
    base_color = {0.8, 0.2, 0.15, 1}, metallic = 0, roughness = 0.4)
```

| Constructor | Model | Reads |
| --- | --- | --- |
| `create_material_phong` | `BLINN_PHONG` | `base_color`, `specular_power` |
| `create_material_pbr_metallic` | `PBR_METALLIC` | `base_color`, `metallic`, `roughness`, `emissive` |
| `create_material_pbr_specgloss` | `PBR_SPECGLOSS` | `base_color`, `specular`, `glossiness`, `emissive` |
| `create_material_toon` | `TOON` | `base_color`, `bands`, `rim`, `emissive` |
| `create_material_subsurface` | `SUBSURFACE` | `base_color`, `subsurface`, `thickness`, `emissive` |
| `create_material_unlit` | `UNLIT` | `base_color` only |

Every constructor also takes `textures: Material_Textures` -- base colour,
metallic-roughness, occlusion, emissive. **Normal maps are not applied**:
`Vertex3D` carries no tangent, so there is no basis to apply one in.

`load_model(path, shading)` honours what the glTF file declares
(`pbrMetallicRoughness` becomes `PBR_METALLIC`, `KHR_materials_unlit` becomes
`UNLIT`); pass a `Shading_Model` to force one for the whole file.

**`Material.transparent = true`** is required for anything alpha-blended under
`DEFERRED`, which cannot put a transparent part in the G-buffer and falls back
to a forward draw for it.

---

## 5. Render pipelines

```odin
settings.pipeline = .FORWARD   // or .CLUSTERED, .DEFERRED
```

| Kind | Use when |
| --- | --- |
| `FORWARD` | The default. Every light evaluated for every fragment. |
| `CLUSTERED` | Many lights. Same picture; each fragment loops only the lights reaching its cluster. Reads `settings.cluster`. |
| `DEFERRED` | Many lights and heavy overdraw. Opaque triangle parts fill a G-buffer; transparent and LINES parts fall back to forward automatically. |

All three fill the same `Surface` and run the same shading models, so the
picture should not change when you switch. If it does, that is a bug.

---

## 6. Shadows

**Opt in twice**: the scene enables the system, and a light says it casts.

```odin
settings.shadows = mb.SHADOW_DEFAULTS     // enabled, PCF, 1024, extent 20
settings.shadows.technique = .CASCADED
```

```odin
light := mb.create_directional_light(dir, colour, casts_shadow = true)
```

| Technique | Light kinds | Notes |
| --- | --- | --- |
| `PCF` | directional, spot | One map per caster. The default. |
| `PCSS` | directional, spot | Penumbra widens with occluder distance. Reads `light_size`. |
| `CASCADED` | directional, spot | Reads `cascade_count` (max 4) and `cascade_split_lambda`. For large scenes. |
| cube | point | **Not in this enum.** A point light with `casts_shadow = true` gets six maps automatically, whatever `technique` is set to. |

At most **2** directional/spot casters (`MAX_SHADOW_CASTERS`) and **1** point
caster at a time. Extra `casts_shadow` lights are lit but cast nothing.

Tuning, in `Shadow_Settings`: `resolution`, `extent` (half-width of the
orthographic frustum for PCF/PCSS; CASCADED computes its own), `near`/`far`,
and `bias` (`depth` and `normal_offset`). A light may override the scene's bias
with its own `shadow_bias`.

Driving the passes by hand is possible -- `begin_shadow_pass(slot)`,
`begin_cascade_shadow_pass(slot, cascade)`, `begin_point_shadow_pass(face)`,
each returning false when there is nothing to render, each closed with
`end_shadow_pass()` -- but `casts_shadow = true` picks the right shape for the
technique and is what to use unless you need otherwise.

---

## 7. Ambient

```odin
settings.ambient = {kind = .HEMISPHERE, color = SKY, ground_color = GROUND}
```

| Kind | Reads | Result |
| --- | --- | --- |
| `CONSTANT` | `color` | One flat colour everywhere. |
| `HEMISPHERE` | `color` (sky), `ground_color` | Blended by the surface normal against world +Y. |
| `ENVIRONMENT_PROBE` | a bound probe | Baked irradiance and prefiltered specular. |

Ambient is multiplied by the surface's albedo, so a black surface stays black
and **a scene with `Ambient{}` has no ambient light at all**.

`ENVIRONMENT_PROBE` also gives metals something to reflect. A fully metallic
material has no diffuse term, so without a probe it reflects only the lights
and renders nearly black.

### Environment probe from a skybox

```odin
probe, err := mb.create_environment_probe(skybox)   // skybox must be a cube map
mb.set_environment_probe(probe)                     // takes ownership
settings.ambient.kind = .ENVIRONMENT_PROBE
```

---

## 8. Reflection probes

Localized probes capture the scene from where they stand and blend by
distance; whatever they do not cover falls back to the scene-wide probe above.
Up to 4.

```odin
// once, at load
a := mb.add_reflection_probe({-5, 1.5, 0}, radius = 7)
b := mb.add_reflection_probe({ 5, 1.5, 0}, radius = 7)

// inside begin_drawing/end_drawing, but NOT inside begin_drawing_3d
for index in 0 ..< mb.get_reflection_probe_count() {
    for face in 0 ..< 6 {
        if mb.begin_probe_capture(index, face) {
            draw_my_scene()          // casts_shadow = false; include the floor
            mb.end_probe_capture()
        }
    }
    mb.bake_reflection_probe(index)
}
```

Then set `settings.ambient.kind = .ENVIRONMENT_PROBE`.

Capturing renders the scene six times per probe -- do it at load, or when
something large moves, not per frame. Probes do not see each other, so capture
twice if you want one probe's bounce in another.

`clear_reflection_probes()` forgets them all; the textures are kept.

---

## 9. SSAO

```odin
settings.ssao = mb.SSAO_DEFAULTS    // radius 0.5, intensity 1, bias 0.02, 16 samples, blur 2
```

**It does nothing without ambient light**, because occlusion multiplies the
ambient term. If SSAO looks like it is not working, check `settings.ambient`
first.

`radius` is in world units and is the number to tune first -- it is how far
away something has to be before it stops shadowing, so it depends entirely on
the scale your scene is built at. `bias` trades self-occlusion grain against
the contact shadow; `blur = 0` skips the blur pass and shows the raw sampling.

Under `FORWARD` and `CLUSTERED` this costs a **depth prepass**: the geometry is
drawn once more with no fragment work. `DEFERRED` gets it for one fullscreen
pass, since the G-buffer already has depth.

---

## 10. Volumetric light

```odin
settings.volumetric = mb.VOLUMETRIC_DEFAULTS   // density 0.03, anisotropy 0.6, 32 steps, 40 units
```

**Needs a shadow-casting light to look like anything** -- without shadows there
is nothing to cut the beam into shafts, only a smooth haze.

`density` is per world unit and small (0.03 is a light haze, 0.3 is thick fog).
`anisotropy` is forward-scattering above 0 and backward below, in (-1, 1).
`steps` is the whole cost: one shadow lookup per casting light per step.

---

## 11. Post: bloom, grading, tonemap, exposure

```odin
settings.tonemap  = .ACES              // NONE, REINHARD, ACES, AGX
settings.exposure = 1
settings.post.bloom = mb.BLOOM_DEFAULTS    // threshold 1, knee 0.5, intensity 0.05, scatter 0.7, 5 levels
settings.post.grade = {enabled = true, contrast = 0.2, saturation = 0.1, gain = {0.1, 0, -0.1}}
```

`Bloom.threshold` is in linear light, so 1 means "brighter than white" -- lower
it for a scene that never reaches that. `levels` widens the halo, `intensity`
strengthens it, and the two do not affect each other.

**Every `Color_Grade` field is a delta from identity**, so `Color_Grade{}` is
an exact no-op and a partial literal is safe. `lift` adds, `gain` scales,
`gamma` bends the midtones, `contrast` pushes from mid grey, `saturation`
pushes from luminance.

Grading runs after the tonemap curve on a [0, 1] value; bloom runs before
exposure, on scene light.

---

## 12. Fog

```odin
settings.fog = {enabled = true, color = {0.05, 0.08, 0.16, 1}, start = 3, end = 22}
```

`start`/`end` are distances from the camera and want to fit the scene -- a
range wider than the room means nothing visibly fogs. `color` is a linear
value mixed before the tonemap curve, so it is not the exact pixel colour you
will see.

---

## 13. Reading state back

`is_lighting_active()`, `is_shadows_active()`, `get_reflection_probe_count()`.
What `set_lighting` stored is the normalized value, so reading a field back
gives what actually runs.

---

## 14. Gotchas

- **Logging.** `init` installs a logger on its own context. Set
  `context.logger = mb.mbi.logger` or you will see nothing Matchbox logs.
- **A metal with no environment probe renders nearly black.** Correct, and the
  most common reason PBR looks wrong.
- **`draw_grid` and wireframes are LINES topology**, which is unlit and skipped
  by shadow and depth passes.
- **Changing the pipeline should not change the picture.** If it does, report
  it.
- **`examples/lighting-lab`** puts all of the above on keys with the state on
  screen, and depends on no asset files.
