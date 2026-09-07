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

    Must match matchbox.Lighting_Data exactly. 1248 bytes at MAX_LIGHTS = 16,
    and -- for now -- no explicit padding field: Odin's own `matrix[4,4]f32`
    aligns to 32 bytes, not 16, and has needed a manual pad here before to
    reproduce a gap the Odin side got from its compiler whether asked for or
    not. It happens not to need one at this particular size (see
    Lighting_Data's own comment for why), which is exactly why that struct's
    comment says to measure again rather than assume, the next time a field
    is added here -- or MAX_LIGHTS changes again.
*/

// Keep in step with matchbox.MAX_LIGHTS (light.odin) -- the two are not the
// same constant and nothing enforces they match except this comment and the
// size assert above catching it if they ever do not.
#define MAX_LIGHTS 16

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

    // x how many lights are set, y 1 when fog is on, z the first shadow
    // caster's light index or -1 for none, w the shadow depth-compare bias.
    float4    flags;

    // x the second shadow caster's light index or -1 for none -- two lights
    // may each cast a real shadow at once, see shadow.odin's
    // MAX_SHADOW_CASTERS. y-w unused.
    float4    shadow_caster1;

    // Each caster's own view-projection, world space to its own clip space.
    // light_view_projection is unread whenever flags.z is -1;
    // light_view_projection2 whenever shadow_caster1.x is -1.
    float4x4  light_view_projection;
    float4x4  light_view_projection2;
};

/*
    `shadow_map0`/`shadow_sampler0`/`shadow_map1`/`shadow_sampler1` are
    declared by whichever file includes this header, not here -- SDL_GPU
    requires a shader's sampled textures to be numbered contiguously from t0
    (see its own CreateGPUShader doc comment), and mesh_flat and
    mesh_textured cannot agree on one fixed pair of slots for them:
    mesh_flat has nothing else, so its two shadow maps are t0/s0 and t1/s1,
    while mesh_textured's own albedo already sits at t0/s0 and its two
    shadow maps follow at t1/s1 and t2/s2. Declaring them ahead of this
    #include, at whichever slots are free, is what makes the same
    shadow_factor below compile correctly against either.
*/

/*
    How much of one caster's light actually reaches `world`, 0 (fully
    shadowed) to 1 (fully lit, or filtered in between across the map's own
    texels courtesy of SampleCmpLevelZero's hardware PCF). Takes the map,
    its comparison sampler and its own view-projection as arguments rather
    than reading a single fixed set of globals, so the same function serves
    whichever of the two shadow-casting slots `lit_shade` is asking about.

    Returns 1 -- lit, no correction -- whenever `world` falls outside that
    caster's own frustum. The far edge of a shadow map fading to "lit"
    rather than clipping to "shadowed" is the right degrade: a frustum drawn
    too small should look like no shadow past its edge, not a false wall of
    darkness there. Callers already check the caster index is not -1 before
    reaching here -- see lit_shade -- so that case is not handled twice.
*/
float shadow_factor(Texture2D<float> map, SamplerComparisonState samp, float4x4 view_projection, float3 world)
{
    float4 light_clip = mul(view_projection, float4(world, 1.0));
    float3 light_ndc   = light_clip.xyz / light_clip.w;

    float2 uv = light_ndc.xy * 0.5 + 0.5;
    uv.y = 1.0 - uv.y; // clip +Y is up, texture +V is down

    if (uv.x < 0.0 || uv.x > 1.0 || uv.y < 0.0 || uv.y > 1.0 ||
        light_ndc.z < 0.0 || light_ndc.z > 1.0)
        return 1.0;

    float current = light_ndc.z - flags.w; // flags.w: the bias, shared by both maps
    return map.SampleCmpLevelZero(samp, uv, current);
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

        // Only the (up to two) lights named by flags.z/shadow_caster1.x cast
        // a shadow -- see shadow.odin's MAX_SHADOW_CASTERS. Every other
        // light still reaches a surface behind an occluder, the same as
        // before this feature existed.
        float shadow = 1.0;
        if (i == int(flags.z))
            shadow = shadow_factor(shadow_map0, shadow_sampler0, light_view_projection, world);
        else if (i == int(shadow_caster1.x))
            shadow = shadow_factor(shadow_map1, shadow_sampler1, light_view_projection2, world);

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
