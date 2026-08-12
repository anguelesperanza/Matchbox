// Flat colour, no texture. Must match matchbox.Rect_Frag_Data.
cbuffer FragData : register(b0, space3)
{
    float4 color;
};

float4 main(float4 pos : SV_Position, float2 uv : TEXCOORD0) : SV_Target0
{
    return color;
}
