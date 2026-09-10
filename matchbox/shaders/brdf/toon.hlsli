/*
    Toon / cel shading
    -------------------
    `lighting_plan.md` section 1's "Toon/cel-shading". The visual signature of
    the style is a diffuse response that jumps between a small number of flat
    steps rather than shading smoothly, plus (commonly, and cheap enough to
    include unconditionally rather than gating it behind a second material
    flag) a rim-light term that brightens a silhouette edge regardless of
    which lit/unlit band it falls in. `Surface.bands` and `Surface.rim` are
    exactly those two knobs, already reaching this shader (`mesh.frag.hlsl`)
    with nothing left to plumb.

    This model has no specular term -- `lighting_plan.md`'s own entry for it
    only asks for banded diffuse and a rim light, so `Radiance.specular` is
    left at its zero-initialized value throughout and never contributes to
    `brdf_resolve_toon`'s combine below, the same "field rides along unread"
    shape `Light.cone` already has for a light that is not a spot.
*/

Radiance brdf_light_toon(Surface surface, Light_Sample light)
{
    Radiance r = (Radiance)0;

    // `bands <= 1` is "one flat step", a legitimate if degenerate caller
    // choice, not a divide-by-zero -- see `material_normalized`'s own
    // comment (material.odin) for why a *zero* `bands` is instead treated as
    // "unset" and defaulted before it ever reaches this shader.
    float bands   = max(surface.bands, 1.0);
    float banded  = floor(light.n_dot_l * bands) / bands;

    r.diffuse = light.radiance * banded;

    return r;
}

/*
    Rim: brightest where the view grazes the surface's own silhouette (view
    near-perpendicular to the normal, `n_dot_v` near 0) and zero looking
    straight on -- the standard `1 - n_dot_v` mask, squared to narrow it to
    the actual edge rather than half the visible hemisphere, scaled by the
    material's own `rim` strength. Unlike the per-light banding above, this
    depends only on the (single, scene-wide) view direction, so it belongs in
    the resolve step rather than the per-light one -- computing it once here
    is exact, not an approximation of computing it per-light and averaging.

    Ambient here is a flat, un-scaled add tinted by `base_color` and
    attenuated by `occlusion`, the same shape the PBR models' resolves use
    (`brdf_resolve_pbr_metallic`'s own doc comment) -- toon has no physically-
    based reason to divide it, the way blinn_phong's own ambient-over-ten is
    PsxGame's tuning rather than anything this model inherits (see
    `lighting_rework.md` section 7.4). Each model decides this for itself;
    this is toon's answer. `ambient.rgb` became `ambient_light(surface)`
    (`lighting_core.hlsli`) in P4, the one edit this file needed for
    `Ambient_Kind.HEMISPHERE`/`.ENVIRONMENT_PROBE` to reach a toon material
    at all -- no specular environment term is added, since a banded model
    has no continuous roughness for `pbr_environment_specular`
    (brdf/pbr_common.hlsli) to key a reflection sharpness off of.
*/
float3 brdf_resolve_toon(Surface surface, Radiance total)
{
    float n_dot_v = max(dot(surface.normal, surface.view), 0.0);
    float rim     = surface.rim * pow(1.0 - n_dot_v, 2.0);

    float3 color = surface.base_color * (total.diffuse + rim);
    color += surface.emissive;
    color += surface.base_color * ambient_light(surface) * surface.occlusion;

    return color;
}
