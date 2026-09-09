/*
    BRDF contract
    -------------
    Every shading model in this directory defines one function,
    `brdf_eval_<name>(Surface) -> float3`, returning a linear colour before
    fog -- no gamma, no tone mapping (that machinery is P1). `shade_surface`
    (`lighting_core.hlsli`) is the one place that switches on
    `Surface.shading_model` to decide which one to call; nothing else in
    shared code calls one directly, and no `brdf_eval_*` may assume which
    render pipeline filled the `Surface` it was handed -- see
    `surface.hlsli`'s own doc comment.

    Odin and HLSL both lack a real interface (`lighting_rework.md` section 2),
    so this is a naming convention rather than something the compiler checks.
    The value column below is what `shading_model_index` (shading.odin) must
    keep agreeing with; it is a `#define` and not `Shading_Model` translated
    automatically because HLSL and Odin do not share an enum -- see that
    proc's own doc comment.

    **Not `brdf_eval(Surface, Light_Sample)`, one call per light, the way
    `lighting_plan.md`'s strategy-pattern framing suggests.** That shape was
    tried first and does not fit `BLINN_PHONG`: PsxGame's own formula sums a
    light's diffuse and specular contributions into two *separate* running
    totals and only combines them at the very end --
    `base_color * (1 + sum(specular)) * sum(diffuse)` -- which has a genuine
    cross term between every pair of lights' specular and diffuse
    contributions. That is not decomposable into an order-independent sum of
    independent per-light contributions, which a strict `brdf_eval(light)`
    contract would require. Porting the exact formula "constant for constant"
    (`lighting_rework.md` section 5, P0) therefore needs each model to own its
    whole light loop -- which it can do freely, since `lights`
    (`StructuredBuffer<Light>`), `flags.x` (the light count) and
    `shadow_visibility` (`shadow/contract.hlsli`) are ordinary globals visible
    to any included file, not something that needs threading through a
    parameter list. A model with a simpler, order-independent sum -- most of
    `lighting_plan.md`'s remaining four are exactly that -- is free to loop
    the same way and simply not have a cross term.

    Values:

        SHADING_BLINN_PHONG  0
        SHADING_UNLIT        1
*/

#define SHADING_BLINN_PHONG 0
#define SHADING_UNLIT       1
