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

    Declared before `sample_light` below: that is the only caller left, since
    P2b moved the shadow lookup out of every BRDF's own light loop and into
    shared code -- see `brdf/contract.hlsli`'s own doc comment for why no
    `brdf_light_*`/`brdf_resolve_*` may call this directly any more.
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

/*
    What light `i` contributes at `surface`, resolved once regardless of
    which shading model is running -- see `brdf/contract.hlsli`'s own doc
    comment for the three-piece contract this is step one of, and
    `lighting_rework.md` section 2.1 for why this used to be duplicated
    inside every model's own light loop instead. Lifted verbatim from what
    was P0's `brdf_eval_blinn_phong` (now `brdf_light_blinn_phong`,
    `brdf/blinn_phong.hlsli`): the directional/point/spot resolution, the
    distance attenuation curve, the spot cone smoothstep, and the shadow
    lookup are unchanged arithmetic, just no longer copied into a second
    model the day one arrives.

    **`radiance` already has attenuation and shadow multiplied in.** That is
    the whole point of pulling this out: a BRDF never learns whether a
    shadow map, a spot cone or distance dimmed a light, the same way
    `Surface` never tells one which render pipeline filled it in
    (`surface.hlsli`'s own doc comment).

    Declared after `shadow_visibility` above, and after `Light`/`lights`/
    `Scene`, because it reads all three -- `sample_light` is scene-shaped
    code, not a model, so it lives here rather than in `brdf/contract.hlsli`
    alongside the plain data shapes (`Light_Sample`, `Radiance`) that do not
    depend on any of them.
*/
Light_Sample sample_light(uint i, Surface surface)
{
    Light_Sample result;
    float        attenuation = 1.0;

    if (lights[i].target.w < 0.5)
    {
        // Directional: a direction, not a place. Everything is lit from
        // the same angle however far away it is.
        result.direction = -normalize(lights[i].target.xyz - lights[i].position.xyz);
    }
    else
    {
        // Point and spot are both a place, and fade the same way with
        // distance -- the curve PsxGame uses, which decides how far a
        // campfire reaches, so it is copied rather than reinvented.
        result.direction = normalize(lights[i].position.xyz - surface.position);

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
            float  cos_angle = dot(-result.direction, spot_dir);
            float  outer_cos = cos(radians(lights[i].cone.x));
            float  inner_cos = cos(radians(lights[i].cone.y));
            attenuation *= smoothstep(outer_cos, inner_cos, cos_angle);
        }
    }

    // Every light asks the same dispatcher, regardless of whether it is
    // actually one of the (up to MAX_SHADOW_CASTERS) casters -- see
    // shadow_visibility_pcf's own doc comment for why a light that is
    // neither still comes back 1 (unshadowed) rather than needing a special
    // case here.
    float shadow = shadow_visibility(int(i), surface.position);

    result.n_dot_l  = max(dot(surface.normal, result.direction), 0.0);
    result.radiance = lights[i].color.rgb * attenuation * shadow;

    return result;
}

#include "brdf/blinn_phong.hlsli"
#include "brdf/unlit.hlsli"

/*
    Step two of the per-light contract: which model's `brdf_light_<name>`
    runs for this light. The only things in this whole file that switch on
    `Surface.shading_model` are this function and `brdf_resolve` below --
    see `brdf/contract.hlsli`'s own doc comment for why adding a sixth
    shading model touches one line in each of these two rather than
    anything else here.
*/
Radiance brdf_light(Surface surface, Light_Sample light)
{
    switch (surface.shading_model)
    {
    case SHADING_BLINN_PHONG:
        return brdf_light_blinn_phong(surface, light);
    case SHADING_UNLIT:
    default:
        return brdf_light_unlit(surface, light);
    }
}

// Step three: which model's `brdf_resolve_<name>` turns the accumulated
// sums into a colour. See `brdf_light`'s own doc comment just above.
float3 brdf_resolve(Surface surface, Radiance total)
{
    switch (surface.shading_model)
    {
    case SHADING_BLINN_PHONG:
        return brdf_resolve_blinn_phong(surface, total);
    case SHADING_UNLIT:
    default:
        return brdf_resolve_unlit(surface, total);
    }
}

