// Glyph from the baked atlas. The atlas is white RGB with the coverage mask in
// alpha, so the colour comes wholly from the uniform and only alpha is sampled.
// Must match matchbox.FontFragData.
Texture2D<float4> tex : register(t0, space2);
SamplerState      smp : register(s0, space2);

cbuffer FragData : register(b0, space3)
{
    float4 color;
};

float4 main(float4 pos : SV_Position, float2 uv : TEXCOORD0) : SV_Target0
{
    float4 sampled = tex.Sample(smp, uv);
    return float4(color.rgb, color.a * sampled.a);
}
