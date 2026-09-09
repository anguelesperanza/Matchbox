/*
    Unlit
    -----
    What replaces the old fixed-direction fallback that ran whenever a scene
    had no lights set -- see `lighting_rework.md` section 1's first defect,
    and `shade_surface`'s own doc comment (`lighting_core.hlsli`) for the
    other way to reach this same output: `Lighting_Settings.enabled = false`
    forces every material through this regardless of its own shading model.

    No light loop, no shadow lookup, no ambient -- a material that chose this
    (or a scene with lighting off) is not lit by anything, which is the
    honest statement `lighting_rework.md` section 1 asks for in place of an
    accident of how many lights happened to be set.
*/
float3 brdf_eval_unlit(Surface surface)
{
    return surface.base_color;
}
