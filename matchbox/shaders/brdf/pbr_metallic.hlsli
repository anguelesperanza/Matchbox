/*
    PBR metallic-roughness
    -----------------------
    Cook-Torrance under the industry-standard metallic-roughness
    parameterization -- `lighting_plan.md` section 1's "PBR metallic-roughness
    (Cook-Torrance/GGX -- industry standard)". The GGX distribution, Smith
    visibility and Schlick Fresnel it is built from live in
    `brdf/pbr_common.hlsli`, shared with `pbr_specgloss.hlsli` -- see that
    file's own top comment for why the maths is factored out rather than
    copied into each parameterization.

    **This is not blinn_phong with different numbers.** Per
    `lighting_rework.md` section 7.4, the old look is not a constraint here:
    this model is physically motivated rather than tuned toward PsxGame's
    picture, and its `brdf_resolve_pbr_metallic` below is the plain,
    un-scaled combine that decision describes -- no ambient-over-ten, no
    `(1 + specular) * diffuse` cross term. Each shading model decides for
    itself what ambient means (`brdf_resolve_blinn_phong`'s own doc comment
    makes the same point from the other side); this is the "boring", literal
    case `lighting_rework.md` section 2.1 says most of the remaining models
    would be.

    `f0` -- the surface's reflectance straight back at the viewer, at normal
    incidence -- is the one piece of real PBR machinery a metallic-roughness
    material has to derive rather than read directly: `lerp(0.04, base_color,
    metallic)`. 0.04 is the standard stand-in for "an unspecified dielectric"
    (most real-world non-metals cluster near 4% reflectance regardless of
    colour); a full metal's `f0` is its own base colour, which is also why a
    metal's visible colour comes entirely from its specular term -- the
    `(1 - metallic)` factor on the diffuse term below is what removes the
    other half of a metal's would-be Lambertian response, since a metal does
    not scatter light back out from underneath its surface at all.

    **The diffuse energy split is two Fresnel terms, not one, and this was
    found rather than assumed.** The first version of this file weighted
    diffuse by `(1 - F(v_dot_h))` -- the same Fresnel value the specular term
    itself uses, which reads naturally as "whatever fraction isn't reflected
    specularly is left over for diffuse". `pbr_test.odin`'s furnace sweep
    caught it failing its own gate: at a grazing view angle (`view_cos_theta`
    around 0.2, roughly 78 degrees) and mid roughness, the total reflected
    energy ran as high as 1.24 for a uniform environment of 1. The cause is
    geometric -- at the specular lobe's own peak, the half vector sits close
    to the surface normal *regardless of how grazing the view is* (that is
    what "peak" means for a mirror-like reflection), so `v_dot_h` there is
    just `n_dot_v`, not necessarily large, while `D` is at its biggest right
    at that same peak. A single Fresnel term evaluated at `v_dot_h` does not
    reliably suppress diffuse exactly where specular is largest, so the two
    lobes can both be large in the same place and the sum exceeds what a
    uniform environment actually sent in.

    The fix is the classic two-sided diffuse Fresnel transmission --
    `(1 - F(n_dot_v)) * (1 - F(n_dot_l))` -- read as "light must cross the
    interface once to enter (weighted by how little of it reflects away at
    the light's own angle) and once more to leave toward the eye (weighted
    the same way at the view's own angle)" rather than "whatever the
    specular lobe didn't take". `pbr_test.odin`'s furnace sweep, re-run
    against this version across the same roughness values and view angles
    (including that same grazing one), stays under 1 everywhere it checks --
    see that file's own results for the actual numbers, not a claim made
    without them.
*/

