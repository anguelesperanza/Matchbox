/*
    The G-buffer fill pass's own fragment shader -- P6's deferred pipeline.

    Fills a `Surface` from interpolants and texture samples exactly the way
    `mesh.frag.hlsl` does -- the same four material textures, the same
    factor-times-texture combine, the same defaults for a part with none of
    them (the 1x1 white `Renderer.default_texture`, bound here the same way
    it is for forward) -- and then writes it across four render targets
    instead of calling `shade_surface`. No shading happens here at all: this
    pass runs once per opaque triangle, `deferred_lighting.frag.hlsl` runs
    once per pixel, and `shade_surface` is called from exactly the one place
    it always was, just fed a `Surface` decoded from these targets instead
    of one filled from interpolants.

    Paired with `mesh.vert`/`mesh_skinned.vert`, the same way `shadow.frag`
    is -- see that shader's own comment (`Shaders.shadow`, init.odin) for why
    a vertex shader that already computes the layout a caller needs does not
    get a second copy for a different fragment stage.

    Only the four material textures are declared -- no shadow maps, no light
    buffer, no probe maps, no `Scene` cbuffer at all. A fill pass writes a
    `Surface`'s own values; it does not shade one, so none of the resources
    `shade_surface` needs are read here. This is also why this shader's own
    sampler count is nowhere near the floor `MESH_FRAG_SAMPLER_COUNT`
    (render.odin) and `DEFERRED_LIGHTING_SAMPLER_COUNT`
    (`deferred_lighting.frag.hlsl`) both have to mind.

    Must match matchbox.Material_Frag_Data -- the identical cbuffer
    `mesh.frag.hlsl` declares, since a part's material is the same 112 bytes
    regardless of which pipeline is drawing it.
*/

Texture2D<float4> tex : register(t0, space2);
SamplerState      smp : register(s0, space2);

Texture2D<float4> metal_rough_tex : register(t1, space2);
SamplerState      metal_rough_smp : register(s1, space2);
Texture2D<float4> occlusion_tex   : register(t2, space2);
SamplerState      occlusion_smp   : register(s2, space2);
Texture2D<float4> emissive_tex    : register(t3, space2);
SamplerState      emissive_smp    : register(s3, space2);

cbuffer Material : register(b0, space3)
{
    float4 tint;       // draw_model's own multiplier, not a material property
    float4 base_color;
    float4 specular;   // xyz specular colour (spec-gloss), w glossiness (spec-gloss)
    float4 emissive;   // xyz emissive colour,              w specular_power (Blinn-Phong)
    float4 params;     // x metallic, y roughness, z bands (toon), w rim (toon)
    float4 subsurface; // xyz subsurface tint,              w thickness
    float4 shading;    // x shading_model_index -- see shading.odin.  y-w unused
};

#include "surface.hlsli"
#include "brdf/contract.hlsli" // SHADING_* only -- gbuffer_encode's own switch
#include "gbuffer.hlsli"

struct PSInput
{
    float4 pos    : SV_Position;
    float3 normal : TEXCOORD0;
    float2 uv     : TEXCOORD1;
    float3 world  : TEXCOORD2; // unread here -- position is not part of the G-buffer, see gbuffer.hlsli
};

struct PSOutput
{
    float4 a : SV_Target0;
    float4 b : SV_Target1;
    float4 c : SV_Target2;
    float4 d : SV_Target3;
};

PSOutput main(PSInput input)
{
    float4 sampled      = tex.Sample(smp, input.uv);
    float4 metal_rough  = metal_rough_tex.Sample(metal_rough_smp, input.uv);
    float  occlusion_tx = occlusion_tex.Sample(occlusion_smp, input.uv).r;
    float3 emissive_tx  = emissive_tex.Sample(emissive_smp, input.uv).rgb;

    // Only the fields gbuffer_encode actually reads -- position/view/alpha
    // are not part of the G-buffer at all (gbuffer.hlsli's own top comment),
    // so this Surface is deliberately partial rather than a copy of
    // mesh.frag.hlsl's own fill.
    Surface surface = (Surface)0;

    surface.normal        = normalize(input.normal);
    surface.base_color    = sampled.rgb * base_color.rgb * tint.rgb;

    surface.metallic      = params.x * metal_rough.b;
    surface.roughness     = params.y * metal_rough.g;
    surface.specular      = specular.rgb;
    surface.glossiness    = specular.a;
    surface.emissive      = emissive.rgb * emissive_tx;
    surface.occlusion     = occlusion_tx;
    surface.subsurface    = subsurface.rgb;
    surface.thickness     = subsurface.a;
    surface.shading_model = uint(shading.x);
    surface.bands         = params.z;
    surface.rim           = params.w;
    surface.specular_power = emissive.w;

    Gbuffer_Encoded g = gbuffer_encode(surface);

    PSOutput output;
    output.a = g.a;
    output.b = g.b;
    output.c = g.c;
    output.d = g.d;
    return output;
}
