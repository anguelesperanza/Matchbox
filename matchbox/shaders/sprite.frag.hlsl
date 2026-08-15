/*
    Textured quad. Was test.frag.

    No flipping here. This used to take flip_x/flip_y and do `1 - uv`, which is
    wrong for anything drawing part of a sheet: the uv arriving here has already
    been narrowed to one tile by the vertex shader, so reflecting it around 0.5
    reflects it around the middle of the whole atlas and lands in a different
    frame. On a four column sheet, frame 1 runs 0.25..0.5 and a pixel at 0.30
    came out at 0.70 -- frame 2. Flipping is a swap of uv_min and uv_max, which
    the caller already knows how to do.

    What it does take is a tint. A sprite used to be drawable only exactly as it
    was painted, so dimming one meant drawing a translucent rectangle over the
    top of it -- an extra draw that can only ever darken. Must match
    matchbox.Sprite_Frag_Data.
*/
cbuffer FragData : register(b0, space3)
{
    float4 tint;       // multiplied into the sampled colour
    float  desaturate; // 0 = as painted, 1 = fully grey
    float3 _pad;
};

Texture2D<float4> tex : register(t0, space2);
SamplerState      smp : register(s0, space2);

float4 main(float4 pos : SV_Position, float2 uv : TEXCOORD0) : SV_Target0
{
    float4 c = tex.Sample(smp, uv);

    // Grey before the tint rather than after, so tinting a desaturated sprite
    // gives a picture in the tint's hue. The other order washes the tint out
    // along with everything else and there is no way back to a colour.
    float lum = dot(c.rgb, float3(0.2126, 0.7152, 0.0722));
    c.rgb = lerp(c.rgb, lum.xxx, saturate(desaturate));

    return c * tint;
}
