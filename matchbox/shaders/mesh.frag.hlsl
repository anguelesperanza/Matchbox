/*
    The one fragment shader for a solid mesh part, textured or not.

    Before this rework there were two of these -- mesh_flat and mesh_textured
    -- differing only in whether they sampled a base-colour texture. That
    forced lighting.hlsli's ugliest comment, the one explaining that the two
    shadow maps sat at t0/t1 in one and t1/t2 in the other, and it forced
    draw_model_immediate to compute `shadow_slot: u32 = 1 if textured else 0`
    to match. Binding a 1x1 white default texture for an untextured part
    (Renderer.default_texture, init.odin) removes all of it: `tex` is always
    bound to something, so the shadow maps always sit at t1/t2 and the two
    shaders collapse into this one.

    Must match matchbox.Material_Frag_Data and matchbox.Scene_Frag_Data.
*/

Texture2D<float4> tex : register(t0, space2);
SamplerState      smp : register(s0, space2);

Texture2D<float>       shadow_map0     : register(t1, space2);
SamplerComparisonState shadow_sampler0 : register(s1, space2);
Texture2D<float>       shadow_map1     : register(t2, space2);
SamplerComparisonState shadow_sampler1 : register(s2, space2);

cbuffer Material : register(b0, space3)
{
    float4 tint;       // draw_model's own multiplier, not a material property
    float4 base_color;
    float4 specular;   // xyz specular colour (spec-gloss), w glossiness (spec-gloss)
    float4 emissive;   // xyz emissive colour,                  w specular_power (Blinn-Phong)
    float4 params;     // x metallic, y roughness, z bands (toon, P2), w rim (toon, P2)
    float4 subsurface; // xyz subsurface tint (P2),             w thickness (P2)
    float4 shading;    // x shading_model_index -- see shading.odin.  y-w unused
};

#include "lighting_core.hlsli"

struct PSInput
{
    float4 pos    : SV_Position;
    float3 normal : TEXCOORD0;
    float2 uv     : TEXCOORD1;
    float3 world  : TEXCOORD2;
};

float4 main(PSInput input) : SV_Target0
{
    float4 sampled = tex.Sample(smp, input.uv);

    Surface surface;
    surface.position      = input.world;
    surface.normal        = normalize(input.normal);
    surface.view           = normalize(view_pos.xyz - input.world);
    surface.base_color    = sampled.rgb * base_color.rgb * tint.rgb;
    surface.alpha         = sampled.a * base_color.a * tint.a;
    surface.metallic      = params.x;
    surface.roughness     = params.y;
    surface.specular      = specular.rgb;
    surface.glossiness    = specular.a;
    surface.emissive      = emissive.rgb;
    surface.occlusion     = 1.0;
    surface.subsurface    = subsurface.rgb;
    surface.thickness     = subsurface.a;
    surface.shading_model = uint(shading.x);
    surface.bands         = params.z;
    surface.rim           = params.w;

    return shade_surface(surface);
}
