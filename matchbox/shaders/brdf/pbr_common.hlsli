/*
    PBR common -- the microfacet maths shared by both parameterizations
    ---------------------------------------------------------------------
    `pbr_metallic.hlsli` and `pbr_specgloss.hlsli` are the same Cook-Torrance
    BRDF -- GGX/Trowbridge-Reitz normal distribution, Smith joint-masking
    visibility, Schlick Fresnel -- under two different ways of naming a
    surface's reflectance (metallic-roughness vs. glTF's specular-glossiness).
    `lighting_plan.md` section 1 lists them as two separate modules, and
    `shading.odin`'s own doc comment says plainly that two divergent copies of
    GGX would not be one seam -- so the maths lives here, once, and both
    models' own `.hlsli` files include it rather than restating it.

    This file is not itself a shading model. It defines no `brdf_light_*` or
    `brdf_resolve_*` and is not named in `Shading_Model` (`shading.odin`) or
    switched on anywhere -- it is a plain function library, the same relationship
    `shadow/pcf.hlsli` already has to `shadow_visibility`.

    HLSL has no built-in pi; every model in this directory that needs one
    (the GGX distribution's own normalization, and each model's Lambertian
    diffuse term) uses this one rather than a repeated 3.14159 literal.

    **Why height-correlated Smith rather than a plain `G / (4 * NdotV * NdotL)`
    split.** The classic Cook-Torrance write-up divides by that product
    directly, which is a division by a value that can be arbitrarily close to
    zero at a grazing angle. Folding the `1 / (4 * NdotV * NdotL)` into the
    visibility term itself (Heitz 2014's height-correlated Smith-GGX, the same
    form Filament and Frostbite ship) means `pbr_visibility_smith_ggx` returns
    a value that is already safe to multiply straight into `D * F` -- no
    separate divide at the call site to remember, and no separate epsilon to
    guard it with.
*/

#define PBR_PI 3.14159265358979323846

/*
    Roughness clamped away from 0, shared by both parameterizations below --
    see `pbr_distribution_ggx`'s own comment for why 0 is a true singularity
    (a perfect mirror is a Dirac delta) rather than merely an inconvenient
    one. 0.045 is the same floor Unreal Engine's own metallic-roughness
    shading uses (`a = roughness^2` bottoms out at roughly 0.002), chosen
    there for the same reason: small enough that no artist-visible material
    looks any different, large enough that the highlight stays a bright,
    finite spot rather than a NaN. Declared here rather than in
    `pbr_metallic.hlsli` so `pbr_specgloss.hlsli` does not have to depend on
    include order between two sibling model files to see it.
*/
#define PBR_MIN_ROUGHNESS 0.045

/*
    Trowbridge-Reitz / GGX normal distribution. `roughness` is the artist-
    facing, perceptually-linear value (0 mirror, 1 fully rough); `a =
    roughness^2` is the actual GGX parameter, the standard remap that makes
    the roughness slider behave closer to linearly across its range instead
    of bunching all the visible change into the bottom of it.

    At `n_dot_h = 1` this has a closed form -- `d` reduces to `a2`, so
    `D = a2 / (PI * a2^2) = 1 / (PI * a2)` -- which is what `pbr_test.odin`'s
    furnace test checks this function against, independently, rather than
    against a value produced by running this file and copying the answer.

    `+ 1e-12` in the denominator only matters at `roughness == 0`, where `a2`
    is itself 0 and this would otherwise be a true `0/0` (a perfect mirror is
    a Dirac delta no rasterized punctual light can represent anyway) -- every
    real caller in this directory clamps roughness above `PBR_MIN_ROUGHNESS`
    first (see that constant's own comment below), so this epsilon is a
    last-resort guard against a caller that does not, not the mechanism doing
    the clamping. **It has to be this small and not merely small.** An
    earlier version of this file used `1e-7`, which reads as negligible but
    is not: at `PBR_MIN_ROUGHNESS` (0.045) `a2` is already only about
    `4.1e-6`, so `a2 * a2` is about `1.7e-11` -- smaller than `1e-7` by four
    orders of magnitude, meaning that "guard" was silently dominating the
    real denominator across the entire clamped roughness range and not just
    at the literal zero it was meant to catch. `pbr_test.odin`'s own closed-
    form check (`D` at `n_dot_h = 1` against `1 / (PI * roughness^4)`, worked
    out independently) is what caught it: at `roughness = 0.1` the old
    epsilon put `D` off by more than 4x. `1e-12` sits comfortably below
    `PBR_MIN_ROUGHNESS`'s own `a2^2`, so it changes nothing there and still
    keeps the literal-zero case finite rather than `NaN`.
*/
float pbr_distribution_ggx(float n_dot_h, float roughness)
{
    float a  = roughness * roughness;
    float a2 = a * a;
    float d  = (n_dot_h * n_dot_h) * (a2 - 1.0) + 1.0;

    return a2 / (PBR_PI * d * d + 1e-12);
}

/*
    Smith joint-masking-shadowing, height-correlated (Heitz 2014), already
    divided by `4 * NdotV * NdotL` -- see this file's own top comment for why
    that division is folded in here rather than left to the call site. A
    caller multiplies this straight into `D * F`.
*/
float pbr_visibility_smith_ggx(float n_dot_v, float n_dot_l, float roughness)
{
    float a  = roughness * roughness;
    float a2 = a * a;

    float ggx_v = n_dot_l * sqrt(n_dot_v * n_dot_v * (1.0 - a2) + a2);
    float ggx_l = n_dot_v * sqrt(n_dot_l * n_dot_l * (1.0 - a2) + a2);

    return 0.5 / max(ggx_v + ggx_l, 1e-5);
}

/*
    Schlick's approximation to the Fresnel reflectance. At `cos_theta == 1`
    (normal incidence) `pow(1 - cos_theta, 5)` is exactly 0, so this reduces
    to exactly `f0` -- the other closed-form anchor `pbr_test.odin` checks
    independently, alongside the GGX one above.
*/
float3 pbr_fresnel_schlick(float cos_theta, float3 f0)
{
    float m = clamp(1.0 - cos_theta, 0.0, 1.0);
    return f0 + (1.0 - f0) * (m * m * m * m * m);
}
