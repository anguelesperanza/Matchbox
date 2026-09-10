/*
    Unlit
    -----
    What replaces the old fixed-direction fallback that ran whenever a scene
    had no lights set -- see `lighting_rework.md` section 1's first defect,
    and `shade_surface`'s own doc comment (`lighting_core.hlsli`) for the
    other way to reach this same output: `Lighting_Settings.enabled = false`
    forces every material through this regardless of its own shading model.

    No ambient, and (see `brdf_light_unlit` below) nothing any light
    contributes either -- a material that chose this, or a scene with
    lighting off, is not lit by anything, which is the honest statement
    `lighting_rework.md` section 1 asks for in place of an accident of how
    many lights happened to be set.

    **`shade_lights` (`lighting_core.hlsli`) still calls `sample_light` once
    per light even for this model.** That loop is shared, unconditional
    code -- see `brdf/contract.hlsli`'s own doc comment for why it does not
    special-case any one shading model -- so an unlit material with many
    lights in the scene still pays for each light's distance/shadow lookup
    only to discard the result immediately below. Cheaper than P0's own
    `brdf_eval_unlit`, which took none of that cost, but it is the trade
    that keeps the seam a plain dispatch rather than shared code that knows
    one model's name.
*/
Radiance brdf_light_unlit(Surface surface, Light_Sample light)
{
    return (Radiance)0;
}

// `total` is always zero -- `brdf_light_unlit` never contributes to it --
// so this is unconditionally `surface.base_color`, the same output
// `brdf_eval_unlit` gave before this split.
float3 brdf_resolve_unlit(Surface surface, Radiance total)
{
    return surface.base_color;
}
