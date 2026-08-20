/*
    A render target drawn back to the window with nothing done to it.

    Not the same as the sprite shader, though it looks like it should be: that
    one's uniform block is a tint and a desaturate, and post-processing pushes a
    resolution, a grid and a time. Two blocks of the same size and different
    meaning is exactly the mix-up that reads as a picture in the wrong colours,
    so this has its own.

    Must match matchbox.Post_Frag_Data.
*/
cbuffer FragData : register(b0, space3)
{
    float2 resolution;
    float2 grid;
    float  time;
    float3 _pad;
};

Texture2D<float4> tex : register(t0, space2);
SamplerState      smp : register(s0, space2);

float4 main(float4 pos : SV_Position, float2 uv : TEXCOORD0) : SV_Target0
{
    return float4(tex.Sample(smp, uv).rgb, 1.0);
}
