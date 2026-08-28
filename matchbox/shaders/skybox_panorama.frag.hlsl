/*
    An equirectangular panorama, sampled by direction.

    The projection every 360 photo and most sky generators produce: longitude
    across, latitude down, in a 2:1 image. Cheaper to author than a cube map and
    slightly more expensive to sample, because it costs an atan2 and an acos a
    pixel where a cube map costs a compare and a divide.
*/
cbuffer FragData : register(b0, space3)
{
    float4 tint;
};

Texture2D<float4> sky : register(t0, space2);
SamplerState      smp : register(s0, space2);

static const float INV_TAU = 0.15915494309; // 1 / 2pi
static const float INV_PI  = 0.31830988618;

float4 main(float4 pos : SV_Position, float3 dir : TEXCOORD0) : SV_Target
{
    float3 d = normalize(dir);

    float2 uv;

    /*
        Longitude from x and z. Matchbox's yaw 0 looks along +x and yaw grows
        toward +z, which is the same direction atan2(z, x) grows in -- so a
        feature to the viewer's right lands to the right of screen centre, and
        the panorama is not mirrored. Getting this backwards gives a sky that
        turns the wrong way, which reads as motion sickness rather than as a
        texture bug.
    */
    uv.x = atan2(d.z, d.x) * INV_TAU + 0.5;

    // Latitude. acos gives 0 straight up, which is v = 0, which is the top row
    // of the image -- the zenith, where an equirectangular projection puts it.
    uv.y = acos(clamp(d.y, -1.0, 1.0)) * INV_PI;

    return sky.Sample(smp, uv) * tint;
}
