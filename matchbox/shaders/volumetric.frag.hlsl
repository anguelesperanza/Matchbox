/*
    Volumetric light -- marching the air between the camera and the scene
    ----------------------------------------------------------------------
    See `volumetric.odin`'s own top comment for what this is and what it
    approximates. This file is the march.

    **It reuses `sample_light` rather than reimplementing the light loop**,
    which is the whole reason it is cheap to have written. That function
    (lighting_core.hlsli) already resolves a light's kind, its attenuation
    curve, a spot's cone and -- the part that matters here -- its
    `shadow_visibility` lookup, and folds all of it into one `radiance`. A
    point in mid-air asks it exactly what a surface asks it. That is the same
    property `lighting_rework.md` section 2.1 claimed the split contract would
    buy and P4 first tested: *a thing that is not a BRDF can still consume the
    light list without widening it.* Shafts through a window are shadow maps
    seen edge-on, and they cost one function call here because that function
    was written for someone else.

    The `Surface` handed to it is a stand-in, and two of its fields are load
    bearing:

    - `position` is the point in the air being sampled, which is what
      attenuation and the shadow lookup both key off.
    - `normal` is **zero**, deliberately. There is no surface here, so there
      is no normal to offset the shadow lookup along -- and
      `Shadow_Bias.normal_offset` multiplies by exactly this vector, so a zero
      turns that half of the bias off while leaving the depth bias doing its
      job. Passing the view direction instead would push every sample along
      the ray and smear the shafts lengthwise.

    Everything else in that struct rides along unread: nothing here calls a
    BRDF, because scattering off air is not a surface reflectance.

    Must match matchbox.Volumetric_Frag_Data.
*/

cbuffer FragData : register(b0, space3)
{
    float4x4 inverse_view_projection;

    float4 params;  // x density, y anisotropy g, z step count, w max distance
    float4 params2; // x intensity, yzw unused
};

Texture2D<float> depth_map : register(t0, space2);
SamplerState     depth_smp : register(s0, space2);

// t1-t6 mirror mesh.frag.hlsl's own t4-t9 exactly, by name as well as by
// type, because `shadow_visibility` and `ambient_light` (lighting_core.hlsli)
// reach for these identifiers by name. The two probe maps are declared and
// bound and never read by anything in this file's own path -- a declared
// sampler has to have something in it, which is what volumetric_run binds
// the placeholder for.
Texture2D<float>       shadow_map0     : register(t1, space2);
SamplerComparisonState shadow_sampler0 : register(s1, space2);
Texture2D<float>       shadow_map1     : register(t2, space2);
SamplerComparisonState shadow_sampler1 : register(s2, space2);

Texture2DArray<float>  cascade_maps    : register(t3, space2);
SamplerComparisonState cascade_sampler : register(s3, space2);
Texture2DArray<float>  cube_maps       : register(t4, space2);
SamplerComparisonState cube_sampler    : register(s4, space2);

Texture2DArray<float4> irradiance_map  : register(t5, space2);
SamplerState           probe_sampler0  : register(s5, space2);
Texture2DArray<float4> prefiltered_map : register(t6, space2);
SamplerState           probe_sampler1  : register(s6, space2);

// One further than the deferred pass, since this shader has no G-buffer but
// does have the depth target ahead of the shared six -- see
// lighting_core.hlsli's own comment on why every one of these moves whenever
// a texture is added anywhere in front of it.
#define SSAO_T 7
#define LIGHTS_T 8
#define CLUSTER_RANGES_T 9
#define CLUSTER_LIGHT_INDICES_T 10

#include "lighting_core.hlsli"

/*
    Henyey-Greenstein. How much light travelling in one direction scatters
    into another -- `cos_theta` between the two, `g` the anisotropy.

    Normalized over the sphere, which is what the 1/(4*pi) is for: at g = 0
    this returns exactly 1/(4*pi) in every direction, so a unit of light
    scattered isotropically spreads over a unit sphere and no more. Mirrors
    `volumetric_phase_hg` (volumetric.odin), which volumetric_test.odin
    integrates numerically to confirm that constant is the right one -- get it
    wrong and every `density` value means something other than what its own
    doc comment says.
*/
float volumetric_phase(float cos_theta, float g)
{
    float gg = g * g;

    // Floored before the power: g at the ends of its range drives this to
    // zero, and a negative from rounding comes back NaN. The CPU-side clamp
    // to +/-0.95 (volumetric_settings_normalized) is what actually keeps it
    // away from there; this is the belt to that pair of braces.
    float denom = max(1.0 + gg - 2.0 * g * cos_theta, 1e-4);

    return (1.0 - gg) / (12.566370614 * denom * sqrt(denom));
}

