/*
    The skybox vertex shader, which reads no geometry at all.

    Three vertices generated from SV_VertexID, covering the screen as one
    oversized triangle rather than two triangles making a quad. There is no
    vertex buffer, no index buffer and nothing to bind: the draw is
    DrawGPUPrimitives(pass, 3, 1, 0, 0) and the pipeline declares zero vertex
    buffers.

    One triangle rather than two because the diagonal seam of a quad is drawn
    twice, and because a sky needs no interpolated attribute that a triangle
    cannot carry. The parts hanging off the screen are clipped and cost nothing.

    What it hands the fragment shader is a direction, not a coordinate. The
    camera's basis arrives already scaled by the field of view, so the ray
    through a pixel is the sum of the three -- which is the projection matrix
    undone without inverting anything.
*/
#pragma pack_matrix(column_major)

cbuffer Skybox_Vert_Data : register(b0, space1)
{
    float4 ray_right;   // camera right, scaled by tan(fov/2) * aspect
    float4 ray_up;      // camera up, scaled by tan(fov/2)
    float4 ray_forward; // camera forward, unit length
};

struct VSOutput
{
    float4 pos : SV_Position;
    float3 dir : TEXCOORD0;
};

VSOutput main(uint id : SV_VertexID)
{
    // (0,0), (2,0), (0,2) -> clip (-1,-1), (3,-1), (-1,3).
    float2 uv  = float2((id << 1) & 2, id & 2);
    float2 ndc = uv * 2.0 - 1.0;

    VSOutput output;

    // z of zero and w of one puts it on the near plane, which is where nothing
    // else is. It does not matter: the pipeline neither tests nor writes depth,
    // and the sky is drawn before anything that does.
    output.pos = float4(ndc, 0.0, 1.0);

    // Not normalised here. Interpolating three unit vectors across a triangle
    // does not give unit vectors in the middle, so the fragment shader has to
    // normalise anyway and doing it twice is one wasted rsqrt per vertex.
    output.dir = ray_forward.xyz + ray_right.xyz * ndc.x + ray_up.xyz * ndc.y;

    return output;
}
