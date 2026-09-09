/*
    Blinn-Phong
    -----------
    Ported from this package's own `lighting.hlsli` -- itself ported from
    PsxGame's lighting.fs. P0 kept the arithmetic constant for constant so
    that phase had a reference picture to check its own refactor against;
    P2b's job is a second refactor, splitting the one function P0 shipped
    into the three pieces `brdf/contract.hlsli` now describes, and the
    arithmetic is *still* the same re-associated expression -- with one
    stated exception, `brdf_light_blinn_phong`'s own specular term, which is
    this rework's first deliberate change to how this model looks. See that
    function's doc comment for what changed and why.

    See `brdf/contract.hlsli` for why this no longer owns its whole light
    loop the way P0's `brdf_eval_blinn_phong` did: the `base_color *
    (1 + specular) * diffuse` combination has a cross term between every
    pair of lights, but both `specular` and `diffuse` are themselves plain
    sums -- only the final combine is nonlinear, so splitting accumulation
    (this file) from resolution (`brdf_resolve_blinn_phong`, below) expresses
    that cross term exactly, with no special case and no light loop here at
    all.

    The specular exponent is read from the bound `Material` cbuffer's own
    `emissive.w` (`mesh.frag.hlsl`) rather than from `Surface` -- see
    `material.odin`'s own `Material_Frag_Data` packing comment. `Surface`
    only carries what a shading model needs that a future deferred G-buffer
    could also supply (`surface.hlsli`'s own doc comment); a scalar this
    specific to one model is cheaper read straight off the material that is
    already bound for this draw.
*/

/*
    One light's diffuse and specular contribution -- P0's own per-iteration
    body (`lighting.hlsli`'s predecessor), re-expressed against
    `Light_Sample` instead of reading `lights[i]`/`shadow_visibility`
    directly. `light.radiance` already carries that light's colour,
    attenuation and shadow together (`sample_light`'s own doc comment,
    `lighting_core.hlsli`), and `light.n_dot_l` is the same clamped dot P0
    computed inline as `ndl`.

    diffuse:  P0 had `lights[i].color.rgb * ndl * attenuation * shadow`,
              which is exactly `light.radiance * light.n_dot_l` once colour,
              attenuation and shadow are already folded into `radiance`.

    specular: **Coloured, where P0's own port was not.** P0 accumulated
              `spec * attenuation * shadow` alone, with no colour term, while
              the diffuse sum above carried the light's colour. Folding
              colour into `light.radiance` -- the whole point of this file's
              split, see `sample_light`'s doc comment -- means specular would
              have had to divide that colour back out again just to stay
              bit-for-bit identical to the old, uncoloured result, which is
              precisely the "awkward line" `lighting_rework.md` section 2.1
              already flags rather than asks anyone to write. Section 7.4 has
              already released the old look as a constraint, so the honest
              move is to let specular be coloured instead: `light.radiance *
              spec` rather than `spec * attenuation * shadow`. A white light's
              highlight looks identical either way; a coloured light now
              tints its own highlight the way a real one would. **This is
              this rework's first deliberate change to `blinn_phong`'s
              arithmetic** -- every other line in this file and in
              `brdf_resolve_blinn_phong` is P0's own expression, re-associated
              rather than rewritten.
*/
Radiance brdf_light_blinn_phong(Surface surface, Light_Sample light)
{
    Radiance r = (Radiance)0;

    r.diffuse = light.radiance * light.n_dot_l;

    if (light.n_dot_l > 0.0)
    {
        float specular_power = emissive.w; // Material's own, see this file's top comment
        float spec = pow(max(0.0, dot(surface.view, reflect(-light.direction, surface.normal))), specular_power);

        r.specular = light.radiance * spec; // coloured -- see this function's own doc comment
    }

    return r;
}

/*
    P0's own final combine, unchanged: `base_color * (1 + specular) *
    diffuse` plus `base_color * (ambient / 10)`. This is where PsxGame's
    cross term between every pair of lights' specular and diffuse
    contributions actually happens -- `total.specular` and `total.diffuse`
    are each a sum across every light already (`shade_lights`,
    `lighting_core.hlsli`), so multiplying the two sums here reproduces the
    same cross terms P0's single accumulating loop produced, without either
    sum needing to know about any other light while it was being built.

    **`ambient.rgb` became `ambient_light(surface)` in P4**, the one edit
    this file needed for `Ambient_Kind.HEMISPHERE`/`.ENVIRONMENT_PROBE`
    (lighting.odin) to reach this model at all -- see that function's own
    doc comment (lighting_core.hlsli). The `/ 10.0` stays local to this
    model regardless of which `Ambient_Kind` supplied the colour: it is
    PsxGame's own tuning of what *Blinn-Phong* does with ambient, not a
    property of a flat colour specifically, so the two new modules must not
    (and do not) bypass it -- `ambient_light`'s own return value means the
    same thing to this resolve whichever module produced it. No specular
    environment term is added here even under `ENVIRONMENT_PROBE`: this
    model has no physically-based notion of a prefiltered reflection, the
    same reason `pbr_environment_specular` (brdf/pbr_common.hlsli) is a
    second, separate call the two PBR models opt into rather than something
    every resolve function receives automatically.
*/
float3 brdf_resolve_blinn_phong(Surface surface, Radiance total)
{
    float3 color = surface.base_color * (1.0 + total.specular) * total.diffuse;
    color += surface.base_color * (ambient_light(surface) / 10.0);

    return color;
}
