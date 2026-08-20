/*
    An untextured surface in one colour, lit.

    The shading lives in lighting.hlsli, shared with mesh_textured. With no
    lights configured it is the fixed direction stages 1 to 4 used, so every
    scene written before this still looks like itself.

    Must match matchbox.Mesh_Frag_Data and matchbox.Lighting_Data.
*/
#include "lighting.hlsli"

cbuffer FragData : register(b0, space3)
{
    float4 tint;
};

struct PSInput
{
    float4 pos    : SV_Position;
    float3 normal : TEXCOORD0;
    float2 uv     : TEXCOORD1;
    float3 world  : TEXCOORD2;
};

float4 main(PSInput input) : SV_Target0
{
    return apply_lighting(input.normal, input.world, tint);
}
