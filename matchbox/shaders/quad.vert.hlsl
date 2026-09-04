// The one vertex shader. Every draw in Matchbox is the same unit quad scaled,
// rotated and placed, so sprites, rects, outlines and glyphs all come through
// here -- the old test.vert and font.vert had identical bodies and differed
// only in the field order of their uniform block.
//
// Uniform layout must match matchbox.Vert_Data exactly. Each float2 pair fills
// one 16-byte register: (position,size) (screen,uv_min) (uv_max,rotation,pad).
cbuffer VertData : register(b0, space1)
{
    float2 position;
    float2 size;
    float2 screen;
    float2 uv_min;
    float2 uv_max;
    float  rotation;
    float  _pad;
};

struct VSInput
{
    float3 pos : TEXCOORD0;
    float2 uv  : TEXCOORD1;
};

struct VSOutput
{
    float4 pos : SV_Position;
    float2 uv  : TEXCOORD0;
};

VSOutput main(VSInput input)
{
    VSOutput output;

    // Scale the unit quad by size, centered at origin.
    float2 local = input.pos.xy * size;

    // Rotate around the quad's center.
    float s = sin(rotation);
    float c = cos(rotation);
    float2 rotated = float2(local.x * c - local.y * s,
                            local.x * s + local.y * c);

    // Translate to world position, then to clip space.
    float2 world = rotated + position;

    // Matchbox works in screen coordinates: y grows downward from the top-left.
    // SDL3_GPU normalises clip space to the D3D convention -- y = +1 is the top
    // -- on every backend, including Vulkan, so the y term is negated here.
    // The old GLSL did not negate because it drew through raw Vulkan, where
    // clip space y already pointed down.
    float2 ndc = float2( (world.x / screen.x) * 2.0 - 1.0,
                         1.0 - (world.y / screen.y) * 2.0 );

    output.pos = float4(ndc, 0.0, 1.0);
    output.uv  = uv_min + input.uv * (uv_max - uv_min);
    return output;
}
