/*
    Shadow contract
    ---------------
    Every technique in this directory defines one function,
    `shadow_visibility_<name>(int light_index, float3 world) -> float`,
    answering 0 (fully shadowed) to 1 (fully lit, or filtered in between).
    `shadow_visibility` (`lighting_core.hlsli`) is the one dispatcher that
    picks between them, switching on `Shadow_Settings.technique`
    (`shadow.odin`); a BRDF calls that, never a technique's own function
    directly.

    One technique in P0 -- `PCF`, standard shadow mapping filtered by hardware
    PCF on the sample, ported unchanged from what this package had before
    this rework (`shadow_standard.odin`, `shadow/pcf.hlsli`). Adding a second
    (`lighting_plan.md` section 2's PCSS, cascaded maps, cube maps -- P3)
    means a `.hlsli` here, a value in `Shadow_Technique`, and one more case in
    `shadow_visibility`'s switch -- the dispatcher currently has one case
    because P0 has one technique to dispatch to, not because the seam only
    fits one.

    Values:

        SHADOW_TECHNIQUE_PCF  0
*/

#define SHADOW_TECHNIQUE_PCF 0
