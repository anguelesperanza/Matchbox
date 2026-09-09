/*
    Lighting core
    -------------
    The scene-wide resources every shading model and shadow technique reads
    (the light list, the `Scene` cbuffer), and the two dispatchers that pick
    between them: `shade_surface` and `shadow_visibility`. This is what
    replaces `lighting.hlsli` -- that file was one hardcoded model with one
    hardcoded shadow lookup baked into `apply_lighting`; this is the seam
    `lighting_rework.md` section 2 asks for, with `apply_lighting`'s old job
    split between `shade_surface` (the lit colour) and its own caller,
    `mesh.frag.hlsl` (the fog mix, since fog is scene state rather than a
    shading model's business).

    A header rather than a copy in each shader that needs it: dxc resolves
    `#include` relative to the file doing the including, and
    `build_shaders.bat` only compiles `*.vert.hlsl` and `*.frag.hlsl`, so a
    `.hlsli` is picked up by whichever shader includes it and compiled as
    neither on its own.

    ---

    **The packing.** Every member of `Light` and `Scene` is a float4 (or a
    float4x4), never a float3. HLSL will not let a vector straddle a 16-byte
    boundary and pads to get out of the way, and the padding it inserts is
    invisible from the Odin side -- so a float3 followed by a float is either
    16 bytes or 32 depending on rules nobody remembers correctly. Everything
    being a float4 makes the layout the same on both sides by construction,
    which is what the size asserts in init.odin then confirm.

    `Light` must match `matchbox.Light_Uniform` exactly (64 bytes); `Scene`
    must match `matchbox.Scene_Frag_Data` exactly (224 bytes) -- see that
    struct's own comment in lighting.odin for why 224 is safe from the
    32-byte `matrix[4,4]f32` alignment gap `Lighting_Data` (now deleted) used
    to have to reason about.
*/

#include "surface.hlsli"
#include "shadow/contract.hlsli"
#include "brdf/contract.hlsli"

// One light, as the shader reads it -- the same shape as before this
// rework, just an element of a StructuredBuffer now rather than a fixed-size
// array inside this same cbuffer. See light.odin's own top comment for why.
struct Light
{
    float4 position; // xyz where it is,                          w 1 when enabled
    float4 target;   // xyz direction (directional/spot), unused (point), w kind: 0/1/2
    float4 color;
    float4 cone;     // x outer half-angle degrees, y inner half-angle degrees -- spot only
};

// Unbounded -- see light.odin's top comment on why MAX_LIGHTS retired. t3,
// space2: sampled textures at t0-t2 (whichever the including shader
// declares) come first in SDL_GPU's fragment-stage numbering, storage
// buffers continue the same t[n] sequence after them.
StructuredBuffer<Light> lights : register(t3, space2);

cbuffer Scene : register(b1, space3)
{
    float4 ambient;   // rgb
    float4 view_pos;  // xyz, the camera
    float4 fog_color; // rgb

    // x near, y far, z 1 when fog is enabled, w unused.
    float4 fog_range;

    // x how many lights are set, y 1 when Lighting_Settings.enabled is true,
    // z the first shadow caster's uploaded light index or -1 for none, w the
    // shadow depth-compare bias.
    float4 flags;

    // x the second shadow caster's uploaded light index or -1 for none -- two
    // lights may each cast a real shadow at once, see shadow.odin's
    // MAX_SHADOW_CASTERS. y which shadow technique is running -- see
    // shadow_visibility below and Shadow_Technique (shadow.odin). z-w unused.
    float4 shadow_caster1;

    // Each caster's own view-projection, world space to its own clip space.
    // light_view_projection is unread whenever flags.z is -1;
    // light_view_projection2 whenever shadow_caster1.x is -1.
    float4x4 light_view_projection;
    float4x4 light_view_projection2;
};

#include "shadow/pcf.hlsli"

/*
    How much of one caster's light reaches `world`, switching on
    `shadow_caster1.y` (`Shadow_Settings.technique`, set by `set_lighting`).
    One technique in P0 -- see `shadow/contract.hlsli`'s own doc comment for
    what adding a second touches; the `default` case is `PCF` rather than an
    error so a technique value this shader does not yet know about degrades
    to the one it does, the same silent-degrade shape an unsupported
    combination gets elsewhere in this package.

    Declared before the brdf includes below: a BRDF is free to call this from
    inside its own light loop (see `brdf/contract.hlsli`'s own doc comment on
    why the loop lives there rather than in shared code), which means the
    dispatcher has to exist before anything that might call it.
*/
float shadow_visibility(int light_index, float3 world)
{
    switch (int(shadow_caster1.y))
    {
        case SHADOW_TECHNIQUE_PCF:
        default:
            return shadow_visibility_pcf(light_index, world);
    }
}

#include "brdf/blinn_phong.hlsli"
#include "brdf/unlit.hlsli"

/*
    The one dispatcher a mesh fragment shader calls: which BRDF `surface`
    runs, then the fog mix every material gets regardless of which one that
    was.

    `flags.y < 0.5` (`Lighting_Settings.enabled == false`, lighting.odin)
    forces `SHADING_UNLIT` on every material regardless of its own choice --
    this is the second way `lighting_rework.md` section 6 describes reaching
    an unlit picture, alongside a material choosing `Shading_Model.UNLIT`
    itself. Both exist because they answer different questions: a material
    says "I am never lit"; a scene says "nothing is lit right now" without
    every material needing to agree on why.

    Gamma is applied here, per shading model, rather than inside each
    `brdf_eval_*` -- `BLINN_PHONG`'s output wants `pow(1/2.2)` because
    PsxGame's own did, `UNLIT`'s does not, because its output is already the
    colour the material asked for. This is P0's one carried-over wart: P1
    moves the whole 3D pass to an HDR target and this pow call leaves every
    BRDF for a proper tonemap resolve -- see `lighting_rework.md` section 3.7
    for why it has to leave before a second shading model can be added
    without deciding this question again.
*/
float4 shade_surface(Surface surface)
{
    uint model = flags.y > 0.5 ? surface.shading_model : SHADING_UNLIT;

    float3 color;
    switch (model)
    {
    case SHADING_BLINN_PHONG:
        color = brdf_eval_blinn_phong(surface);
        color = pow(max(color, 0.0), 1.0 / 2.2);
        break;
    case SHADING_UNLIT:
    default:
        color = brdf_eval_unlit(surface);
        break;
    }

    if (fog_range.z > 0.5)
    {
        float distance = length(view_pos.xyz - surface.position);
        float factor   = saturate((fog_range.y - distance) / (fog_range.y - fog_range.x));
        color = lerp(fog_color.rgb, color, factor);
    }

    return float4(color, surface.alpha);
}
