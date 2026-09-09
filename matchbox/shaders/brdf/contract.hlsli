/*
    BRDF contract
    -------------
    Every shading model in this directory defines three things, not one --
    P0 shipped a single `brdf_eval_<name>(Surface) -> float3` that owned its
    whole light loop, and `lighting_rework.md` section 2.1 records why that
    was a weaker seam than this one and why replacing it is P2b's first job,
    ahead of any new model. Read that section before touching this file; it
    explains the reasoning this comment only summarizes.

    **One -- sampling a light. Shared, not part of any model's own file.**
    `sample_light` (`lighting_core.hlsli`) resolves the directional/point/
    spot distinction, the distance attenuation curve, the spot cone
    smoothstep and the shadow lookup, once, regardless of which model is
    running:

        struct Light_Sample
        {
            float3 direction; // normalized, surface toward the light
            float3 radiance;  // color * attenuation * shadow -- what actually lands
            float  n_dot_l;   // clamped; every model wants it
        };

        Light_Sample sample_light(uint i, Surface surface);

    `radiance` already has attenuation and shadow multiplied in -- a BRDF
    must never learn whether a shadow map, a cone or distance dimmed a
    light, the same way it never learns which render pipeline filled in the
    `Surface` it was handed (see that struct's own doc comment).

    **Two -- evaluating one light. `brdf_light_<name>`, the model's actual
    job, named channels rather than one colour:**

        struct Radiance
        {
            float3 diffuse;
            float3 specular;
        };

        Radiance brdf_light_<name>(Surface surface, Light_Sample light);

    Named channels are what make this decomposable at all -- see
    `brdf_resolve_blinn_phong`'s own doc comment (`brdf/blinn_phong.hlsli`)
    for the cross term this shape was designed around: P0's conclusion that
    Blinn-Phong could not be split into independent per-light contributions
    was true only because it assumed a single `float3` per light. Both of
    PsxGame's own running totals are plain sums; only the final combine is
    nonlinear, and that combine is what step three is for.

    **Three -- resolving the sums. `brdf_resolve_<name>`, where a model's
    own weirdness (or lack of it) lives:**

        float3 brdf_resolve_<name>(Surface surface, Radiance total);

    Blinn-Phong's combines `total.diffuse` and `total.specular`
    non-linearly (`base_color * (1 + specular) * diffuse`, plus ambient);
    the boring case most of `lighting_plan.md`'s remaining models are is
    just `total.diffuse + total.specular`.

    **The loop itself is shared too.** `shade_lights` (`lighting_core.hlsli`)
    calls `sample_light` once per light, dispatches to `brdf_light`, sums
    the two channels, then dispatches once more to `brdf_resolve`.
    `brdf_light` and `brdf_resolve` are the only two places anything
    switches on `Surface.shading_model` -- **the modularity test is four
    places now, not three**: a new `.hlsli`, a `SHADING_*` value here, and
    one line in each of those two switches (`lighting_core.hlsli`). Still
    bounded and mechanical; `lighting_rework.md` section 2.1 states plainly
    that this is a real cost of the split and why it is worth paying --
    P3/P4 stop touching BRDF files at all, since a new shadow technique or a
    changed attenuation curve both land inside `sample_light` alone.

    No `brdf_light_*` or `brdf_resolve_*` may assume which render pipeline
    filled the `Surface` it was handed (`surface.hlsli`'s own doc comment),
    call `shadow_visibility` directly, iterate `lights` itself, or apply a
    transfer function, an exposure multiply or a tone-mapping curve -- that
    machinery is the tonemap resolve (`tonemap.odin`,
    `shaders/tonemap.frag.hlsl`), which runs once, after `shade_surface` has
    mixed in fog, on the whole HDR scene target, not per shading model and
    not in this directory.

    Odin and HLSL both lack a real interface (`lighting_rework.md` section
    2), so all of the above is a naming convention rather than something the
    compiler checks. The value column below is what `shading_model_index`
    (shading.odin) must keep agreeing with; it is a `#define` and not
    `Shading_Model` translated automatically because HLSL and Odin do not
    share an enum -- see that proc's own doc comment.

    Values:

        SHADING_BLINN_PHONG   0
        SHADING_UNLIT         1
        SHADING_PBR_METALLIC  2
        SHADING_PBR_SPECGLOSS 3
*/

#define SHADING_BLINN_PHONG   0
#define SHADING_UNLIT         1
#define SHADING_PBR_METALLIC  2
#define SHADING_PBR_SPECGLOSS 3

/*
    What one light contributes at a surface, before any model-specific
    arithmetic runs -- the return of `sample_light` (`lighting_core.hlsli`).
    Declared here, ahead of `Light`/`Scene` in that file, because it depends
    on neither: it is a plain bag of floats, not scene state.
*/
struct Light_Sample
{
    float3 direction; // normalized, surface toward the light
    float3 radiance;  // color * attenuation * shadow -- what actually lands
    float  n_dot_l;   // clamped; every model wants it
};

// The per-model running total `shade_lights` (`lighting_core.hlsli`)
// accumulates across every light before handing it to `brdf_resolve_<name>`.
struct Radiance
{
    float3 diffuse;
    float3 specular;
};
