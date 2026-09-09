/*
    Bloom, pass three -- back up the chain, adding as it goes
    ---------------------------------------------------------
    Reads one level of the bloom chain and writes the level above it, at
    twice the width and twice the height. Run `levels - 1` times per frame,
    from the smallest level upward (`bloom_run`, bloom.odin), so that by the
    time level 0 is written it carries the sum of every level below it.

    **This pass blends rather than overwrites**, and the blend is additive
    (`Color_Blend.ADDITIVE`, init.odin) rather than the alpha blend every
    other pipeline in this package uses. That is the whole mechanism: the
    destination level already holds its own detail from the way down, and
    this adds the blurrier level below on top of it. An overwrite would throw
    away everything but the smallest level, and an alpha blend would need the
    ratio between them carried in an alpha channel nothing writes. It is also
    why this pass's own render pass loads rather than discarding -- see
    `bloom_pass` (bloom.odin).

    Must match matchbox.Bloom_Filter_Frag_Data.
*/

#include "bloom.hlsli"

cbuffer FragData : register(b0, space3)
{
    float2 texel; // one texel of the source (the *smaller*) level, in uv
    float2 _pad;
};

Texture2D<float4> tex : register(t0, space2);
SamplerState      smp : register(s0, space2);

float4 main(float4 pos : SV_Position, float2 uv : TEXCOORD0) : SV_Target0
{
    // Alpha 1 rather than 0 is harmless and deliberate: the additive blend
    // this pipeline is built with takes ONE/ONE for colour and ONE/ZERO for
    // alpha, so the destination's alpha is overwritten rather than summed,
    // and nothing downstream reads a bloom level's alpha at all.
    return float4(bloom_upsample_tent(tex, smp, uv, texel), 1.0);
}
