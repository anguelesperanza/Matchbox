/*
    Lines, in the colour they were asked for and nothing else.

    Shares mesh.vert with the solid pipeline, so a line vertex carries a normal
    it does not use -- one vertex layout for all 3D geometry is worth more than
    the eight bytes it saves to have two.

    No shading on purpose. A wireframe is an annotation rather than a surface:
    it marks where an edge or a bounding box is, and a lit one goes dim exactly
    where it is being read.

    ---

    The depth write is the interesting part.

    A wireframe is nearly always drawn over the very surface it outlines --
    `draw_cube` then `draw_cube_wires` at the same place is why both exist -- and
    an edge line sits at exactly the depth of the faces meeting at that edge.
    Rasterised separately, the line's interpolated depth and the triangle's
    differ by a few floating-point ulps in either direction, so the depth test
    becomes a coin toss decided per pixel: the outline comes out as a dashed line
    that crawls as the camera moves.

    The obvious fix is `enable_depth_bias` on the pipeline, and it was tried
    first. It does nothing here: depth bias is specified for polygons, and a line
    list is not one, so the state is accepted and quietly ignored.

    What does work is moving the fragment itself. SV_Depth costs this pipeline
    its early-z, which for a few thousand line pixels is not worth measuring, and
    it is the one place the offset can be applied where it certainly happens.

    Declares only the field it actually reads, `tint` -- `draw_model_immediate`
    pushes the full `matchbox.Material_Frag_Data` for every part regardless of
    pipeline, and a cbuffer smaller than what was pushed simply leaves the
    rest unread. `tint` is that struct's first field, so this still lines up.
*/
cbuffer FragData : register(b0, space3)
{
    float4 tint;
};

struct PSInput
{
    float4 pos    : SV_Position;
    float3 normal : TEXCOORD0;
    float3 uv     : TEXCOORD1; // uv * q, q -- see psx_uv (psx_geometry.hlsli)
    float3 world  : TEXCOORD2;
};

struct PSOutput
{
    float4 color : SV_Target0;
    float  depth : SV_Depth;
};

PSOutput main(PSInput input)
{
    PSOutput output;
    output.color = tint;

    // Towards the camera, which is downwards: the projections in math3d.odin put
    // the near plane at 0 and the depth test is LESS.
    //
    // Small enough to be invisible -- a few hundred ulps of a 24-bit buffer --
    // and large enough to beat the ulp or two of disagreement between a line and
    // a triangle that share an edge. Clamped, because a line drawn at the near
    // plane would otherwise be pushed behind it and vanish.
    const float bias = 0.00002;
    output.depth = max(input.pos.z - bias, 0.0);

    return output;
}
