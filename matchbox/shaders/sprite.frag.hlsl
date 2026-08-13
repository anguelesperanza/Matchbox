/*
    Textured quad. Was test.frag.

    No uniforms at all, and no flipping. This used to take flip_x/flip_y and
    do `1 - uv`, which is wrong for anything drawing part of a sheet: the uv
    arriving here has already been narrowed to one tile by the vertex shader,
    so reflecting it around 0.5 reflects it around the middle of the whole
    atlas and lands in a different frame. On a four column sheet, frame 1 runs
    0.25..0.5 and a pixel at 0.30 came out at 0.70 -- frame 2.

    Flipping is a swap of uv_min and uv_max, which the caller already knows how
    to do and animation.odin was already doing to work around this. Now
    draw_sprite does the same and the shader has nothing left to get wrong.
*/
Texture2D<float4> tex : register(t0, space2);
SamplerState      smp : register(s0, space2);

float4 main(float4 pos : SV_Position, float2 uv : TEXCOORD0) : SV_Target0
{
    return tex.Sample(smp, uv);
}
