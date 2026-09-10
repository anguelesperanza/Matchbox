/*
    SSAO -- taking the sampling noise off
    --------------------------------------
    A plain box blur over the AO texture `ssao.frag.hlsl` wrote.

    **Box, not gaussian, and that is the right kernel here for once.** The
    thing being removed is not detail, it is the per-pixel rotation that shader
    applies to its sampling hemisphere: every pixel takes the same number of
    taps in a *differently rotated* set of directions, so neighbouring pixels
    hold independent estimates of the same quantity. Averaging independent
    estimates of one quantity is what a box filter does exactly and what a
    gaussian does with a weighting nothing here justifies -- there is no
    frequency content to preserve, only variance to reduce.

    **Not depth-aware, deliberately.** A bilateral blur that refuses to average
    across a depth discontinuity is the usual next step, and it needs the depth
    buffer bound here as a second sampler plus a falloff constant to tune. The
    artifact it prevents -- occlusion bleeding a couple of pixels past a
    silhouette -- is small at the radii `SSAO_DEFAULTS` uses and is hard to
    judge without a frame to look at. Left as a stated gap rather than a
    guessed constant, the same call `bloom_prefilter.frag.hlsl` makes about its
    own missing firefly suppression.

    Must match matchbox.Ssao_Blur_Frag_Data.
*/

cbuffer FragData : register(b0, space3)
{
    float2 texel;  // one texel of the AO texture, in uv
    float  radius; // in texels; 2 is the 5x5 the default asks for
    float  _pad;
};

Texture2D<float> ao_map : register(t0, space2);
SamplerState     ao_smp : register(s0, space2);

float4 main(float4 pos : SV_Position, float2 uv : TEXCOORD0) : SV_Target0
{
    int r = int(radius);

    float total = 0.0;
    float count = 0.0;

    /*
        A dynamic loop bound rather than an unrolled fixed one. `radius` is a
        uniform, so every pixel in the draw takes the same path and the branch
        predicts perfectly -- the cost of a uniform loop bound is a loop, not a
        divergence. Fixing it at compile time would mean either a permutation
        per radius or taking the maximum number of taps always, and this is a
        blur of a single-channel texture, not a place worth spending either on.
    */
    for (int y = -r; y <= r; y++)
    {
        for (int x = -r; x <= r; x++)
        {
            total += ao_map.Sample(ao_smp, uv + float2(x, y) * texel).r;
            count += 1.0;
        }
    }

    // count is never zero: the loops always run at least the centre tap,
    // since a negative radius is clamped away CPU-side
    // (ssao_settings_normalized, ssao.odin) and radius 0 skips this pass
    // entirely rather than arriving here.
    return float4((total / count).xxxx);
}
