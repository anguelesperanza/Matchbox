Texture2D tex : register(t0);
SamplerState smp : register(s0);


cbuffer Frame : register(b0){
    float4x4 view_projection;
};

cbuffer Draw : register(b1) {
    float4x4 model;
    float4 tint;
};

struct VS_Input {
    float3 position : position;
    float2 uv : texcoord;
    float4 color : color;
};


// V2P -> Vertex to Pixel
struct V2P {
    float4 position : SV_POSITION;
    float4 color: COLOR;
    float2 uv : TEXCOORD;
};

V2P vertex_main(VS_Input input) {
    V2P output;

    float4 world = mul(model, float4(input.position, 1.0));
    output.position = mul(view_projection, world);
    output.color = input.color * tint;
    output.uv = input.uv;
    return output;
}

float4 pixel_main(V2P input) : SV_TARGET {
    return tex.Sample(smp, input.uv) * input.color;
}
