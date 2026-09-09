/*
    Blinn-Phong
    -----------
    Ported from this package's own `lighting.hlsli` -- itself ported from
    PsxGame's lighting.fs -- constant for constant: the same attenuation
    curve, the same specular exponent of 16, the same ambient divided by ten.
    Keeping those exactly is the whole point of doing this one first (P0):
    not because this look is being preserved past this phase (it is not, see
    `lighting_rework.md` section 7.4), but because a refactor that also
    changes the maths cannot be checked against a reference picture. Every
    later shading model is free to look however it likes; this one may not,
    yet.

    See `brdf/contract.hlsli`'s own doc comment for why this owns its whole
    light loop rather than being called once per light: the final
    `base_color * (1 + specular) * diffuse` combination has a cross term
    between every pair of lights that a strict per-light contract cannot
    express.

    The specular exponent is read from the bound `Material` cbuffer's own
    `emissive.w` (`mesh.frag.hlsl`) rather than from `Surface` -- see
    `material.odin`'s own `Material_Frag_Data` packing comment. `Surface` only
    carries what a shading model needs that a future deferred G-buffer could
    also supply (`surface.hlsli`'s own doc comment); a scalar this specific to
    one model is cheaper read straight off the material that is already bound
    for this draw.
*/
float3 brdf_eval_blinn_phong(Surface surface)
{
    float3 n     = surface.normal;
    float3 viewd = surface.view;

    float3 diffuse_sum  = float3(0, 0, 0);
    float3 specular_sum = float3(0, 0, 0);

    uint count = uint(flags.x);
    for (uint i = 0; i < count; i++)
    {
        float3 to_light;
        float  attenuation = 1.0;

        if (lights[i].target.w < 0.5)
        {
            // Directional: a direction, not a place. Everything is lit from
            // the same angle however far away it is.
            to_light = -normalize(lights[i].target.xyz - lights[i].position.xyz);
        }
        else
        {
            // Point and spot are both a place, and fade the same way with
            // distance -- the curve PsxGame uses, which decides how far a
            // campfire reaches, so it is copied rather than reinvented.
            to_light = normalize(lights[i].position.xyz - surface.position);

            float d = length(lights[i].position.xyz - surface.position);
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

        // Every light asks the same dispatcher, regardless of whether it is
        // actually one of the (up to MAX_SHADOW_CASTERS) casters -- see
        // shadow_visibility_pcf's own doc comment for why a light that is
        // neither still comes back 1 (unshadowed) rather than needing a
        // special case here.
        float shadow = shadow_visibility(int(i), surface.position);

        float ndl = max(dot(n, to_light), 0.0);
        diffuse_sum += lights[i].color.rgb * ndl * attenuation * shadow;

        if (ndl > 0.0)
        {
            float specular_power = emissive.w; // Material's own, see this file's top comment
            float spec = pow(max(0.0, dot(viewd, reflect(-to_light, n))), specular_power);
            specular_sum += spec * attenuation * shadow;
        }
    }

    float3 color = surface.base_color * (1.0 + specular_sum) * diffuse_sum;
    color += surface.base_color * (ambient.rgb / 10.0);

    return color;
}
