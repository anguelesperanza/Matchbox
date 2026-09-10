/*
    Environment probe -- prefiltered specular convolution
    ---------------------------------------------------------
    `create_environment_probe`'s (ambient.odin) other bake pass: for every
    texel of every face of every roughness level, blur the source cube map
    in a cosine-weighted cone around that texel's own world direction,
    treated as a mirror-reflection direction rather than a surface normal --
    see this file's own top comment in ambient.odin for what this trades
    away against a real GGX importance-sampled prefilter (a longer-tailed
    highlight shape) and what it keeps (a normalized, energy-preserving
    kernel, checked by `ibl_test.odin`'s own uniform-environment sweep).

    The cone's half-angle widens with `roughness^2`, the same remap
    `pbr_distribution_ggx` (brdf/pbr_common.hlsli) applies to get its own
    GGX parameter `a` from the artist-facing roughness slider -- not because
    this file's own blur is GGX (it is not: no importance sampling, no
    normal distribution function, just a uniform cosine-weighted cone), but
    because reusing the identical remap means this map's roughness axis
    lines up with the same slider a material's own `roughness` already is,
    rather than introducing a second, differently-shaped curve a game would
    have to learn separately.

    **`roughness == 0` is a mirror and is handled as one, exactly**, rather
    than as a cone of width 0: `sin(theta)` -- the solid-angle measure every
    other angle in this integral is weighted by -- vanishes at `theta = 0`
    the same way it does at the sphere's own pole, so a cone-angle-scales-to-
    zero limit would divide a vanishing numerator by a vanishing denominator
    instead of reducing cleanly to a single sample. Short-circuiting to the
    raw environment lookup avoids needing to reason about that limit at all.
*/

TextureCube<float4> env : register(t0, space2);
SamplerState        smp : register(s0, space2);

cbuffer FragData : register(b0, space3)
{
    float4 roughness_data; // x roughness for this level, y-w unused -- Probe_Prefilter_Frag_Data (types.odin)
};

static const float PROBE_PI = 3.14159265358979323846;

// 8 x 16 -- coarser than the irradiance bake's own 12x24 (probe_irradiance.frag.hlsl's
// own comment) since this runs `prefilter_level_count` times as many draws
// (once per roughness level as well as per face); a cone blur has no single
// sharp feature the way a mirror reflection would, so the coarser grid costs
// no more visible banding than the level count itself already introduces --
// see pbr_environment_specular's (brdf/pbr_common.hlsli) own doc comment on
// why levels are discrete steps rather than a real mip chain to begin with.
#define PREFILTER_N_THETA 8
#define PREFILTER_N_PHI   16

float3 sample_env(float3 d)
{
    // Same left-handed hardware cube-map convention skybox_cubemap.frag.hlsl's
    // own x-negation exists for.
    return env.Sample(smp, float3(-d.x, d.y, d.z)).rgb;
}

float4 main(float4 pos : SV_Position, float3 dir : TEXCOORD0) : SV_Target
{
    float3 r = normalize(dir);
    float  roughness = saturate(roughness_data.x);

    // GGX's own artist-roughness remap (pbr_distribution_ggx's own `a =
    // roughness^2`), reused here as this file's own top comment explains,
    // scaled to fill [0, pi/2] -- a full hemisphere cone at roughness 1.
    float cone_half_angle = roughness * roughness * (PROBE_PI * 0.5);

    if (cone_half_angle <= 1e-5)
    {
        // A mirror: no blur to perform, and the sin(theta)-weighted
        // integral below is degenerate at theta = 0 regardless (see this
        // file's own top comment) -- return the single sample directly.
        return float4(sample_env(r), 1.0);
    }

    float3 up_hint = (abs(r.y) < 0.999) ? float3(0, 1, 0) : float3(1, 0, 0);
    float3 right   = normalize(cross(up_hint, r));
    float3 up      = cross(r, right);

    float dtheta = cone_half_angle / float(PREFILTER_N_THETA);
    float dphi   = (2.0 * PROBE_PI) / float(PREFILTER_N_PHI);

    float3 total  = float3(0.0, 0.0, 0.0);
    float  weight_sum = 0.0;

    for (int ti = 0; ti < PREFILTER_N_THETA; ti++)
    {
        float theta  = (float(ti) + 0.5) * dtheta;
        float sin_t  = sin(theta);
        float cos_t  = cos(theta);
        float weight = sin_t * cos_t; // cosine-weighted, same kernel shape probe_irradiance.frag.hlsl uses

        for (int pi_i = 0; pi_i < PREFILTER_N_PHI; pi_i++)
        {
            float  phi        = (float(pi_i) + 0.5) * dphi;
            float3 local_dir  = float3(sin_t * cos(phi), sin_t * sin(phi), cos_t);
            float3 sample_dir = local_dir.x * right + local_dir.y * up + local_dir.z * r;

            total      += sample_env(sample_dir) * weight;
            weight_sum += weight;
        }
    }

    /*
        Normalized by its own weight sum, not by a fixed constant the way
        the irradiance bake divides by pi -- this cone's own solid angle
        shrinks with roughness, so a fixed divisor would not stay
        energy-preserving across levels the way dividing by the sum of
        exactly the weights actually used does. A uniform environment of
        radiance L divides out to exactly L regardless of cone width, which
        is what `ibl_test.odin`'s own uniform-environment sweep checks
        across every level rather than only the mirror one above.
    */
    return float4(total / max(weight_sum, 1e-6), 1.0);
}
