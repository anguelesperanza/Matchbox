/*
    A cube map, sampled by direction.

    Six square faces, and the hardware does the face selection and the
    projection -- which is why this is three lines where the panorama is a
    handful of transcendentals.
*/
cbuffer FragData : register(b0, space3)
{
    float4 tint;
};

TextureCube<float4> sky : register(t0, space2);
SamplerState        smp : register(s0, space2);

float4 main(float4 pos : SV_Position, float3 dir : TEXCOORD0) : SV_Target
{
    float3 d = normalize(dir);

    /*
        The x is negated, and it is not optional.

        Cube map sampling is defined left-handed -- it is the one place the
        convention survived from Direct3D into every API since, Vulkan
        included. Matchbox's world is right-handed: looking along +z, the
        camera's right is -x, where the cube map's +Z face puts +x to the right
        of the image. Feeding the world direction in unchanged gives a sky that
        is mirrored, which is invisible on clouds and obvious the moment
        anything in it has a shape you recognise.

        Negating x here rather than swapping the faces at upload keeps
        `load_skybox_cubemap` slicing the cross by the labels the cross is drawn
        with, which is the thing a person can check against the file.
    */
    return sky.Sample(smp, float3(-d.x, d.y, d.z)) * tint;
}
