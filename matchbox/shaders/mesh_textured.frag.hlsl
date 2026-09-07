/*
    A textured surface, which is what a loaded model usually is, lit.

    The tint multiplies the sampled colour rather than replacing it, so WHITE
    leaves a model as it was painted and anything else shades it -- matching
    what `tint` already means for a sprite.

    Must match matchbox.Mesh_Frag_Data and matchbox.Lighting_Data.
*/

// Sampled textures in order: this one first (the model's own base colour),
// then the two shadow maps -- see lighting.hlsli's own comment on why they
// are declared here rather than inside that shared header.
Texture2D<float4> tex : register(t0, space2);
SamplerState      smp : register(s0, space2);

Texture2D<float>       shadow_map0     : register(t1, space2);
SamplerComparisonState shadow_sampler0 : register(s1, space2);
Texture2D<float>       shadow_map1     : register(t2, space2);
SamplerComparisonState shadow_sampler1 : register(s2, space2);

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
    float4 albedo = tex.Sample(smp, input.uv) * tint;

    return apply_lighting(input.normal, input.world, albedo);
}
