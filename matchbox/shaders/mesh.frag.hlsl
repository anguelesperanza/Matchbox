/*
    The one fragment shader for a solid mesh part, textured or not.

    Before this rework there were two of these -- mesh_flat and mesh_textured
    -- differing only in whether they sampled a base-colour texture. That
    forced lighting.hlsli's ugliest comment, the one explaining that the two
    shadow maps sat at t0/t1 in one and t1/t2 in the other, and it forced
    draw_model_immediate to compute `shadow_slot: u32 = 1 if textured else 0`
    to match. Binding a 1x1 white default texture for an untextured part
    (Renderer.default_texture, init.odin) removes all of it: every one of the
    four textures below is always bound to something, so the shadow maps
    always sit at t4/t5 and the two shaders collapse into this one.

    Must match matchbox.Material_Frag_Data and matchbox.Scene_Frag_Data.
*/

Texture2D<float4> tex : register(t0, space2);
SamplerState      smp : register(s0, space2);

// Metallic-roughness, occlusion and emissive -- read into Surface below the
// same way `tex`/`smp` already were. One sampler state per texture even
// though every one of them is, in practice, the same nearest-neighbour
// sampler (matchbox.resolve_texture's own doc comment says why) -- HLSL
// samplers are declared per texture regardless, so there is no shorter way
// to write this that SDL_GPU's binding model would accept.
Texture2D<float4> metal_rough_tex : register(t1, space2);
SamplerState      metal_rough_smp : register(s1, space2);
Texture2D<float4> occlusion_tex   : register(t2, space2);
SamplerState      occlusion_smp   : register(s2, space2);
Texture2D<float4> emissive_tex    : register(t3, space2);
SamplerState      emissive_smp    : register(s3, space2);

Texture2D<float>       shadow_map0     : register(t4, space2);
SamplerComparisonState shadow_sampler0 : register(s4, space2);
Texture2D<float>       shadow_map1     : register(t5, space2);
SamplerComparisonState shadow_sampler1 : register(s5, space2);

/*
    CASCADED's up to MAX_SHADOW_CASTERS(2) * MAX_CASCADES(4) maps, and CUBE's
    six -- fixed-size HLSL resource arrays rather than one declaration per
    map, which is what lets `render3d.odin`'s own binding code stay two
    `BindGPUFragmentSamplers` calls (one contiguous range each) regardless of
    `MAX_CASCADES`, the same shape the two PCF/PCSS slots just above already
    use for `MAX_SHADOW_CASTERS`. Always declared and always bound to
    *something* valid (real maps or `init`'s 1x1 placeholders) whether or not
    this game's scene ever selects `CASCADED` or ever has a point light
    casting a cube shadow -- see `Shadow_State`'s own doc comment (shadow.odin)
    for why the one shared fragment shader cannot pick and choose which
    slots to declare per technique.
*/
Texture2D<float>       cascade_maps[8]     : register(t6, space2);
SamplerComparisonState cascade_samplers[8] : register(s6, space2);
Texture2D<float>       cube_maps[6]        : register(t14, space2);
SamplerComparisonState cube_samplers[6]    : register(s14, space2);

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
    float4 sampled      = tex.Sample(smp, input.uv);
    float4 metal_rough  = metal_rough_tex.Sample(metal_rough_smp, input.uv);
    float  occlusion_tx = occlusion_tex.Sample(occlusion_smp, input.uv).r;
    float3 emissive_tx  = emissive_tex.Sample(emissive_smp, input.uv).rgb;

    Surface surface;
    surface.position      = input.world;
    surface.normal        = normalize(input.normal);
    surface.view           = normalize(view_pos.xyz - input.world);
    surface.base_color    = sampled.rgb * base_color.rgb * tint.rgb;
    surface.alpha         = sampled.a * base_color.a * tint.a;

    // glTF's own packing: roughness in green, metalness in blue -- red and
    // alpha are unused by the metallic-roughness texture itself, though red
    // doubles as occlusion when occlusionTexture names the same image (see
    // matchbox.read_material's own comment on that sharing). factor * texture
    // is the spec's own combine, so a part with no metallic-roughness texture
    // reads its factor unchanged: the default texture bound in its place
    // (Renderer.default_texture, init.odin) is white, and white is 1.0.
    surface.metallic      = params.x * metal_rough.b;
    surface.roughness     = params.y * metal_rough.g;

    surface.specular      = specular.rgb;
    surface.glossiness    = specular.a;

    // Same factor * texture combine as metallic-roughness above, and the
    // same reason a missing texture must not read as black: a material with
    // an emissive factor and no emissive texture -- every emissive material
    // create_material_pbr_metallic builds, since it has no texture parameter
    // at all -- would otherwise go dark the moment a mesh pipeline started
    // sampling this slot.
    surface.emissive      = emissive.rgb * emissive_tx;

    // glTF's occlusion is a plain texture sample with no factor to multiply
    // against (matchbox.read_material's own doc comment on why
    // occlusionTexture.strength is not read) -- the red channel is the whole
    // answer, and 1.0 (a missing texture's default) means "no occlusion",
    // exactly the constant this used to be hardcoded to.
    surface.occlusion     = occlusion_tx;

    surface.subsurface    = subsurface.rgb;
    surface.thickness     = subsurface.a;
    surface.shading_model = uint(shading.x);
    surface.bands         = params.z;
    surface.rim           = params.w;

    return shade_surface(surface);
}