/*
    The light loop itself -- shared, written once, the replacement for every
    model owning its own copy of this. `lighting_rework.md` section 2.1's own
    sketch, unchanged: sample each light, dispatch its contribution into the
    running `Radiance`, then dispatch once more to resolve the sums into a
    colour. No shading model ever appears here by name -- this loop only
    knows the contract (`brdf/contract.hlsli`), not which models implement
    it, which is what keeps a new model from having to touch this function.
*/
float3 shade_lights(Surface surface)
{
    Radiance total = (Radiance)0;

    uint count = uint(flags.x);
    for (uint i = 0; i < count; i++)
    {
        Light_Sample light = sample_light(i, surface);
        Radiance     r     = brdf_light(surface, light);

        total.diffuse  += r.diffuse;
        total.specular += r.specular;
    }

    return brdf_resolve(surface, total);
}

/*
    The one dispatcher a mesh fragment shader calls: which BRDF `surface`
    runs (by way of `shade_lights` above), then the fog mix every material
    gets regardless of which one that was.

    `flags.y < 0.5` (`Lighting_Settings.enabled == false`, lighting.odin)
    forces `SHADING_UNLIT` on every material regardless of its own choice --
    this is the second way `lighting_rework.md` section 6 describes reaching
    an unlit picture, alongside a material choosing `Shading_Model.UNLIT`
    itself. Both exist because they answer different questions: a material
    says "I am never lit"; a scene says "nothing is lit right now" without
    every material needing to agree on why.

    The override is applied to this function's own local copy of `surface`
    before `shade_lights` ever sees it -- HLSL passes structs by value, so
    mutating the parameter here changes nothing the caller holds, and lets
    `brdf_light`/`brdf_resolve` read `surface.shading_model` directly rather
    than needing the scene-level override threaded through as a second
    argument.

    **No gamma and no tone mapping here, since P1.** Before that phase,
    `BLINN_PHONG`'s branch applied `pow(color, 1.0 / 2.2)` in place, inline,
    before fog -- a transfer function baked into one shading model's own
    case of this switch, which is exactly what `brdf/contract.hlsli`'s doc
    comment on the BRDF contract warns against: the next shading model would
    have had to decide the same question again, in its own branch, and there
    would be two answers to "what encode does this pass use" alive at once.
    This function now returns pure linear light -- fog mixed in below, still
    nothing else -- and the whole 3D pass writes that into an `RGBA16_FLOAT`
    scene target. The tonemap resolve (`tonemap.odin`,
    `shaders/tonemap.frag.hlsl`) is the one place exposure, a tonemap curve
    and the gamma encode run, once, after every shading model and every
    fragment in the pass has already been decided rather than per-branch
    here.

    One consequence worth stating plainly: `UNLIT` and the skybox/line
    shaders (which never call this function at all) used to write their
    output straight through with no encode of any kind, so a material's
    `base_color` or a skybox's `tint` was the literal pixel value. Now that
    the whole HDR target is resolved uniformly, those colours are tonemapped
    and gamma-encoded exactly like every lit surface's output is -- a value
    like `{0.5, 0.5, 0.5}` no longer lands on screen as a 0.5 grey pixel, the
    same way it no longer would for a lit one. There is no way to opt an
    individual draw out of the resolve without reintroducing the per-branch
    encode this phase removes; a material that wants to look identical to
    before this phase needs a different `base_color`, not a different code
    path.
*/
float4 shade_surface(Surface surface)
{
    surface.shading_model = flags.y > 0.5 ? surface.shading_model : SHADING_UNLIT;

    float3 color = shade_lights(surface);

    /*
        Fog moves into linear space here purely by virtue of where the
        encode used to be relative to this line: before P1, this mix ran
        *after* SHADING_BLINN_PHONG's own pow(1/2.2), so `fog_color` was
        being blended against an already gamma-encoded value -- it meant
        "the colour you picked", literally, because nothing further ever
        touched it. The encode is gone from this function entirely now, so
        the identical mix, unchanged, runs in linear light before the
        tonemap resolve -- `fog_color` is no longer the final pixel value,
        it is one more linear quantity the resolve's curve and gamma step
        will still transform afterward, the same as every light's own
        colour already was. See `Fog`'s own doc comment (lighting.odin) for
        what a game should expect to look different.
    */
    if (fog_range.z > 0.5)
    {
        float distance = length(view_pos.xyz - surface.position);
        float factor   = saturate((fog_range.y - distance) / (fog_range.y - fog_range.x));
        color = lerp(fog_color.rgb, color, factor);
    }

    return float4(color, surface.alpha);
}
