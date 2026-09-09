/*
    A full-screen triangle from SV_VertexID alone -- the same generating
    trick `skybox.vert.hlsl` already uses (three vertices, no buffer, the
    parts hanging off the screen clipped for free), generalized to plain
    screen-space UVs instead of a camera ray: a deferred lighting pass wants
    to sample its own G-buffer at 1:1 texel/pixel correspondence, not project
    a direction the way a sky does. P6's `deferred_lighting.frag.hlsl` is the
    first caller and, so far, the only one.

    No vertex buffer, no index buffer, no uniform buffer at all --
    `Vertex_Layout.NONE` (init.odin), zero uniform buffers passed to
    `create_builtin_shader` -- there is nothing here that depends on a model
    or a camera, only on which of the three corners `SV_VertexID` names.

    `uv` is derived from the same `corner` value `pos` is, rather than from
    `pos` after the fact: `corner` is affine in the same way `pos.xy` is (both
    are `SV_VertexID`'s own per-vertex constant), so the two interpolate
    together exactly, and the *visible*, screen-clipped part of this
    oversized triangle is exactly where `corner` -- not `pos.xy` -- already
    covers `[0, 1]`. `+V down` matches this package's own established
    convention (`shadow_sample_pcf`'s "clip +Y is up, texture +V is down",
    `shaders/shadow/pcf.hlsli`) rather than a fresh choice for this file.
*/

struct VSOutput
{
    float4 pos : SV_Position;
    float2 ndc : TEXCOORD0; // clip-space xy, exact under interpolation since every vertex has w == 1
    float2 uv  : TEXCOORD1; // 0..1 within the visible screen, +V down
};

VSOutput main(uint id : SV_VertexID)
{
    // (0,0), (2,0), (0,2) -> clip (-1,-1), (3,-1), (-1,3) -- see
    // skybox.vert.hlsl's own comment on the same bit trick.
    float2 corner = float2((id << 1) & 2, id & 2);
    float2 ndc    = corner * 2.0 - 1.0;

    VSOutput output;
    output.pos = float4(ndc, 0.0, 1.0);
    output.ndc = ndc;
    output.uv  = float2(corner.x, 1.0 - corner.y);
    return output;
}
