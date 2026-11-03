Texture2D tex: register(t0); // slot 0 => PSSetShaderResources(0, ...)
SamplerState smp : register(s0); // slot 0 => PSSetSamplers(0, ...)

cbuffer Constants: register(b0) {
    float2 viewport_size;
    float2 _padding;
};


struct VS_Input {
        float2 position: position;
        float4 color: color;
        float2 uv: texcoord;
};

struct V2P {
        float4 position: SV_POSITION;
        float4 color: COLOR;
        float2 uv: texcoord;
};


V2P vertex_main(VS_Input input) {
        V2P output;

        float x_ndc = input.position.x / viewport_size.x * 2.0f - 1.0f;
        float y_ndc = 1.0f - input.position.y / viewport_size.y * 2.0f;

        output.position = float4(x_ndc, y_ndc, 0.0f, 1.0f);
        output.color = input.color;
        output.uv = input.uv;

        return output;
}

float4 pixel_main(V2P input) : SV_TARGET {
        return tex.Sample(smp, input.uv) * input.color;
}

