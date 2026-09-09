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

/*
    The split-sum BRDF integration term, analytically approximated rather
    than baked -- `ambient.odin`'s own top comment names this as the one of
    P4's three IBL pieces that is not generated at all: no bake pass, no
    texture, no third probe sampler slot (which would have pushed
    `MESH_FRAG_SAMPLER_COUNT`, render.odin, from 10 to 11 -- still under
    Vulkan's floor of 16, but a cost worth avoiding when a closed-form fit is
    this cheap and this close).

    This is the Karis 2014 ("Real Shading in Unreal Engine 4", mobile
    approximation) / Lazarov 2013 ("Getting More Physical in Call of Duty:
    Black Ops II") polynomial fit for `f0 * scale + bias`, where `scale`/
    `bias` are what a real split-sum LUT would otherwise store per
    `(roughness, n_dot_v)` texel.

    **The exact closed-form anchor `ibl_test.odin` checks this against is
    not "scale=1, bias=0 at roughness 0"** -- that would be true of the real
    split-sum integral at normal incidence, but this fit does not reach it
    exactly (`scale` comes out to ~0.994 at `roughness=0, n_dot_v=1`, not
    1.0 -- checked once, independently, in `ibl_test.odin`'s own comment, so
    this file does not overclaim a precision the fit does not have). The
    anchor this polynomial *does* hit exactly, derivable from its own
    algebra rather than measured: `scale + bias` depends on `roughness`
    alone, not on `n_dot_v` or on `a004` at all -- `scale + bias = (-1.04 +
    1.04) * a004 + (r.z + r.w) = r.z + r.w`, and `r.z + r.w = roughness *
    (c0.z + c0.w) + (c1.z + c1.w) = roughness * (-0.55) + 1.0`. So
    `scale + bias == 1 - 0.55 * roughness` identically, for any `n_dot_v` --
    a genuine algebraic fact about this specific fit rather than a physical
    property of a real BRDF LUT, but a useful regression check precisely
    because it is exact: `ibl_test.odin` asserts it to float precision
    rather than to the "a few percent" tolerance the fit's own accuracy
    against a real split-sum integral (the two papers above's own measured
    numbers) would otherwise require.
*/
float2 pbr_env_brdf_approx(float roughness, float n_dot_v)
{
    const float4 c0 = float4(-1.0, -0.0275, -0.572, 0.022);
    const float4 c1 = float4( 1.0,  0.0425,  1.04, -0.04);

    float4 r    = roughness * c0 + c1;
    float  a004 = min(r.x * r.x, exp2(-9.28 * n_dot_v)) * r.x + r.y;

    return float2(-1.04, 1.04) * a004 + r.zw;
}

/*
    The specular half of image-based lighting -- `pbr_metallic.hlsli`/
    `pbr_specgloss.hlsli`'s own resolve calls this alongside `ambient_light`
    (`lighting_core.hlsli`, the diffuse half); no other shading model calls
    it, since Blinn-Phong/toon/subsurface have no physically-based specular
    environment term to add -- see `ambient_light`'s own doc comment for why
    that split is two functions rather than one.

    Returns zero outright under `AMBIENT_CONSTANT`/`AMBIENT_HEMISPHERE`: a
    flat colour or a two-colour gradient has no notion of "the reflection
    seen in this direction", so there is nothing physically meaningful this
    could return under either, and a material's own specular highlight
    (already accumulated per-light, `total.specular`) is what a mirror-like
    surface shows in a scene with no probe rather than a fabricated
    stand-in -- the same "opt in, nothing happens" shape selecting
    `ENVIRONMENT_PROBE` with no probe ever loaded already has
    (`Renderer.default_probe_texture`'s own doc comment, render.odin).

    **The level chosen is a layer index, not a real mip level.** Unlike a
    hardware-filtered mip chain, `prefiltered_map`'s `prefilter_level_count`
    roughness buckets are `prefilter_level_count` *layers* of one
    `Texture2DArray` (`ambient.odin`'s own top comment explains why: every
    layer must share one width/height, so there is no per-level resolution
    falloff the way a real mip chain has) -- `roughness` is turned into the
    nearest layer with a plain `round`, not `SampleLevel`'s own fractional
    interpolation between mips, since there is no second adjacent mip of the
    same texture to blend toward. A visible band between two roughness
    layers is the cost of that choice; see this function's own top comment
    for why a real mip chain was not built instead.
*/
float3 pbr_environment_specular(Surface surface, float3 f0)
{
    if (int(ambient.w) != AMBIENT_ENVIRONMENT_PROBE)
        return float3(0.0, 0.0, 0.0);

    float3 r       = reflect(-surface.view, surface.normal);
    float  n_dot_v = max(dot(surface.normal, surface.view), 1e-4);

    float level_count_minus_one = ambient_ground.w;
    int   level                 = int(round(saturate(surface.roughness) * level_count_minus_one));

    int    face = shadow_cube_face_index(r);
    float2 uv   = probe_layer_uv(r, face);

    float3 prefiltered = prefiltered_map.Sample(probe_sampler1, float3(uv, float(level * 6 + face))).rgb;
    float2 env_brdf    = pbr_env_brdf_approx(surface.roughness, n_dot_v);

    return prefiltered * (f0 * env_brdf.x + env_brdf.y);
}
