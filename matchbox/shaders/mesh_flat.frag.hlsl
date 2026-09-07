/*
    An untextured surface in one colour, lit.

    The shading lives in lighting.hlsli, shared with mesh_textured. With no
    lights configured it is the fixed direction stages 1 to 4 used, so every
    scene written before this still looks like itself.

    Must match matchbox.Mesh_Frag_Data and matchbox.Lighting_Data.
*/

// This shader's only sampled textures -- see lighting.hlsli's own comment on
// why they are declared here, at t0/t1, rather than inside that shared header.
Texture2D<float>       shadow_map0     : register(t0, space2);
SamplerComparisonState shadow_sampler0 : register(s0, space2);
Texture2D<float>       shadow_map1     : register(t1, space2);
SamplerComparisonState shadow_sampler1 : register(s1, space2);

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