Radiance brdf_light_pbr_metallic(Surface surface, Light_Sample light)
{
    Radiance r = (Radiance)0;

    if (light.n_dot_l <= 0.0)
        return r;

    float3 h         = normalize(surface.view + light.direction);
    float  n_dot_v   = max(dot(surface.normal, surface.view), 1e-4);
    float  n_dot_h   = max(dot(surface.normal, h), 0.0);
    float  v_dot_h   = max(dot(surface.view, h), 0.0);
    float  roughness = max(surface.roughness, PBR_MIN_ROUGHNESS);

    float3 f0 = lerp(float3(0.04, 0.04, 0.04), surface.base_color, surface.metallic);

    float  d = pbr_distribution_ggx(n_dot_h, roughness);
    float  v = pbr_visibility_smith_ggx(n_dot_v, light.n_dot_l, roughness);
    float3 f = pbr_fresnel_schlick(v_dot_h, f0);

    float3 specular = f * (d * v);

    // Two-sided diffuse Fresnel transmission, not the specular term's own
    // v_dot_h-based F -- see this file's own top comment for the furnace
    // failure that distinguishes them and why only this form stayed under 1.
    // A metal (metallic 1) keeps none of it, per that same comment.
    float3 f_v     = pbr_fresnel_schlick(n_dot_v, f0);
    float3 f_l     = pbr_fresnel_schlick(light.n_dot_l, f0);
    float3 kd      = (1.0 - f_v) * (1.0 - f_l) * (1.0 - surface.metallic);
    float3 diffuse = kd * surface.base_color / PBR_PI;

    r.diffuse  = diffuse * light.radiance * light.n_dot_l;
    r.specular = specular * light.radiance * light.n_dot_l;

    return r;
}

/*
    The plain, physically-based combine `lighting_rework.md` section 2.1
    calls "the boring case this was designed for": the two accumulated
    channels, `emissive` (a surface's own light, independent of anything
    arriving from outside it), and `ambient_light(surface) * occlusion` --
    ambient reaches every point equally except where `occlusion` says a
    point is tucked away from it. No division, no cross term: unlike
    blinn_phong's resolve, GGX's energy split already happened per-light,
    above, so there is nothing left for this step to do but add.

    **`pbr_environment_specular` joined this in P4**, occlusion-weighted the
    same way the diffuse ambient term already is -- see that function's own
    doc comment (brdf/pbr_common.hlsli) for why it is a second call rather
    than folded into `ambient_light`, and why it is a silent zero under
    every `Ambient_Kind` but `ENVIRONMENT_PROBE`. `f0` is recomputed here
    rather than threaded through from `brdf_light_pbr_metallic`: the two
    functions are never guaranteed to run back-to-back for the same light
    (`shade_lights` calls this once per surface, that once per light), and
    recomputing four scalars is cheaper than a second field on `Radiance`
    every other shading model would then carry unread.
*/
/*
    **`ambient_light` is irradiance arriving, not light leaving**, so the
    diffuse half of it has to be multiplied by what the surface actually
    reflects. This read `ambient_light(surface) + ambient_specular` until P7c,
    adding the raw ambient colour to every pixel whatever it was made of --
    so a scene with `Ambient_Kind.HEMISPHERE` set to a pale blue sky got that
    pale blue added to every surface in it, and every material washed toward
    it. A red box came out pink; a *black* surface came out pale blue, which
    is the version of the bug that cannot be argued with.

    It survived because nothing tested it. `pbr_test.odin`'s white-furnace
    sweep checks `brdf_light_pbr_metallic`, which is the per-light half and
    was correct; `brdf_test.odin` mirrors `brdf_resolve_blinn_phong`, which
    is a different model and multiplies by `base_color` as it should. The two
    PBR resolves were the only ones doing it wrong and the only ones with no
    mirror. `brdf_test.odin` now checks the property directly for every model.

    **It also made SSAO look broken**, which is how it was found: occlusion
    multiplies the ambient term, so with ambient a large flat addition rather
    than a modulation of the surface, AO darkened a uniform wash laid over the
    picture instead of shading the surface -- a grey smudge rather than
    contact shadow.

    `(1 - metallic)` for the same reason `brdf_light_pbr_metallic` has it: a
    metal does not scatter light back out from underneath its surface, so it
    has no diffuse response to ambient either. Its ambient comes entirely
    through `pbr_environment_specular`, which is already weighted by `f0` and
    was always correct.

    No `/ PBR_PI` here, unlike the per-light diffuse term. `Ambient.color` is
    a look knob a game picks by eye (see `Ambient`'s own doc comment,
    lighting.odin) rather than a measured irradiance, and dividing it by pi
    would mean the number a game types is not the brightness it gets. The
    per-light term divides because its `radiance` really is one.
*/
float3 brdf_resolve_pbr_metallic(Surface surface, Radiance total)
{
    float3 f0 = lerp(float3(0.04, 0.04, 0.04), surface.base_color, surface.metallic);
    float3 ambient_specular = pbr_environment_specular(surface, f0);

    float3 ambient_diffuse = ambient_light(surface) * surface.base_color * (1.0 - surface.metallic);

    return total.diffuse + total.specular + surface.emissive +
        (ambient_diffuse + ambient_specular) * surface.occlusion;
}
