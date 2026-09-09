/*
    Bloom, pass one -- which light blooms, and shrink it once
    ---------------------------------------------------------
    Reads the full-resolution HDR scene target and writes the first (half
    resolution) level of the bloom chain, keeping only the part of each pixel
    that is bright enough to spill.

    **The threshold is applied after the downsample, not before, and that is
    a real choice.** Thresholding all 13 taps first and averaging afterwards
    would let a single very bright texel survive a neighbourhood that is
    otherwise dark, which is the classic bloom firefly: one pixel of specular
    highlight on a moving surface turns into a flickering blob two levels
    further down the chain. Averaging first dilutes that pixel into its
    neighbours before the knee ever sees it. What it costs is that a lone
    bright pixel below the average may not bloom at all -- the trade every
    engine makes here, and the reason production bloom usually also carries a
    Karis luminance average inside the downsample. **That is deliberately not
    here**: it needs a rendered frame to tune against, there is no GPU in the
    environment this was written in, and a stated gap is better than a guessed
    constant. See `bloom.odin`'s own top comment.

    `curve` is worked out on the CPU (`bloom_prefilter_curve`, bloom.odin) so
    that the knee = 0 case never divides by zero in here -- see that proc for
    what it packs and why the shader gets four numbers rather than a threshold
    and a knee.

    Must match matchbox.Bloom_Prefilter_Frag_Data.
*/

#include "bloom.hlsli"

cbuffer FragData : register(b0, space3)
{
    float2 texel; // one texel of the source (the HDR target), in uv
    float2 _pad;
    float4 curve; // x threshold - knee, y 2 * knee, z 0.25 / knee, w threshold
};

Texture2D<float4> tex : register(t0, space2);
SamplerState      smp : register(s0, space2);

/*
    The soft knee, scaling a colour by how far its brightest channel is past
    the threshold. Below `threshold - knee` nothing survives; above
    `threshold` the plain difference does; between the two a quadratic joins
    them smoothly, so a surface drifting across the threshold fades into
    bloom rather than popping into it.

    Scales the colour rather than subtracting from it, which is what keeps
    hue: subtracting the threshold from each channel separately would push a
    saturated orange highlight toward white as it brightens.

    Mirrors `bloom_prefilter_weight` (bloom.odin) exactly -- that one is what
    `post_test.odin` sweeps, since there is no way to run this.
*/
float3 bloom_prefilter(float3 c)
{
    float brightness = max(c.r, max(c.g, c.b));

    float soft = clamp(brightness - curve.x, 0.0, curve.y);
    soft = curve.z * soft * soft;

    // max(brightness, tiny) rather than a branch: a black pixel has nothing
    // to scale and the numerator is zero there anyway, so the floor only
    // exists to keep 0/0 out of it.
    float weight = max(soft, brightness - curve.w) / max(brightness, 1e-5);
    return c * weight;
}

float4 main(float4 pos : SV_Position, float2 uv : TEXCOORD0) : SV_Target0
{
    float3 color = bloom_downsample_13(tex, smp, uv, texel);

    // The 3D pass can hand back a small negative from floating-point error in
    // a BRDF even though nothing physical is negative -- the same floor
    // `tonemap_expose` (tonemap.odin) applies for the same reason. It matters
    // more here: `brightness` below is a max across channels, so one negative
    // channel would otherwise ride through the knee untouched and then be
    // amplified by every upsample that follows.
    color = max(color, 0.0);

    return float4(bloom_prefilter(color), 1.0);
}