// The same reconstruction ssao.frag.hlsl uses, and for the same reason: an
// inverse matrix does not need to know whether the projection was perspective
// or orthographic, and a linear-depth formula does and gets a whole frame
// silently wrong if it guesses.
float3 world_from_depth(float2 uv, float raw_depth)
{
    float4 clip  = float4(uv.x * 2.0 - 1.0, 1.0 - uv.y * 2.0, raw_depth, 1.0);
    float4 world = mul(inverse_view_projection, clip);

    return world.xyz / world.w;
}

/*
    Interleaved gradient noise again -- see ssao.frag.hlsl's own copy for what
    it is and why it is a hash rather than a texture.

    Here it offsets where along its ray each pixel takes its first step.
    Without it, every pixel samples the air at the identical set of distances
    and the result is a set of concentric bands one step apart -- the single
    most recognisable artifact of an undersampled raymarch, and far more
    visible than the noise that replaces it, which the eye reads as grain.
*/
float interleaved_gradient_noise(float2 pixel)
{
    return frac(52.9829189 * frac(0.06711056 * pixel.x + 0.00583715 * pixel.y));
}

float4 main(float4 pos : SV_Position, float2 uv : TEXCOORD0) : SV_Target0
{
    float density      = params.x;
    float anisotropy   = params.y;
    float max_distance = params.w;
    float intensity    = params2.x;

    uint steps = uint(params.z);

    float raw = depth_map.Sample(depth_smp, uv).r;

    float3 eye = view_pos.xyz;

    /*
        How far to march. A pixel with geometry in it marches to that
        geometry; a pixel of sky marches to `max_distance` and stops, rather
        than to the far plane -- the absorption term has killed the
        contribution long before then, and marching there anyway would spend
        the whole step budget on the part of the ray that cannot be seen.
    */
    float3 target = world_from_depth(uv, min(raw, 0.999999));
    float3 ray    = target - eye;

    float  distance  = length(ray);
    float3 direction = distance > 1e-5 ? ray / distance : float3(0, 0, 1);

    float march = min(distance, max_distance);
    if (march <= 1e-4 || steps == 0 || density <= 0.0) return float4(0, 0, 0, 1);

    float step_length = march / float(steps);

    // The dither offsets the first sample within its own step, so each pixel
    // samples a different set of distances -- see interleaved_gradient_noise.
    float offset = interleaved_gradient_noise(pos.xy);

    Surface probe = (Surface)0;
    probe.view    = -direction;

    uint light_count = uint(flags.x);
    float3 total = float3(0, 0, 0);

    for (uint s = 0; s < steps; s++)
    {
        float t = (float(s) + offset) * step_length;
        probe.position = eye + direction * t;

        /*
            How much of what scatters here survives the trip back to the eye.
            Beer-Lambert over the distance already marched.

            **Only this half of the absorption is modelled.** The light
            reaching this point has also crossed air on its way in, and that
            is not accounted for -- doing it properly needs the distance from
            each light to each sample, which is a second march per light per
            step. The visible consequence is that a distant light's shaft is
            slightly too bright; the alternative is an effect nobody can
            afford. Stated rather than left to be discovered.
        */
        float transmittance = exp(-density * t);
        if (transmittance < 0.002) break; // nothing further can contribute

        for (uint i = 0; i < light_count; i++)
        {
            Light_Sample l = sample_light(i, probe);

            // The angle between the way the light is travelling (the opposite
            // of the direction toward it) and the way the camera is looking.
            float cos_theta = dot(direction, -l.direction);

            total += l.radiance * volumetric_phase(cos_theta, anisotropy) * transmittance;
        }
    }

    // density * step_length is the fraction of the light in each segment that
    // scatters at all -- the integral this loop is a Riemann sum of.
    total *= density * step_length * intensity;

    // Additive into the HDR scene target, so alpha is not read at all -- see
    // volumetric_run (volumetric.odin) for why this adds to the scene rather
    // than compositing later the way bloom does.
    return float4(total, 1.0);
}
