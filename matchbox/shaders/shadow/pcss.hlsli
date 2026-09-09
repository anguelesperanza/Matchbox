/*
    Percentage-closer soft shadows
    -------------------------------
    A blocker search, then a penumbra estimate from how far the average
    blocker sits behind the receiver, then a percentage-closer filter whose
    *width* grows with that estimate -- an occluder close to the receiver
    casts a hard-edged shadow, one far below it casts a soft one, the same
    behaviour a real area light produces and a fixed-width PCF kernel
    (`shadow/pcf.hlsli`) cannot.

    **Zero CPU-side footprint, on purpose.** This reads the exact same
    two-slot depth map `shadow_visibility_pcf` does -- same
    `shadow_standard.odin` pass, same `shadow_map0`/`shadow_map1`, same
    `light_view_projection`(2). The whole technique lives in this file: a
    blocker search over nearby texels (raw depth, via `Load`, since a
    comparison sampler answers "is this texel nearer or farther" rather than
    "how much nearer or farther") and a filter over the same map with a
    wider or narrower kernel depending on what that search found. See
    `Shadow_Technique`'s own doc comment (shadow.odin) for why this is what
    lets adding this technique cost `shadow_*.odin` nothing at all.

    **The bias framework applies unchanged.** `depth`/`normal_offset`
    (per-light, same resolution `shadow_visibility_pcf` uses) still guard the
    final comparison and the sample position the same way they do for plain
    PCF -- soft filtering changes *how many* depth comparisons run and at
    what spread, not whether each individual comparison still needs the same
    acne/peter-panning guard `shadow_test.odin` checks. A blocker search
    itself reads raw depth rather than comparing, so it needs no bias at all
    -- only the final `shadow_pcss_filter` step does.

    `light_size` (`Shadow_Settings.light_size`) is the light's own apparent
    width in world units -- `push_lighting` (lighting.odin) has already
    converted it into UV units once, on the CPU, as `flags.w`
    (`light_size / (2 * extent)`, the ortho map's own constant UV-per-world-
    unit scale), so this file never needs `extent` itself.

    Declared after `shadow/pcf.hlsli` in `lighting_core.hlsli`'s own include
    order, not included here directly -- the same "shared code lives where
    the file that assembles the includes puts it" shape
    `brdf/pbr_metallic.hlsli` already has with `brdf/pbr_common.hlsli`.
*/

// Both the blocker search and the final filter use the same small, fixed
// grid -- PCSS's own quality knob is filter *width* (driven by the computed
// penumbra), not sample count, so growing this only buys smoother noise at a
// cost this renderer's own low-fi picture would not make visible.
#define PCSS_TAPS 3

/*
    The average light-space depth of every texel in a `search_radius_uv`
    square around `uv` that is nearer the light than `receiver_depth` --
    those are the ones actually blocking it. Returns -1 (a depth value no
    real occluder can produce, since light-space z is clamped to [0, 1] by
    construction) when none are found, which is PCSS's own "no occluder in
    range" case and degrades to fully lit exactly like `shadow_sample_pcf`'s
    own out-of-frustum case does.

    `Load` rather than `Sample`: a comparison sampler answers "is this texel
    nearer or farther than X", which is exactly what the blocker search
    cannot use -- it needs the raw depth to average, not a 0/1 answer.
*/
float shadow_pcss_blocker_search(Texture2D<float> map, float2 uv, float receiver_depth, float search_radius_uv)
{
    uint width, height;
    map.GetDimensions(width, height);

    float blocker_sum   = 0;
    int   blocker_count = 0;
    const int half_taps = PCSS_TAPS / 2;

    for (int y = -half_taps; y <= half_taps; y++)
    {
        for (int x = -half_taps; x <= half_taps; x++)
        {
            float2 sample_uv = uv + float2(x, y) / float(half_taps) * search_radius_uv;
            if (sample_uv.x < 0.0 || sample_uv.x > 1.0 || sample_uv.y < 0.0 || sample_uv.y > 1.0)
                continue;

            int2  texel = int2(sample_uv * float2(width, height));
            float depth = map.Load(int3(texel, 0));

            if (depth < receiver_depth)
            {
                blocker_sum += depth;
                blocker_count += 1;
            }
        }
    }

    return blocker_count > 0 ? blocker_sum / float(blocker_count) : -1.0;
}

// The same fixed grid, now doing an ordinary hardware-filtered comparison at
// each tap -- percentage-closer, the same as shadow_sample_pcf's single tap,
// just averaged over a `filter_radius_uv` spread instead of one texel.
float shadow_pcss_filter(Texture2D<float> map, SamplerComparisonState samp, float2 uv, float current, float filter_radius_uv)
{
    float sum = 0;
    const int half_taps = PCSS_TAPS / 2;

    for (int y = -half_taps; y <= half_taps; y++)
    {
        for (int x = -half_taps; x <= half_taps; x++)
        {
            float2 sample_uv = uv + float2(x, y) / float(half_taps) * filter_radius_uv;
            sum += map.SampleCmpLevelZero(samp, sample_uv, current);
        }
    }

    return sum / float(PCSS_TAPS * PCSS_TAPS);
}

float shadow_sample_pcss(
    Texture2D<float> map, SamplerComparisonState samp, float4x4 view_projection,
    float3 world, float3 normal, float2 bias)
{
    float3 offset_world = world + normal * bias.y;

    float4 light_clip = mul(view_projection, float4(offset_world, 1.0));
    float3 light_ndc   = light_clip.xyz / light_clip.w;

    float2 uv = light_ndc.xy * 0.5 + 0.5;
    uv.y = 1.0 - uv.y;

    if (uv.x < 0.0 || uv.x > 1.0 || uv.y < 0.0 || uv.y > 1.0 ||
        light_ndc.z < 0.0 || light_ndc.z > 1.0)
        return 1.0;

    float receiver_depth  = light_ndc.z;
    float search_radius   = max(flags.w, 1.0 / 512.0); // flags.w: light_size already converted to UV units -- see this file's own top comment. Floored so a 0 light size still searches at least one texel of a 512-map rather than none.
    float avg_blocker     = shadow_pcss_blocker_search(map, uv, receiver_depth, search_radius);

    if (avg_blocker < 0.0)
        return 1.0;

    // Similar triangles: a blocker sitting (receiver - blocker) of the way
    // back to the light casts a penumbra proportional to that fraction,
    // scaled by the light's own apparent size -- the standard PCSS penumbra
    // estimate.
    float penumbra = max(receiver_depth - avg_blocker, 0.0) / max(avg_blocker, 1e-5) * search_radius;

    float current = receiver_depth - bias.x;
    return shadow_pcss_filter(map, samp, uv, current, max(penumbra, search_radius * 0.25));
}

float shadow_visibility_pcss(int light_index, float3 world, float3 normal)
{
    float2 bias = lights[light_index].shadow_bias.xy;

    if (light_index == int(flags.z))
        return shadow_sample_pcss(shadow_map0, shadow_sampler0, light_view_projection, world, normal, bias);
    if (light_index == int(shadow_caster1.x))
        return shadow_sample_pcss(shadow_map1, shadow_sampler1, light_view_projection2, world, normal, bias);
    return 1.0;
}
