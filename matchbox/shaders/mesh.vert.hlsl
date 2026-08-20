/*
    The 3D vertex shader. Unlike quad.vert, this one reads real geometry: a
    vertex buffer belonging to the model being drawn, not the one shared quad.

    pack_matrix is stated rather than left to the compiler on purpose. Odin's
    matrix[4,4]f32 is column-major, HLSL's cbuffer default is column-major too,
    and so the two agree -- until something passes -Zpr or a future dxc changes
    its mind, at which point every matrix arrives transposed and the picture is
    wrong in a way that looks like bad maths rather than bad packing. One line
    here removes the question.

    Uniform layout must match matchbox.Mesh_Vert_Data exactly: three 64-byte
    matrices, 192 bytes.
*/
#pragma pack_matrix(column_major)

cbuffer Mesh_Vert_Data : register(b0, space1)
{
    float4x4 mvp;           // projection * view * model
    float4x4 model;         // model alone, for the world position
    float4x4 normal_matrix; // inverse transpose of model, so non-uniform scale
                            // does not shear the normals off the surface
};

struct VSInput
{
    float3 pos    : TEXCOORD0;
    float3 normal : TEXCOORD1;
    float2 uv     : TEXCOORD2;
};

struct VSOutput
{
    float4 pos    : SV_Position;
    float3 normal : TEXCOORD0;
    float2 uv     : TEXCOORD1;
    float3 world  : TEXCOORD2;
};

VSOutput main(VSInput input)
{
    VSOutput output;

    output.pos   = mul(mvp,   float4(input.pos, 1.0));
    output.world = mul(model, float4(input.pos, 1.0)).xyz;

    // w = 0, so the translation column is dropped: a normal is a direction and
    // does not move with the model.
    output.normal = normalize(mul(normal_matrix, float4(input.normal, 0.0)).xyz);
    output.uv     = input.uv;

    // No y negation, unlike quad.vert. That one flips because Matchbox measures
    // 2D from the top-left; here the projection has already put world +y where
    // it belongs.
    return output;
}
