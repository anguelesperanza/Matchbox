/*
    Tape. Barrel curve, wobble, a tracking band, chroma smear, ghosting, grain,
    head-switching noise at the bottom, and a vignette.

    Ported from PsxGame's vhs.fs, step for step and constant for constant. The
    numbers are the whole character of it -- how far the chroma smears, how
    often the tracking band moves, how much the brightness swells -- so none of
    them were tidied on the way across.

    Everything animated is driven from `time` through sines that do not divide
    into each other, which is what keeps it drifting rather than strobing.

    Must match matchbox.Post_Frag_Data.
*/
cbuffer FragData : register(b0, space3)
{
    float2 resolution;
    float2 grid; // unused here; PSX wants it
    float  time;
    float3 _pad;
};

Texture2D<float4> tex : register(t0, space2);
SamplerState      smp : register(s0, space2);

float hash1(float n)
{
    return frac(sin(n) * 43758.5453);
}

float hash2(float2 p)
{
    return frac(sin(dot(p, float2(127.1, 311.7))) * 43758.5453);
}

float4 main(float4 pos : SV_Position, float2 uv : TEXCOORD0) : SV_Target0
{
    float2 center = uv - 0.5;

    // 1. Barrel distortion, for the curve of the glass.
    float barrel = dot(center, center) * 0.04;
    uv += center * barrel;

    // 2. Tape warp: two slow sines on x, no randomness, so it waves rather
    //    than jitters.
    float wobble = sin(uv.y * 6.0  + time * 0.7)  * 0.0007
                 + sin(uv.y * 14.0 - time * 0.45) * 0.0004;
    uv.x += wobble;

    // 3. A tracking band that picks a new place two or three times a second.
    float g_t     = floor(time * 2.5);
    float g_y     = hash1(g_t * 13.7);
    float g_width = 0.03 + hash1(g_t * 5.1) * 0.04;
    float g_shift = (hash1(g_t * 9.3) - 0.5) * 0.018;
    uv.x += smoothstep(g_width, 0.0, abs(uv.y - g_y)) * g_shift;

    // 4. Chroma smear. Tape records colour at a lower bandwidth than
    //    brightness, so red and blue blur sideways and green stays sharp.
    float cs = 0.0025;
    float3 col;
    col.g = tex.Sample(smp, uv).g;
    col.r = (tex.Sample(smp, uv).r
           + tex.Sample(smp, uv - float2(cs,       0.0)).r
           + tex.Sample(smp, uv - float2(cs * 2.0, 0.0)).r) / 3.0;
    col.b = (tex.Sample(smp, uv).b
           + tex.Sample(smp, uv + float2(cs,       0.0)).b
           + tex.Sample(smp, uv + float2(cs * 2.0, 0.0)).b) / 3.0;

    // 5. A faint echo of the signal, offset to the right.
    col += tex.Sample(smp, uv + float2(0.018, 0.0)).rgb * 0.04;

    // 6. Warm and slightly desaturated, the way tape ages.
    float luma = dot(col, float3(0.299, 0.587, 0.114));
    col  = lerp(col, luma.xxx, 0.15);
    col *= float3(1.04, 1.00, 0.90);

    // 7. Brightness swell from tape speed. Two slow sines, a few percent.
    float swell = 1.0 + sin(time * 0.6) * 0.015 + sin(time * 1.1) * 0.008;
    col *= swell;

    // 8. Scanlines, off the real resolution rather than the coarse grid.
    float scan = sin(uv.y * resolution.y * 3.14159);
    col *= 1.0 - 0.07 * (0.5 + 0.5 * scan);

    // 9. Grain that updates ten times a second, two pixels across, so it
    //    crawls instead of fizzing.
    float  g_frame = floor(time * 10.0);
    float2 g_coord = floor(uv * resolution / 2.0);
    float  grain   = hash2(g_coord + g_frame * float2(73.1, 91.7));
    col += (grain - 0.5) * 0.016;

    // 10. Head-switching noise, in the strip at the very bottom.
    float head_mask  = smoothstep(0.95, 1.0, uv.y);
    float head_noise = hash2(float2(floor(uv.x * 50.0), floor(time * 25.0)));
    col = lerp(col, (head_noise * 0.2).xxx, head_mask * 0.75);

    // 11. Vignette.
    col *= smoothstep(0.82, 0.30, length(center));

    return float4(saturate(col), 1.0);
}
