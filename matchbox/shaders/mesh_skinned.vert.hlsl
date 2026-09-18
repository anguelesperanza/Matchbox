/*
    The skinned 3D vertex shader: mesh.vert with a skeleton in front of it.

    Everything after the skinning is mesh.vert unchanged -- the same three
    matrices, the same normal handling, the same outputs -- so the fragment
    shaders do not know or care which vertex shader fed them, and a skinned
    model is lit, fogged and textured by exactly the code an unskinned one is.

    Uniform layout must match matchbox.Mesh_Vert_Data exactly: 208 bytes in
    b0. Skin_Vert_Data in b1 is one uint now -- see below.
*/
#pragma pack_matrix(column_major)

#include "psx_geometry.hlsli"

cbuffer Mesh_Vert_Data : register(b0, space1)
{
    float4x4 mvp;
    float4x4 model;
    float4x4 normal_matrix;

    float2   snap_grid;     // Psx_Geometry: cells to snap to, or zero for off
    float    affine;        // Psx_Geometry: 1 for affine texture mapping
    float    _pad;
};

/*
    One matrix per joint, already the product of the joint's global transform
    and its inverse bind matrix -- see animator_resolve. The shader does no
    hierarchy walking: by the time a matrix arrives here it is the whole answer
    for that joint, and all that is left is the weighted sum.

    A storage buffer, not a uniform -- SDL's Vulkan backend binds a uniform
    with range capped at exactly 64 matrices regardless of what is pushed,
    which is undefined past that point on Vulkan and merely zero on D3D12.
    That asymmetry is why the same file once skinned correctly on Windows and
    threw geometry across the room on Linux; see `refactor.md`. A storage
    buffer has no such cap.

    One buffer holds every skinned part of one character back to back, not
    one palette each -- `joint_offset` below is which slice is this part's.
    `t0, space0` is SDL_GPU's fixed HLSL slot for a vertex stage's first
    storage buffer, the same way vertex uniforms are always `space1`.
*/
StructuredBuffer<float4x4> joints : register(t0, space0);

// Where this part's palette starts in `joints`. Every vertex's `joint` field
// below is local to the part (0..joint_map count-1 on the Odin side); this is
// what turns that back into a real index into the shared buffer.
cbuffer Skin_Vert_Data : register(b1, space1)
{
    uint joint_offset;
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
    float3 uv     : TEXCOORD1; // uv * q, q -- see psx_uv
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
        input.weight.x * joints[joint_offset + input.joint.x] +
        input.weight.y * joints[joint_offset + input.joint.y] +
        input.weight.z * joints[joint_offset + input.joint.z] +
        input.weight.w * joints[joint_offset + input.joint.w];

    float4 skinned_pos    = mul(skin, float4(input.pos, 1.0));
    float3 skinned_normal = mul(skin, float4(input.normal, 0.0)).xyz;

    VSOutput output;

    // Snapped for where it lands on screen and nothing else: `world` below is
    // the unsnapped point, so lighting, fog and shadow lookups do not wobble
    // with the edges. The shadow pass pushes a zero grid -- see draw_model_immediate.
    output.pos   = psx_snap(mul(mvp, float4(skinned_pos.xyz, 1.0)), snap_grid);
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
    output.uv     = psx_uv(input.uv, output.pos, affine);

    return output;
}
