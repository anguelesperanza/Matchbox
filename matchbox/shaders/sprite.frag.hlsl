// Textured quad. Was test.frag.
Texture2D<float4> tex : register(t0, space2);
SamplerState      smp : register(s0, space2);

// Must match matchbox.FragData. The texture and sampler ids the old bindless
// version carried here are gone -- they are bound to the pass instead.
cbuffer FragData : register(b0, space3)
{
    uint   flip_x;
    uint   flip_y;
    float2 _pad;
};

float4 main(float4 pos : SV_Position, float2 uv : TEXCOORD0) : SV_Target0
{
    float2 uv_final = uv;
    if (flip_x != 0) uv_final.x = 1.0 - uv_final.x;
    if (flip_y != 0) uv_final.y = 1.0 - uv_final.y;
    return tex.Sample(smp, uv_final);
}
