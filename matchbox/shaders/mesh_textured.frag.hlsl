/*
    A textured surface, which is what a loaded model usually is, lit.

    The tint multiplies the sampled colour rather than replacing it, so WHITE
    leaves a model as it was painted and anything else shades it -- matching
    what `tint` already means for a sprite.

    Must match matchbox.Mesh_Frag_Data and matchbox.Lighting_Data.
*/
#include "lighting.hlsli"

cbuffer FragData : register(b0, space3)
{
    float4 tint;
};

Texture2D<float4> tex : register(t0, space2);
SamplerState      smp : register(s0, space2);

struct PSInput
{
    float4 pos    : SV_Position;
    float3 normal : TEXCOORD0;
    float2 uv     : TEXCOORD1;
    float3 world  : TEXCOORD2;
};

float4 main(PSInput input) : SV_Target0
{
    float4 albedo = tex.Sample(smp, input.uv) * tint;

    return apply_lighting(input.normal, input.world, albedo);
}
