/*
    Shadow contract
    ---------------
    Every technique in this directory defines one function,
    `shadow_visibility_<name>(int light_index, float3 world, float3 normal) ->
    float`, answering 0 (fully shadowed) to 1 (fully lit, or filtered in
    between). `shadow_visibility` (`lighting_core.hlsli`) is the one
    dispatcher that picks between them, switching on `Shadow_Settings.technique`
    (`shadow.odin`) for a directional or spot light, or unconditionally
    routing to `shadow_visibility_cube` first when `light_index` is the
    point-light cube caster -- see that function's own doc comment for why
    cube shadows are not one more case in the technique switch. A BRDF calls
    `shadow_visibility`, never a technique's own function directly.

    `world` is the surface point *before* any normal-offset bias is applied --
    each technique's own `.hlsli` is responsible for offsetting it along
    `normal` by its own resolved `Shadow_Bias.normal_offset` before
    projecting into light space, since where that offset happens (world space,
    once, before the light-space transform) is shared, but which bias applies
    is per-light (`lights[light_index].shadow_bias`, see `Light_Uniform`'s own
    doc comment in types.odin).

    `PCF` (standard shadow mapping filtered by hardware PCF) and `PCSS`
    (percentage-closer soft shadows, the same map with a blocker search and a
    variable-width filter on top) both read the plain depth map built by
    `shadow_standard.odin`, declared in `shadow/pcf.hlsli` -- `PCSS`'s own
    `.hlsli` includes it rather than repeating the declarations. `CASCADED`
    reads its own `MAX_SHADOW_CASTERS * MAX_CASCADES` array of maps
    (`shadow/cascaded.hlsli`). `CUBE` reads six flat `Texture2D`s per the
    point-light caster (`shadow/cube.hlsli`) rather than the technique switch
    below at all.

    Values, matching `Shadow_Technique`'s own ordinals (shadow.odin) --
    `CUBE` has none, since it is not a value that field ever takes:

        SHADOW_TECHNIQUE_PCF      0
        SHADOW_TECHNIQUE_PCSS     1
        SHADOW_TECHNIQUE_CASCADED 2
*/

#define SHADOW_TECHNIQUE_PCF      0
#define SHADOW_TECHNIQUE_PCSS     1
#define SHADOW_TECHNIQUE_CASCADED 2
