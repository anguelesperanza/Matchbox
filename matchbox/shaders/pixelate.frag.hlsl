/*
    Coarse pixels and nothing else: the first step of psx.frag without the
    dither, the 15-bit colour or the scanlines. For a game that wants a low
    resolution look without it reading as a television.

    A separate shader rather than a switch in psx.frag, because every step
    psx.frag takes after the snap is one this does not take -- a uniform
    turning off three of its four steps would be a second effect living
    inside the first.

    Like psx.frag, the image is sampled on the grid rather than rendered at
    it, so it costs a full-resolution scene and saves nothing -- see draw_post.

    Must match matchbox.Post_Frag_Data.
*/
cbuffer FragData : register(b0, space3)
{
    float2 resolution; // unused here; the grid is in cells, not pixels
    float2 grid;       // the coarse grid to snap to
    float  time;       // unused here; VHS wants it
    float3 _pad;
};

Texture2D<float4> tex : register(t0, space2);
SamplerState      smp : register(s0, space2);

float4 main(float4 pos : SV_Position, float2 uv : TEXCOORD0) : SV_Target0
{
    // The centre of this cell, through a nearest sampler -- the same snap
    // psx.frag opens with, so the two effects cut an image into the same cells
    // for the same grid, and Psx_Geometry's vertex snap lands on their corners.
    float2 cell    = floor(uv * grid);
    float2 cell_uv = (cell + 0.5) / grid;

    return float4(tex.Sample(smp, cell_uv).rgb, 1.0);
}
