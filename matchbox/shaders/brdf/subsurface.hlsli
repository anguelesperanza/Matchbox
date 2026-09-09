/*
    Subsurface (wrapped diffuse / translucency approximation)
    ------------------------------------------------------------
    `lighting_plan.md` section 1's "Subsurface scattering (for skin, wax,
    foliage)". **What this is, stated plainly because it would be easy to
    mistake for more than it is: a wrapped-diffuse term plus a thickness-
    scaled translucency tint, both cheap enough to run per-fragment in a
    forward pass. This is not a BSSRDF.** It does not simulate light entering
    the surface, scattering through a participating medium and exiting
    elsewhere -- there is no multiple scattering, no diffusion profile, no
    wavelength-dependent scattering distance, and no notion of *where* on the
    surface the light re-emerges relative to where it entered. A real BSSRDF
    (or even a screen-space diffusion approximation) is a render-pipeline-
    level feature -- it needs either a separable blur pass over irradiance or
    a raymarched medium -- and is out of scope for a per-fragment BRDF module
    under this contract; see `brdf/contract.hlsli`'s own doc comment for why
    no `brdf_light_*`/`brdf_resolve_*` may reach outside the `Surface` it was
    handed. What is here is the cheap, forward-compatible stand-in engines
    reach for when a full BSSRDF is not in budget: wrap the terminator so
    thin geometry does not go abruptly black at grazing light angles, and tint
    the wrapped portion to fake "light that scattered under the surface and
    came back out a different colour".

    **Wrap lighting.** A Lambertian surface goes fully dark the instant
    `n.l` crosses zero -- a hard terminator that reads as "opaque" even on
    material that light should visibly bleed through (a hand held in front of
    a bright light, a thin leaf). Wrap lighting (Wyman, used in numerous
    shipped renderers) softens that edge by adding a constant `wrap` before
    normalizing back to `[0, 1]`, letting some light past the geometric
    terminator instead of clipping at it. `Light_Sample.n_dot_l` arrives
    already clamped to 0 (its own doc comment, `brdf/contract.hlsli`) because
    every other model in this directory wants exactly that -- wrap lighting
    is the one model here that specifically needs the *raw*, signed cosine
    instead, and it is recomputed below from `surface.normal` and
    `light.direction` (both already on the structs this model was handed)
    rather than by widening the shared contract for one model's own need.

    **Thickness.** `Surface.thickness` is treated as normalized -- 0 is "as
    thin as this material gets" (an ear, a leaf, a wax candle wall) and 1 is
    "thick enough that no light gets through" -- rather than a real physical
    unit, since nothing in this package's material pipeline measures one.
    Thinner material both wraps more (`wrap` below) and tints the wrapped
    light more strongly (`brdf_resolve_subsurface` below): both are the same
    physical intuition, that less material means both more geometric wrap and
    more of the exiting light having picked up the medium's own colour.
*/

Radiance brdf_light_subsurface(Surface surface, Light_Sample light)
{
    Radiance r = (Radiance)0;

    float raw_n_dot_l = dot(surface.normal, light.direction); // signed -- see this file's own top comment

    float wrap    = saturate(1.0 - surface.thickness);
    float wrapped = saturate((raw_n_dot_l + wrap) / (1.0 + wrap));

    r.diffuse = light.radiance * wrapped;

    return r;
}

/*
    `total.diffuse` already carries the wrapped response from every light.
    `base_color` tints it the way any diffuse surface would; `subsurface`
    tints the same wrapped total a second time, scaled by how thin the
    material is, standing in for "some of what wrapped around picked up the
    medium's own colour on the way through" -- the cheap half of the
    approximation this file's own top comment names. Ambient is flat and
    un-scaled, `base_color`-tinted and `occlusion`-attenuated, the same
    choice `brdf_resolve_toon` makes and for the same reason: nothing here is
    physically based enough to justify PsxGame's ambient-over-ten the way
    blinn_phong's own resolve still does.
*/
float3 brdf_resolve_subsurface(Surface surface, Radiance total)
{
    float3 color = surface.base_color * total.diffuse;
    color += surface.subsurface * total.diffuse * saturate(1.0 - surface.thickness);
    color += surface.emissive;
    color += surface.base_color * ambient.rgb * surface.occlusion;

    return color;
}
