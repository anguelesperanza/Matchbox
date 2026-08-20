/*
    The PlayStation look: coarse pixels, ordered dithering, 15-bit colour, and
    scanlines. A full-screen pass over a render target.

    Ported from PsxGame's psx.fs, constant for constant.

    The image is sampled on a coarse grid rather than being *rendered* at that
    size -- see D9 in 3d.md. That is what the game already does and it is what
    a port should keep; a native low-resolution target is cheaper and a
    different picture, and changing the picture is not what this is for. The
    grid is a uniform rather than the hard-coded 320x240 the original used, so
    it can be moved without recompiling anything.

    Must match matchbox.Post_Frag_Data.
*/
cbuffer FragData : register(b0, space3)
{
    float2 resolution; // the target, in pixels
    float2 grid;       // the coarse grid to snap to -- 320x240 is a PlayStation
    float  time;       // unused here; VHS wants it
    float3 _pad;
};

Texture2D<float4> tex : register(t0, space2);
SamplerState      smp : register(s0, space2);

// A 4x4 Bayer matrix. The PlayStation dithered before reducing colour depth,
// which is why its gradients break up into a weave instead of banding -- most
// visible in shadows.
static const float bayer[16] = {
     0.0,  8.0,  2.0, 10.0,
    12.0,  4.0, 14.0,  6.0,
     3.0, 11.0,  1.0,  9.0,
    15.0,  7.0, 13.0,  5.0
};

float4 main(float4 pos : SV_Position, float2 uv : TEXCOORD0) : SV_Target0
{
    // 1. Snap to the coarse grid. Sampling the centre of each cell with a
    //    nearest sampler is what makes the pixels square rather than smeared.
    float2 cell     = floor(uv * grid);
    float2 cell_uv  = (cell + 0.5) / grid;

    float3 col = tex.Sample(smp, cell_uv).rgb;

    // 2. Ordered dither, applied before the colour is reduced.
    int    x   = (int)fmod(cell.x, 4.0);
    int    y   = (int)fmod(cell.y, 4.0);
    float  dit = bayer[y * 4 + x] / 16.0 - 0.5;

    col += dit * (2.0 / 31.0); // two steps at five bits

    // 3. Five bits a channel, which is the 15-bit colour the hardware had.
    col = floor(col * 31.0 + 0.5) / 31.0;

    // 4. One dark line every two coarse pixels, for a television.
    float scan = fmod(cell.y, 2.0);
    col *= 1.0 - 0.12 * scan;

    return float4(saturate(col), 1.0);
}
