/*
    Bloom, pass three -- back up the chain, mixing as it goes
    ---------------------------------------------------------
    Reads one level of the bloom chain and writes the level above it, at
    twice the width and twice the height. Run `levels - 1` times per frame,
    from the smallest level upward (`bloom_run`, bloom.odin), so that by the
    time level 0 is written it carries a mix of every level below it.

    **This pass blends, and the blend is a mix rather than a sum.** It returns
    `scatter` as its alpha and relies on the ordinary source-alpha blend every
    other pipeline in this package uses, which makes the destination

        level_i = (1 - scatter) * level_i + scatter * tent(level_i+1)

    -- a convex combination, so a level that already held some value keeps
    exactly that much of it and no more.

    **Adding instead would have been simpler and is wrong**, which is worth
    stating because adding is what the original dual-filter presentations do.
    Every level of this chain holds the same total light as the level below it
    (both filter kernels sum to 1), so summing `n` levels into level 0 makes
    level 0 hold `n` times the light the scene actually had -- a flat bright
    wall comes out of a 6-level chain half again as bright as out of a 4-level
    one, and `Bloom.intensity` stops meaning anything fixed. Mixing keeps the
    total at exactly one copy however many levels there are, so `levels`
    controls how *wide* the bloom is and `intensity` controls how *strong*,
    which is the pair of knobs a game can actually reason about. It also makes
    a real property to test against: a constant image comes out of the chain
    as the same constant.

    It is also why this pass's own render pass loads rather than discarding --
    the destination's existing value is half the answer. See `bloom_pass`
    (bloom.odin).

    Must match matchbox.Bloom_Filter_Frag_Data.
*/

#include "bloom.hlsli"

cbuffer FragData : register(b0, space3)
{
    float2 texel;   // one texel of the source (the *smaller*) level, in uv
    float  scatter; // how much of this level is the blurrier one below it
    float  _pad;
};

Texture2D<float4> tex : register(t0, space2);
SamplerState      smp : register(s0, space2);

float4 main(float4 pos : SV_Position, float2 uv : TEXCOORD0) : SV_Target0
{
    // The alpha is the blend weight, not a coverage -- see this file's own
    // top comment. Nothing downstream ever reads a bloom level's alpha
    // channel, so writing it is free.
    return float4(bloom_upsample_tent(tex, smp, uv, texel), scatter);
}
