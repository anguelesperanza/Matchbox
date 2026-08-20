/*
    The lighting model, shared by mesh_flat and mesh_textured.

    A header rather than a copy in each: dxc resolves #include relative to the
    file doing the including, and build_shaders.bat only compiles *.vert.hlsl
    and *.frag.hlsl, so a .hlsli is picked up by both and compiled as neither.

    Ported from PsxGame's lighting.fs, which is where the constants come from --
    the attenuation curve, the specular exponent of 16, the ambient divided by
    ten, and gamma applied before the fog so that the fog colour is a colour you
    picked rather than one you have to pre-distort. Keeping those exactly is the
    point: the game should look the way it already looks.

    ---

    **The packing.** Every member here is a float4, and the light is three of
    them rather than the position/target/colour/enabled/type struct it reads as.
    That is deliberate. HLSL will not let a vector straddle a 16-byte boundary
    and pads to get out of the way, and the padding it inserts is invisible from
    the Odin side -- so a float3 followed by a float is either 16 bytes or 32
    depending on rules nobody remembers correctly. Everything being a float4
    makes the layout the same on both sides by construction, which is what the
    size assert in init.odin then confirms.

    Must match matchbox.Lighting_Data exactly. 272 bytes.
*/

#define MAX_LIGHTS 4

struct Light
{
    float4 position; // xyz where it is,       w 1 when enabled
    float4 target;   // xyz what it points at, w 0 directional / 1 point
    float4 color;
};

cbuffer Lighting : register(b1, space3)
{
    Light  lights[MAX_LIGHTS];
    float4 ambient;   // rgb
    float4 view_pos;  // xyz, the camera
    float4 fog_color; // rgb
    float4 fog_range; // x near, y far
    float4 flags;     // x how many lights are set, y 1 when fog is on
};

/*
    The fallback for a game that has not set any lights.

    Stages 1 to 4 drew with a fixed direction hard-coded in the shader, and
    every example and CoffeeGame were written against it. Lighting is therefore
    opt-in: with no lights configured this is what runs, and the moment
    `set_lights` is called with one enabled the real model takes over. The
    alternative -- no lights meaning no light -- turns every existing scene
    black on the day the feature lands.
*/
float3 fallback_shade(float3 normal, float3 albedo)
{
    const float3 light_dir = normalize(float3(-0.4, 1.0, 0.7));

    float ndl = saturate(dot(normalize(normal), light_dir));
    return albedo * (0.35 + 0.65 * ndl);
}

// The real thing, when a game has set lights up.
float3 lit_shade(float3 normal, float3 world, float3 albedo)
{
    float3 n     = normalize(normal);
    float3 viewd = normalize(view_pos.xyz - world);

    float3 light_dot = float3(0, 0, 0);
    float3 specular  = float3(0, 0, 0);

    [unroll]
    for (int i = 0; i < MAX_LIGHTS; i++)
    {
        if (lights[i].position.w < 0.5) continue; // not enabled

        float3 to_light;
        float  attenuation = 1.0;

        if (lights[i].target.w < 0.5)
        {
            // Directional: a direction, not a place. Everything is lit from the
            // same angle however far away it is.
            to_light = -normalize(lights[i].target.xyz - lights[i].position.xyz);
        }
        else
        {
            to_light = normalize(lights[i].position.xyz - world);

            // The curve PsxGame uses. It is what decides how far a campfire
            // reaches, so it is copied rather than reinvented.
            float d = length(lights[i].position.xyz - world);
            attenuation = 1.0 / (1.0 + 0.09 * d + 0.032 * d * d);
        }

        float ndl = max(dot(n, to_light), 0.0);
        light_dot += lights[i].color.rgb * ndl * attenuation;

        if (ndl > 0.0)
        {
            float spec = pow(max(0.0, dot(viewd, reflect(-to_light, n))), 16.0);
            specular += spec * attenuation;
        }
    }

    float3 color = albedo * (1.0 + specular) * light_dot;
    color += albedo * (ambient.rgb / 10.0);

    return color;
}

// Shade, then fog. Gamma is applied to the lit colour before the fog is mixed
// in, so `fog_color` is the colour it looks like rather than one corrected for.
float4 apply_lighting(float3 normal, float3 world, float4 albedo)
{
    float3 color;

    if (flags.x < 0.5)
    {
        color = fallback_shade(normal, albedo.rgb);
    }
    else
    {
        color = lit_shade(normal, world, albedo.rgb);
        color = pow(color, 1.0 / 2.2);
    }

    if (flags.y > 0.5)
    {
        float distance = length(view_pos.xyz - world);
        float factor   = saturate((fog_range.y - distance) / (fog_range.y - fog_range.x));
        color = lerp(fog_color.rgb, color, factor);
    }

    return float4(color, albedo.a);
}
