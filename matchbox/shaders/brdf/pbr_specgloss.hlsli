/*
    PBR specular-glossiness
    ------------------------
    The same Cook-Torrance BRDF as `pbr_metallic.hlsli` -- literally the same
    `pbr_distribution_ggx`/`pbr_visibility_smith_ggx`/`pbr_fresnel_schlick`
    calls, from `brdf/pbr_common.hlsli` -- under glTF's other material
    parameterization (`KHR_materials_pbrSpecularGlossiness`):
    `lighting_plan.md` section 1's "PBR specular-glossiness (alternate PBR
    parameterization)".

    **The one real difference from metallic-roughness is what `f0` is.**
    Metallic-roughness derives it (`lerp(0.04, base_color, metallic)`)
    because "how reflective is this at normal incidence" is not a dial that
    parameterization exposes directly. Specular-glossiness is built the other
    way around -- an artist paints the reflectance directly -- so
    `Surface.specular` *is* `f0`, unchanged, with no metallic term to lerp
    against and no `(1 - metallic)` to remove a diffuse response a metal
    should not have: a spec-gloss material's own `specular` colour already
    says how much of the diffuse budget the microfacet lobe is spending, and
    the `(1 - F)` energy split below accounts for that on its own, the same
    way it does when metallic-roughness's own `f0` is used in its place.

    `Surface.glossiness` is the direct opposite of roughness (`lighting_plan.md`
    calls specular-glossiness PBR's own alternate parameterization for exactly
    this axis, not a second, unrelated one) -- `roughness = 1 - glossiness`,
    clamped the same way and for the same reason `pbr_metallic.hlsli` clamps
    its own roughness.

    **The diffuse energy split is `pbr_metallic.hlsli`'s own fix, not its
    first draft.** That file's own top comment records a furnace-test failure
    at grazing view angles when diffuse was weighted by the specular term's
    own `F(v_dot_h)` -- both lobes turned out large in the same place, and the
    combined total exceeded a uniform environment's own input by as much as
    24%. This model shares the same GGX/Smith/Schlick maths and would fail
    the identical way for the identical reason, so it uses the same two-sided
    `(1 - F(n_dot_v)) * (1 - F(n_dot_l))` transmission below rather than
    reintroducing the failure `pbr_metallic.hlsli` already found and fixed.
*/

Radiance brdf_light_pbr_specgloss(Surface surface, Light_Sample light)
{
    Radiance r = (Radiance)0;

    if (light.n_dot_l <= 0.0)
        return r;

    float3 h         = normalize(surface.view + light.direction);
    float  n_dot_v   = max(dot(surface.normal, surface.view), 1e-4);
    float  n_dot_h   = max(dot(surface.normal, h), 0.0);
    float  v_dot_h   = max(dot(surface.view, h), 0.0);
    float  roughness = max(1.0 - surface.glossiness, PBR_MIN_ROUGHNESS);

    float3 f0 = surface.specular; // spec-gloss: F0 painted directly, no metallic lerp

    float  d = pbr_distribution_ggx(n_dot_h, roughness);
    float  v = pbr_visibility_smith_ggx(n_dot_v, light.n_dot_l, roughness);
    float3 f = pbr_fresnel_schlick(v_dot_h, f0);

    float3 specular = f * (d * v);

    // Two-sided diffuse Fresnel transmission -- see this file's own top
    // comment and pbr_metallic.hlsli's for the furnace failure this form
    // fixes that the specular term's own v_dot_h-based F does not.
    float3 f_v     = pbr_fresnel_schlick(n_dot_v, f0);
    float3 f_l     = pbr_fresnel_schlick(light.n_dot_l, f0);
    float3 diffuse = (1.0 - f_v) * (1.0 - f_l) * surface.base_color / PBR_PI;

    r.diffuse  = diffuse * light.radiance * light.n_dot_l;
    r.specular = specular * light.radiance * light.n_dot_l;

    return r;
}

// Identical combine to `brdf_resolve_pbr_metallic` -- see that function's own
// doc comment, P4's own `pbr_environment_specular` addition included. Both
// PBR models resolve their sums the same, boring way; the two files differ
// only in how each arrives at the per-light `Radiance` and in what `f0` is
// (`surface.specular`, painted directly -- see this file's own top comment
// -- rather than metallic-roughness's own lerp).
float3 brdf_resolve_pbr_specgloss(Surface surface, Radiance total)
{
    float3 ambient_specular = pbr_environment_specular(surface, surface.specular);

    return total.diffuse + total.specular + surface.emissive +
        (ambient_light(surface) + ambient_specular) * surface.occlusion;
}
