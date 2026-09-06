/*
    The skinned 3D vertex shader: mesh.vert with a skeleton in front of it.

    Everything after the skinning is mesh.vert unchanged -- the same three
    matrices, the same normal handling, the same outputs -- so the fragment
    shaders do not know or care which vertex shader fed them, and a skinned
    model is lit, fogged and textured by exactly the code an unskinned one is.

    Uniform layout must match matchbox.Mesh_Vert_Data and matchbox.Skin_Vert_Data
    exactly: 192 bytes in b0, then 8192 bytes of joint matrices in b1.
*/
#pragma pack_matrix(column_major)

cbuffer Mesh_Vert_Data : register(b0, space1)
{
    float4x4 mvp;
    float4x4 model;
    float4x4 normal_matrix;
};

// One matrix per joint, already the product of the joint's global transform and
// its inverse bind matrix -- see animator_resolve. The shader does no hierarchy
// walking: by the time a matrix arrives here it is the whole answer for that
// joint, and all that is left is the weighted sum.
cbuffer Skin_Vert_Data : register(b1, space1)
{
    float4x4 joints[128];
};

struct VSInput
{
    float3 pos     : TEXCOORD0;
    float3 normal  : TEXCOORD1;
    float2 uv      : TEXCOORD2;
    uint4  joint   : TEXCOORD3;
    float4 weight  : TEXCOORD4;
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
    /*
        The weighted sum of the four joint matrices, built as a matrix rather
        than by transforming the position four times. It costs the same for the
        position and half as much once the normal is transformed by it too --
        and it keeps the two using provably the same deformation, which four
        separate sums would only do by coincidence.

        The weights are used as they arrive, because they were normalised at
        load -- see `read_weights` in model_skin_load.odin.

        This comment used to say they arrive summing to one because glTF
        requires it and every exporter honours it. That was wrong, and the way
        it was wrong is worth keeping: a file may carry WEIGHTS_1, a second set
        of four influences that Matchbox does not read, so a vertex with five
        influences reaches here summing to less than one through no fault of
        the exporter. This sum is used unscaled, so such a vertex lands at `s`
        times its correct position -- dragged toward the model's origin, which
        on a character is on the ground between the feet.

        Normalising is still the wrong thing to do *here*: it is a divide on
        every vertex of every frame to fix something that cannot change after
        load.
    */
    float4x4 skin =
        input.weight.x * joints[input.joint.x] +
        input.weight.y * joints[input.joint.y] +
        input.weight.z * joints[input.joint.z] +
        input.weight.w * joints[input.joint.w];

    float4 skinned_pos    = mul(skin, float4(input.pos, 1.0));
    float3 skinned_normal = mul(skin, float4(input.normal, 0.0)).xyz;

    VSOutput output;

    output.pos   = mul(mvp,   float4(skinned_pos.xyz, 1.0));
    output.world = mul(model, float4(skinned_pos.xyz, 1.0)).xyz;

    /*
        The skin matrix goes on the normal before the model's normal matrix
        does. Strictly the inverse transpose of the skin belongs here rather
        than the skin itself, and the difference shows only under a joint
        scaled unevenly -- which a skeleton does not do, because a bone that
        squashed on one axis would tear the mesh it shares with its neighbour.
        Every rig this was written for scales uniformly or not at all, where the
        two are the same up to a length the normalize below removes.
    */
    output.normal = normalize(mul(normal_matrix, float4(skinned_normal, 0.0)).xyz);
    output.uv     = input.uv;

    return output;
}
