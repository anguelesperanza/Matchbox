#ifndef MATCHBOX_BLOOM_HLSLI
#define MATCHBOX_BLOOM_HLSLI

/*
    Bloom -- the two filter kernels, shared by the three passes
    -----------------------------------------------------------
    `bloom_prefilter.frag.hlsl` and `bloom_downsample.frag.hlsl` both shrink
    an image by half, and `bloom_upsample.frag.hlsl` grows one back; the only
    thing that separates the first two is that one of them also applies the
    brightness knee. So the kernels live here rather than being written out
    three times, the same relationship `brdf/pbr_common.hlsli` has to the two
    PBR models -- a plain function library neither dispatcher knows about,
    not a module behind a contract.

    **Why two kernels and not one blur.** A gaussian wide enough to look like
    bloom at full resolution is hundreds of taps. Halving the image five times
    and adding the results back up gets a much wider skirt for a fraction of
    the work, because each level's own small kernel covers twice the screen
    distance the level below it did. The pair below is the one nearly every
    engine uses for it (the "dual filtering" chain Sledgehammer's Advanced
    Warfare talk popularised): a 13-tap on the way down, a 3x3 tent on the way
    back up. They are not interchangeable -- a box on the way up leaves visible
    square blocks at each level boundary, which is the artifact the tent exists
    to remove.

    **Both kernels sum to exactly 1**, which is the property `post_test.odin`
    asserts rather than assumes: a constant image has to survive the whole
    chain as the same constant, or bloom would brighten or dim a flat wall
    just for being flat. The weights are written as literals here and mirrored
    as literals in `bloom.odin` so that test has two independently-typed copies
    to compare, rather than one copy checked against itself.

    `texel` is one texel of the *source* image in uv units -- 1/width, 1/height
    of whatever texture is bound, never of the destination. The two differ by a
    factor of two in every pass here, and using the wrong one is a blur at half
    or twice the intended radius, which looks plausible rather than broken.
*/

/*
    13 taps in five overlapping boxes, weighted so the four inner taps carry
    half the result. The offsets are in source texels; sampled with a linear
    sampler, each tap is already the average of the four texels around it, so
    this reads 52 texels' worth of image for 13 samples.

        a . b . c
        . j . k .
        d . e . f
        . l . m .
        g . h . i

    Weights: e 1/8, the four corners (a c g i) 1/32 each, the four edge
    midpoints (b d f h) 1/16 each, the four inner (j k l m) 1/8 each.
    1/8 + 4/32 + 4/16 + 4/8 = 1.
*/
float3 bloom_downsample_13(Texture2D<float4> tex, SamplerState smp, float2 uv, float2 texel)
{
    float3 a = tex.Sample(smp, uv + float2(-2, -2) * texel).rgb;
    float3 b = tex.Sample(smp, uv + float2( 0, -2) * texel).rgb;
    float3 c = tex.Sample(smp, uv + float2( 2, -2) * texel).rgb;

    float3 d = tex.Sample(smp, uv + float2(-2,  0) * texel).rgb;
    float3 e = tex.Sample(smp, uv                          ).rgb;
    float3 f = tex.Sample(smp, uv + float2( 2,  0) * texel).rgb;

    float3 g = tex.Sample(smp, uv + float2(-2,  2) * texel).rgb;
    float3 h = tex.Sample(smp, uv + float2( 0,  2) * texel).rgb;
    float3 i = tex.Sample(smp, uv + float2( 2,  2) * texel).rgb;

    float3 j = tex.Sample(smp, uv + float2(-1, -1) * texel).rgb;
    float3 k = tex.Sample(smp, uv + float2( 1, -1) * texel).rgb;
    float3 l = tex.Sample(smp, uv + float2(-1,  1) * texel).rgb;
    float3 m = tex.Sample(smp, uv + float2( 1,  1) * texel).rgb;

    return e * 0.125
         + (a + c + g + i) * 0.03125
         + (b + d + f + h) * 0.0625
         + (j + k + l + m) * 0.125;
}

/*
    A 3x3 tent -- (1 2 1; 2 4 2; 1 2 1) / 16 -- one source texel apart.

        1 2 1
        2 4 2  / 16
        1 2 1

    Read at the smaller level's own texel size, so on screen it covers twice
    the distance the level it is being added into would.
*/
float3 bloom_upsample_tent(Texture2D<float4> tex, SamplerState smp, float2 uv, float2 texel)
{
    float3 a = tex.Sample(smp, uv + float2(-1, -1) * texel).rgb;
    float3 b = tex.Sample(smp, uv + float2( 0, -1) * texel).rgb;
    float3 c = tex.Sample(smp, uv + float2( 1, -1) * texel).rgb;

    float3 d = tex.Sample(smp, uv + float2(-1,  0) * texel).rgb;
    float3 e = tex.Sample(smp, uv                          ).rgb;
    float3 f = tex.Sample(smp, uv + float2( 1,  0) * texel).rgb;

    float3 g = tex.Sample(smp, uv + float2(-1,  1) * texel).rgb;
    float3 h = tex.Sample(smp, uv + float2( 0,  1) * texel).rgb;
    float3 i = tex.Sample(smp, uv + float2( 1,  1) * texel).rgb;

    return (e * 4.0 + (b + d + f + h) * 2.0 + (a + c + g + i)) * 0.0625;
}

#endif // MATCHBOX_BLOOM_HLSLI
