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

    Must match matchbox.Lighting_Data exactly. 416 bytes.

    **`_pad0` is not spare room, it is copying a fact rather than a choice.**
    Odin's own `matrix[4,4]f32` aligns to 32 bytes, not 16, so
    `Lighting_Data.light_view_projection` sits 16 bytes further along than a
    naive count of the fields before it suggests -- the Odin side gets that
    gap from its compiler whether asked for or not, and the one thing to get
    right here is reproducing it, since HLSL's own packing would otherwise
    place a float4x4 immediately after `flags` with no gap at all.
*/

#define MAX_LIGHTS 4

struct Light
{
    float4 position; // xyz where it is,                          w 1 when enabled
    float4 target;   // xyz direction (directional/spot), unused (point), w kind: 0/1/2
    float4 color;
    float4 cone;     // x outer half-angle degrees, y inner half-angle degrees -- spot only
};

cbuffer Lighting : register(b1, space3)
{
    Light     lights[MAX_LIGHTS];
    float4    ambient;   // rgb
    float4    view_pos;  // xyz, the camera
    float4    fog_color; // rgb
    float4    fog_range; // x near, y far

    // x how many lights are set, y 1 when fog is on, z the shadow-casting
    // light's index or -1 for none, w the shadow depth-compare bias.
    float4    flags;

    float4    _pad0; // see this file's own top comment on Odin's matrix alignment

    // World space to the shadow caster's clip space. Unread whenever
    // flags.z is -1 -- see shadow_factor.
    float4x4  light_view_projection;
};

/*
    `shadow_map`/`shadow_sampler` are declared by whichever file includes
    this header, not here -- SDL_GPU requires a shader's sampled textures to
    be numbered contiguously from t0 (see its own CreateGPUShader doc
    comment), and mesh_flat and mesh_textured cannot agree on one fixed slot
    for it: mesh_flat has nothing else, so its shadow map is t0/s0, while
    mesh_textured's own albedo already sits at t0/s0 and the shadow map
    follows at t1/s1. Declaring them ahead of this #include, at whichever
    slot is free, is what makes the same shadow_factor below compile
    correctly against either.
*/

/*
    How much of a light's contribution actually reaches `world`, 0 (fully
    shadowed) to 1 (fully lit, or filtered in between across the map's own
    texels courtesy of SampleCmpLevelZero's hardware PCF).

    Returns 1 -- lit, no correction -- whenever there is no shadow caster at
    all (`flags.z < 0`, `enable_shadows` never called) or `world` falls
    outside the light's own frustum. The far edge of a shadow map fading to
    "lit" rather than clipping to "shadowed" is the right degrade: a
    frustum drawn too small should look like no shadow past its edge, not a
    false wall of darkness there.
*/
float shadow_factor(float3 world)
{
    if (flags.z < 0.0) return 1.0;

    float4 light_clip = mul(light_view_projection, float4(world, 1.0));
    float3 light_ndc   = light_clip.xyz / light_clip.w;

    float2 uv = light_ndc.xy * 0.5 + 0.5;
    uv.y = 1.0 - uv.y; // clip +Y is up, texture +V is down

    if (uv.x < 0.0 || uv.x > 1.0 || uv.y < 0.0 || uv.y > 1.0 ||
        light_ndc.z < 0.0 || light_ndc.z > 1.0)
        return 1.0;

    float current = light_ndc.z - flags.w; // flags.w: the bias
    return shadow_map.SampleCmpLevelZero(shadow_sampler, uv, current);
}

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
            // Point and spot are both a place, and fade the same way with
            // distance -- the curve PsxGame uses, which decides how far a
            // campfire reaches, so it is copied rather than reinvented.
            to_light = normalize(lights[i].position.xyz - world);

            float d = length(lights[i].position.xyz - world);
            attenuation = 1.0 / (1.0 + 0.09 * d + 0.032 * d * d);

            if (lights[i].target.w > 1.5)
            {
                // Spot: an extra cone factor on top of the same distance
                // falloff. cos falls as the angle from the cone's own axis
                // grows, so the outer edge is the smaller of the two --
                // smoothstep(outer, inner, x) is 0 past the outer cone, 1
                // inside the inner one, and a soft ramp in between.
                float3 spot_dir  = normalize(lights[i].target.xyz);
                float  cos_angle = dot(-to_light, spot_dir);
                float  outer_cos = cos(radians(lights[i].cone.x));
                float  inner_cos = cos(radians(lights[i].cone.y));
                attenuation *= smoothstep(outer_cos, inner_cos, cos_angle);
            }
        }

        // Only the one light named by flags.z casts a shadow -- see
        // shadow_factor's own doc comment for why there is only one. Every
        // other light still reaches a surface behind an occluder, the same
        // as before this feature existed.
        float shadow = (i == int(flags.z)) ? shadow_factor(world) : 1.0;

        float ndl = max(dot(n, to_light), 0.0);
        light_dot += lights[i].color.rgb * ndl * attenuation * shadow;

        if (ndl > 0.0)
        {
            float spec = pow(max(0.0, dot(viewd, reflect(-to_light, n))), 16.0);
            specular += spec * attenuation * shadow;
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
