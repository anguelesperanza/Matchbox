/*
    Standard shadow mapping
    -----------------------
    Depth-from-light-view, filtered by hardware PCF on the comparison sample
    (`SampleCmpLevelZero`) rather than a hand-rolled kernel. Ported from this
    package's own P0 `lighting.hlsli`, behind the `shadow_visibility` seam
    (`shadow/contract.hlsli`) rather than called directly -- see
    `shadow_standard.odin` for the CPU-side half: which two lights
    (`MAX_SHADOW_CASTERS`) get a real map, and how each one's view-projection
    is built.

    **P3's bias framework, applied here first.** Both `Shadow_Bias` fields
    (shadow.odin) are read per light off `lights[light_index].shadow_bias`
    rather than off one scene-wide scalar the way P0/P2's single `bias`
    field was -- see `shadow_visibility_pcss` (`shadow/pcss.hlsli`) for the
    other technique that shares this exact bias resolution, and
    `shadow_test.odin` for the numeric sweep that checks the two numbers this
    resolves to are actually sufficient. `normal_offset` moves the *sample
    point* along the surface normal before it is ever projected into light
    space -- see `Shadow_Bias`'s own doc comment for why this and the plain
    depth-compare epsilon are not redundant with each other.

    `shadow_map0`/`shadow_sampler0`/`shadow_map1`/`shadow_sampler1` are
    declared by whichever file includes `lighting_core.hlsli` (today,
    `mesh.frag.hlsl`), not here -- SDL_GPU requires a shader's sampled
    textures to be numbered contiguously from t0 (see its own
    `CreateGPUShader` doc comment), and the including shader is what knows
    where its own base-colour texture ends and these two begin.
*/

// How much of one caster's light actually reaches `world` -- 1 whenever
// `world` falls outside that caster's own frustum. The far edge of a shadow
// map fading to "lit" rather than clipping to "shadowed" is the right
// degrade: a frustum drawn too small should look like no shadow past its
// edge, not a false wall of darkness there.
//
// `bias.x` is the depth-compare epsilon, `bias.y` the world-space
// normal-offset distance -- see this file's own top comment.
float shadow_sample_pcf(
    Texture2D<float> map, SamplerComparisonState samp, float4x4 view_projection,
    float3 world, float3 normal, float2 bias)
{
    float3 offset_world = world + normal * bias.y;

    float4 light_clip = mul(view_projection, float4(offset_world, 1.0));
    float3 light_ndc   = light_clip.xyz / light_clip.w;

    float2 uv = light_ndc.xy * 0.5 + 0.5;
    uv.y = 1.0 - uv.y; // clip +Y is up, texture +V is down

    if (uv.x < 0.0 || uv.x > 1.0 || uv.y < 0.0 || uv.y > 1.0 ||
        light_ndc.z < 0.0 || light_ndc.z > 1.0)
        return 1.0;

    float current = light_ndc.z - bias.x;
    return map.SampleCmpLevelZero(samp, uv, current);
}

/*
    Which of the (up to MAX_SHADOW_CASTERS) uploaded lights this index names,
    if either -- `flags.z`/`shadow_caster1.x` are `-1` whenever shadows are
    not enabled, even if a light was marked `casts_shadow`, so this never
    trusts a map that was never actually rendered into. A light that is
    neither caster is not shadowed by this call at all -- it still receives
    every other light's shadow normally, this only ever answers for the one
    light `light_index` names.
*/
float shadow_visibility_pcf(int light_index, float3 world, float3 normal)
{
    float2 bias = lights[light_index].shadow_bias.xy;

    if (light_index == int(flags.z))
        return shadow_sample_pcf(shadow_map0, shadow_sampler0, light_view_projection, world, normal, bias);
    if (light_index == int(shadow_caster1.x))
        return shadow_sample_pcf(shadow_map1, shadow_sampler1, light_view_projection2, world, normal, bias);
    return 1.0;
}
