/*
    The deferred lighting pass's own fragment shader -- P6's fullscreen
    resolve. Reads the G-buffer four targets and their own depth target,
    reconstructs the identical `Surface` `mesh.frag.hlsl` would have filled
    from interpolants, and calls the identical `shade_surface` -- see
    `lighting_rework.md` section 3.2 for the claim this shader either honours
    or breaks, and P6's own report for which it turned out to be.

    **`DEFERRED_LIGHTING_SAMPLER_COUNT` is 11** (render.odin -- gbuffer_test.odin
    pins it the same way `render_test.odin` pins `MESH_FRAG_SAMPLER_COUNT`):
    four G-buffer targets, this pass's own sampled depth target, and the six
    shadow/probe samplers `mesh.frag.hlsl` also needs (PCF/PCSS's two,
    CASCADED's array, CUBE's array, the environment probe's own two) -- base
    colour, the three material maps and the light/cluster storage buffers
    `mesh.frag.hlsl` reads are *not* read here, since the first four arrive
    through the G-buffer instead and the last three continue the t-register
    sequence past this shader's own eleven rather than mesh.frag.hlsl's ten
    (`lighting_core.hlsli`'s own `LIGHTS_T`/`CLUSTER_RANGES_T`/
    `CLUSTER_LIGHT_INDICES_T`, `#define`d below before that file is included).

    Registers t0-t3 are the G-buffer, t4 this pass's own depth, t5-t10 mirror
    mesh.frag.hlsl's own t4-t9 exactly (same types, same samplers), t11 is
    P7b's AO texture (declared in lighting_core.hlsli, not here) -- and
    t12-t14 are that file's three storage buffers, renumbered up by one to
    make room for the G-buffer's extra texture and up by one again for the AO
    one.

    **Every one of these numbers moves when a texture is added anywhere ahead
    of it**, which is the trap `lighting_rework.md`'s own repo notes call out:
    storage buffers continue the fragment stage's t-register sequence after
    all sampled textures, so a new sampler renumbers every buffer behind it in
    both shaders at once. P2d, P3b, P5 and now P7b are the precedents.
*/

#define SSAO_T 11
#define REFLECT_IRRADIANCE_T 12
#define REFLECT_PREFILTERED_T 13
#define LIGHTS_T 14
#define CLUSTER_RANGES_T 15
#define CLUSTER_LIGHT_INDICES_T 16

// See mesh.vert.hlsl's own doc comment on this pragma: this is the one
// fragment shader in the package carrying a matrix of its own
// (inverse_view_projection, below) rather than only reading one out of the
// shared Scene block the way mesh.frag.hlsl does, so it states the
// assumption explicitly instead of relying on it being dxc's default.
#pragma pack_matrix(column_major)

Texture2D<float4> gbuffer_a : register(t0, space2);
SamplerState      gbuffer_a_smp : register(s0, space2);
Texture2D<float4> gbuffer_b : register(t1, space2);
SamplerState      gbuffer_b_smp : register(s1, space2);
Texture2D<float4> gbuffer_c : register(t2, space2);
SamplerState      gbuffer_c_smp : register(s2, space2);
Texture2D<float4> gbuffer_d : register(t3, space2);
SamplerState      gbuffer_d_smp : register(s3, space2);

// This pass's own depth target (Lighting.gbuffer.depth, render.odin) -- a
// plain sampled read, not a comparison the way the shadow maps below are:
// this is "what depth did the G-buffer fill pass leave here", not "is this
// point in shadow".
Texture2D<float> gbuffer_depth : register(t4, space2);
SamplerState      gbuffer_depth_smp : register(s4, space2);

Texture2D<float>       shadow_map0     : register(t5, space2);
SamplerComparisonState shadow_sampler0 : register(s5, space2);
Texture2D<float>       shadow_map1     : register(t6, space2);
SamplerComparisonState shadow_sampler1 : register(s6, space2);

Texture2DArray<float>  cascade_maps    : register(t7, space2);
SamplerComparisonState cascade_sampler : register(s7, space2);
Texture2DArray<float>  cube_maps       : register(t8, space2);
SamplerComparisonState cube_sampler    : register(s8, space2);

Texture2DArray<float4> irradiance_map   : register(t9, space2);
SamplerState            probe_sampler0  : register(s9, space2);
Texture2DArray<float4> prefiltered_map  : register(t10, space2);
SamplerState            probe_sampler1  : register(s10, space2);

/*
    This pass's own uniform -- everything reconstructing `Surface.position`
    needs that the shared `Scene` cbuffer (`lighting_core.hlsli`) does not
    already carry. `inverse_view_projection` is the exact inverse of the
    same `view_projection` the G-buffer fill pass's own vertex shader
    (`mesh.vert`/`mesh_skinned.vert`) multiplied every vertex by --
    `pipeline_deferred.odin`'s own `draw_deferred_lighting_quad` computes it
    once, on the CPU, from `Renderer.view_projection`.

    Slot 0, the same slot `mesh.frag.hlsl`'s own `Material` cbuffer takes --
    this pass has no per-draw material, so its own first (and only) private
    uniform takes the slot a per-draw one would have.
*/
cbuffer Deferred_Lighting_Frag_Data : register(b0, space3)
{
    float4x4 inverse_view_projection;
};

#include "lighting_core.hlsli"
#include "gbuffer.hlsli"

struct PSInput
{
    float4 pos : SV_Position;
    float2 ndc : TEXCOORD0;
    float2 uv  : TEXCOORD1;
};

float4 main(PSInput input) : SV_Target0
{
    Gbuffer_Encoded g;
    g.a = gbuffer_a.Sample(gbuffer_a_smp, input.uv);
    g.b = gbuffer_b.Sample(gbuffer_b_smp, input.uv);
    g.c = gbuffer_c.Sample(gbuffer_c_smp, input.uv);
    g.d = gbuffer_d.Sample(gbuffer_d_smp, input.uv);

    // GBUFFER_EMPTY (gbuffer.hlsli) is what the G-buffer fill pass's own
    // clear leaves in every pixel it never draws into -- discard rather
    // than shade, so whatever the final HDR pass already painted there
    // (ordinarily the skybox, drawn before this quad in the same pass --
    // see pipeline_deferred.odin's own top comment) shows through
    // untouched instead of being overwritten by a bogus UNLIT-black
    // surface.
    if (g.b.z < -0.5)
        discard;

    // Position, reconstructed rather than stored -- see gbuffer.hlsli's own
    // top comment for why. NDC z comes from this pass's own sampled depth
    // target, which the G-buffer fill pass wrote at the identical
    // clip-space depth mesh.frag.hlsl's own geometry would have.
    float  depth = gbuffer_depth.Sample(gbuffer_depth_smp, input.uv).r;
    float4 clip  = float4(input.ndc, depth, 1.0);
    float4 world_h = mul(inverse_view_projection, clip);
    float3 position = world_h.xyz / world_h.w;

    float3 view = normalize(view_pos.xyz - position);

    Surface surface = gbuffer_decode(g, position, view);

    return shade_surface(surface, input.pos);
}
