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

    `Light` must match `matchbox.Light_Uniform` exactly (112 bytes since P4's
    own `area_right`/`area_size`); `Scene` must match `matchbox.Scene_Frag_Data`
    exactly (272 bytes since P5's own `cluster_grid`/`cluster_camera`) -- see
    that struct's own comment in lighting.odin for why both stayed safe from
    the 32-byte `matrix[4,4]f32` alignment gap `Lighting_Data` (now deleted)
    used to have to reason about.

    `cluster_ranges`/`cluster_light_indices` below are `CLUSTERED`'s own two
    storage buffers -- see `light_cull.odin`'s own top comment for what
    builds them (on the CPU, once a frame) and why, and
    `cluster_index_for_fragment`'s own doc comment for the one place they are
    read. Declared and bound unconditionally, the identical "always
    something valid, whether or not this scene uses it" shape `lights` below
    already has: a `FORWARD` scene has these bound to a 1-element placeholder
    (`pipeline_forward_cluster_buffers`, pipeline_forward.odin) it never
    reads, because `shade_lights` only branches into them under `CLUSTERED`.
*/

#include "surface.hlsli"
#include "shadow/contract.hlsli"
#include "brdf/contract.hlsli"

/*
    One light, as the shader reads it -- the same shape as before this
    rework, just an element of a StructuredBuffer now rather than a fixed-size
    array inside this same cbuffer. See light.odin's own top comment for why.

    `shadow_bias` joined the other four in P3 -- this light's own resolved
    `Shadow_Bias` (shadow.odin), already defaulted from the scene's own
    `Shadow_Settings.bias` at pack time if this light left either field zero
    (see `light_uniform`, light.odin, and `Light_Uniform`'s own doc comment
    in types.odin). Every technique's own `shadow_visibility_<name>` reads
    `lights[light_index].shadow_bias` directly rather than a scene-wide
    scalar the way this package's single `bias` field used to work.

    `area_right`/`area_size` joined the rest in P4, for `AREA_RECT`/
    `AREA_DISK` (kind 3/4, `target.w`) -- see `Light.area_right`'s own doc
    comment (light.odin) for what each component means, and
    `area_light_representative_point` below for the one place either field
    is ever read. Unread by every other kind, the same "field rides along
    unread" shape `cone` already has for a light that is not a spot.
*/
struct Light
{
    float4 position;    // xyz where it is,                          w 1 when enabled
    float4 target;      // xyz direction (directional/spot/area facing), w kind: 0 directional, 1 point, 2 spot, 3 area rect, 4 area disk
    float4 color;
    float4 cone;        // x outer half-angle degrees, y inner half-angle degrees -- spot only
    float4 shadow_bias; // x depth bias, y normal-offset bias -- see Shadow_Bias.  z-w unused

    // Area rect/disk only -- see Light.area_right's own doc comment
    // (light.odin) for what each component means and why a disk leaves most
    // of them unread.
    float4 area_right; // xyz normalized tangent axis (rect only), w half-width (rect) / radius (disk)
    float4 area_size;  // x half-height (rect only).  y-w unused
};

/*
    Unbounded -- see light.odin's top comment on why MAX_LIGHTS retired. t10,
    space2: sampled textures at t0-t9 (whichever the including shader
    declares -- mesh.frag.hlsl's own ten, since P4 added the environment
    probe's own two maps on top of P3b's eight) come first in SDL_GPU's
    fragment-stage numbering, storage buffers continue the same t[n] sequence
    after them. Any shader that changes its own sampler count has to
    renumber this to match -- mesh.frag.hlsl's own top comment is the place
    that number is decided.
*/
StructuredBuffer<Light> lights : register(t10, space2);

/*
    One cluster's own slice of `cluster_light_indices` below -- `count`
    lights starting at `offset`. Must match `matchbox.Cluster_Range`
    (light_cull.odin) exactly: two plain `uint`s, 8 bytes, no padding either
    side needs -- a `StructuredBuffer` element is not a cbuffer, so none of
    this file's own "everything is a float4" packing rule applies to it.
*/
struct Cluster_Range
{
    uint offset;
    uint count;
};

// t11/t12, space2 -- continuing the sequence `lights` (t10) started, per
// this file's own top comment. Indexed by `cluster_index_for_fragment`
// below, which `tx + ty*nx + tz*nx*ny` (light_cull.odin's own
// `cluster_build`) has to agree with byte for byte or a fragment reads a
// neighbouring cluster's own light list.
StructuredBuffer<Cluster_Range> cluster_ranges        : register(t11, space2);
StructuredBuffer<uint>          cluster_light_indices  : register(t12, space2);

cbuffer Scene : register(b1, space3)
{
    // rgb: the CONSTANT colour, or HEMISPHERE's own sky colour -- unread
    // under ENVIRONMENT_PROBE, which reads the probe's own textures
    // instead. w: Ambient_Kind's own ordinal -- see ambient_light below.
    float4 ambient;
    float4 view_pos;  // xyz, the camera
    float4 fog_color; // rgb

    // P4's own addition. rgb: HEMISPHERE's own ground colour, unread by
    // the other two kinds. w: Environment_Probe.prefiltered_level_count - 1,
    // 0 whenever no probe is bound -- see pbr_environment_specular
    // (brdf/pbr_common.hlsli), the one reader.
    float4 ambient_ground;

    // x near, y far, z 1 when fog is enabled, w unused.
    float4 fog_range;

    // x how many lights are set, y 1 when Lighting_Settings.enabled is true,
    // z the first shadow caster's uploaded light index or -1 for none, w
    // PCSS's own light_size pre-converted to the shadow map's UV units --
    // see shadow/pcss.hlsli's own top comment. Unread by every other
    // technique; the old scene-wide depth bias that used to live here moved
    // to each light's own shadow_bias (Light, above) in P3.
    float4 flags;

    // x the second shadow caster's uploaded light index or -1 for none -- two
    // lights may each cast a real shadow at once, see shadow.odin's
    // MAX_SHADOW_CASTERS. y which shadow technique is running -- see
    // shadow_visibility below and Shadow_Technique (shadow.odin). z-w unused.
    float4 shadow_caster1;

    /*
        P5's own addition -- see matchbox.Scene_Frag_Data's own doc comment
        (lighting.odin) for what each component means. Read only by
        cluster_index_for_fragment below, and only once shade_lights has
        already branched on cluster_grid.w == 1 (CLUSTERED) -- FORWARD never
        touches either field.
    */
    float4 cluster_grid;
    float4 cluster_camera;

    // Each caster's own view-projection, world space to its own clip space.
    // light_view_projection is unread whenever flags.z is -1;
    // light_view_projection2 whenever shadow_caster1.x is -1.
    float4x4 light_view_projection;
    float4x4 light_view_projection2;
};

#include "shadow/pcf.hlsli"
#include "shadow/pcss.hlsli"
#include "shadow/cascaded.hlsli"
#include "shadow/cube.hlsli"

/*
    How much of one caster's light reaches `world`, switching on
    `shadow_caster1.y` (`Shadow_Settings.technique`, set by `set_lighting`)
    for a directional or spot caster -- except a point-light caster, checked
    first and unconditionally, since it was never one of this switch's
    choices in the first place. See `Shadow_Technique`'s own doc comment
    (shadow.odin) for why `CUBE` is not a fourth case here, and
    `shadow/contract.hlsli`'s own doc comment for what adding a genuinely new
    directional/spot technique touches. The `default` case is `PCF` rather
    than an error so a technique value this shader does not yet know about
    degrades to the one it does, the same silent-degrade shape an
    unsupported combination gets elsewhere in this package.

    Declared before `sample_light` below: that is the only caller left, since
    P2b moved the shadow lookup out of every BRDF's own light loop and into
    shared code -- see `brdf/contract.hlsli`'s own doc comment for why no
    `brdf_light_*`/`brdf_resolve_*` may call this directly any more.
*/
float shadow_visibility(int light_index, float3 world, float3 normal)
{
    if (light_index == int(cube_caster.x))
        return shadow_visibility_cube(light_index, world, normal);

    switch (int(shadow_caster1.y))
    {
        case SHADOW_TECHNIQUE_PCSS:
            return shadow_visibility_pcss(light_index, world, normal);
        case SHADOW_TECHNIQUE_CASCADED:
            return shadow_visibility_cascaded(light_index, world, normal);
        case SHADOW_TECHNIQUE_PCF:
        default:
            return shadow_visibility_pcf(light_index, world, normal);
    }
}

/*
    P4's own addition -- the one place `Light.area_right`/`area_size`
    (light.odin) are ever read. `lighting_rework.md` section 2.1 flagged this
    as the one punctual-light shape LTC does not fit
    ("there is no single `direction` and no single `radiance`"); the fix
    shipped here is the representative-point approximation named there: pick
    one point on the light's own rectangle or disk and shade as though a
    point light sat there. This is *not* a research citation for a specific
    named technique -- it is the simplest member of that family (Drobot's
    "most representative point" and Karis's sphere-light trick both refine
    the same idea by aiming the search along the specular reflection ray
    rather than, say, the surface normal) chosen because `sample_light`'s own
    contract hands a BRDF exactly one `direction`/`radiance` pair regardless
    of which kind produced them -- see this function's own doc comment for
    why no BRDF file may ever learn which one it was.

    **The method.** Extend a ray from `surface.position` along the mirror
    reflection of `surface.view` off `surface.normal` (the direction a real
    specular highlight would come from), intersect it with the light's own
    plane, then clamp that point onto the rectangle (per-axis, against
    `area_right`'s own tangent and its cross-product partner) or the disk
    (radially, against `area_right.w`). Two consequences fall out of the
    clamp alone, both required by this file's own verification:

    - **Reduces to a point light exactly as the shape shrinks.** Whatever
      the unclamped intersection point is, clamping it into a rectangle or
      disk of half-extent 0 always lands on the light's own `position` --
      independent of the reflection ray, the view angle, or where the
      intersection would otherwise have fallen. `area_light_test.odin`
      checks this limit directly rather than trusting the geometry argument
      alone.
    - **The ray missing the plane (parallel, or pointing away from it)
      degrades to the light's own centre** rather than an unclamped or
      undefined point -- a surface that cannot mirror-reflect toward the
      light at all still gets a sensible representative point rather than a
      NaN one, the same "opt-in, nothing breaks" shape an unsupported
      combination already gets elsewhere in this package.

    **Only the shape's own front face emits.** A window or a light panel
    does not shine through the wall it is mounted on -- `sample_light`
    zeroes `attenuation` outright when `surface.position` is on the far side
    of the plane from `target`, the shape's own facing normal (`Light`'s own
    doc comment, light.odin).
*/
float3 area_light_representative_point(uint i, Surface surface)
{
    float3 center = lights[i].position.xyz;
    float3 normal = normalize(lights[i].target.xyz);

    // `area_right` re-squared against `normal` the same way
    // `create_area_rect_light`'s own doc comment (light.odin) already
    // re-squares a caller's slightly-off `right` hint -- a disk supplies no
    // real tangent (`Light.area_right`'s own doc comment), so this also
    // covers that degenerate all-zero input rather than needing a second
    // branch for it.
    float3 right_hint = lights[i].area_right.xyz;
    if (dot(right_hint, right_hint) < 1e-8)
        right_hint = (abs(normal.y) < 0.99) ? float3(0, 1, 0) : float3(1, 0, 0);
    float3 right = normalize(right_hint - normal * dot(right_hint, normal));
    float3 up    = cross(normal, right);

    float3 refl  = reflect(-surface.view, surface.normal);
    float  denom = dot(refl, normal);

    float3 point_on_plane;
    if (abs(denom) > 1e-5)
    {
        float t = dot(center - surface.position, normal) / denom;
        point_on_plane = (t > 0.0) ? surface.position + refl * t : center;
    }
    else
    {
        point_on_plane = center; // ray parallel to the light's own plane
    }

    float3 local = point_on_plane - center;
    float  lr    = dot(local, right);
    float  lu    = dot(local, up);

    if (lights[i].target.w > 3.5) // AREA_DISK
    {
        float radius = lights[i].area_right.w; // shared slot -- see Light_Uniform's own comment
        float r      = length(float2(lr, lu));
        if (r > radius && r > 0.0)
        {
            lr *= radius / r;
            lu *= radius / r;
        }
    }
    else // AREA_RECT
    {
        float half_width  = lights[i].area_right.w;
        float half_height = lights[i].area_size.x;
        lr = clamp(lr, -half_width, half_width);
        lu = clamp(lu, -half_height, half_height);
    }

    return center + right * lr + up * lu;
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
    shadow map, a spot cone, a distance or an area light's own shape dimmed
    a light, the same way `Surface` never tells one which render pipeline
    filled it in (`surface.hlsli`'s own doc comment). **This is also why
    `AREA_RECT`/`AREA_DISK` (P4) live entirely in this function and its own
    `area_light_representative_point` helper above, and touch no
    `brdf_light_*`/`brdf_resolve_*` file at all**: once
    `area_light_representative_point` has reduced a finite-area light to one
    point, everything below treats it exactly like `POINT`, and no shading
    model ever learns the difference.

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
    float        kind        = lights[i].target.w;

    if (kind < 0.5)
    {
        // Directional: a direction, not a place. Everything is lit from
        // the same angle however far away it is.
        result.direction = -normalize(lights[i].target.xyz - lights[i].position.xyz);
    }
    else if (kind < 2.5)
    {
        // Point and spot are both a place, and fade the same way with
        // distance -- the curve PsxGame uses, which decides how far a
        // campfire reaches, so it is copied rather than reinvented.
        result.direction = normalize(lights[i].position.xyz - surface.position);

        float d = length(lights[i].position.xyz - surface.position);
        attenuation = 1.0 / (1.0 + 0.09 * d + 0.032 * d * d);

        if (kind > 1.5)
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
    else
    {
        // AREA_RECT (3) / AREA_DISK (4) -- see area_light_representative_point's
        // own doc comment for the method and the two guarantees it exists to
        // provide (the point-light limit, and a well-defined degrade when the
        // reflection ray misses the shape's own plane).
        float3 light_point = area_light_representative_point(i, surface);

        result.direction = normalize(light_point - surface.position);

        float d = length(light_point - surface.position);
        attenuation = 1.0 / (1.0 + 0.09 * d + 0.032 * d * d);

        // Only the shape's own front face emits -- see this function's own
        // top comment and Light.area_right's doc comment (light.odin).
        float3 light_normal = normalize(lights[i].target.xyz);
        if (dot(surface.position - lights[i].position.xyz, light_normal) <= 0.0)
            attenuation = 0.0;
    }

    // Every light asks the same dispatcher, regardless of whether it is
    // actually one of the (up to MAX_SHADOW_CASTERS) casters -- see
    // shadow_visibility_pcf's own doc comment for why a light that is
    // neither still comes back 1 (unshadowed) rather than needing a special
    // case here.
    float shadow = shadow_visibility(int(i), surface.position, surface.normal);

    result.n_dot_l  = max(dot(surface.normal, result.direction), 0.0);
    result.radiance = lights[i].color.rgb * attenuation * shadow;

    return result;
}

/*
    Ambient/environment -- P4's own module selection, `Ambient_Kind`'s three
    values (lighting.odin) read off `ambient.w`. Every `brdf_resolve_*` in
    `brdf/` used to read `ambient.rgb` directly, which was `Ambient_Kind.CONSTANT`
    with no other option; this function is what they call instead, and
    `CONSTANT`'s own branch returns exactly what they used to read, so a
    scene that never sets `kind` away from its zero value sees no change at
    all. See `Ambient_Kind`'s own doc comment for what `HEMISPHERE` and
    `ENVIRONMENT_PROBE` mean.

    **What this returns is diffuse irradiance, not radiance.** A metallic-
    roughness/spec-gloss material also wants a specular reflection term under
    `ENVIRONMENT_PROBE` -- that is `pbr_environment_specular`
    (`brdf/pbr_common.hlsli`), a second, separate function, because
    `blinn_phong`/`toon`/`subsurface` have no physically-based specular
    environment term to add and must not be forced to call one -- each
    model's own resolve decides which of the two (or both, or neither) it
    wants, the same "each model decides what ambient means to it" property
    `brdf_resolve_blinn_phong`'s own doc comment already established for the
    ambient-over-ten scaling.
*/
#define AMBIENT_CONSTANT          0
#define AMBIENT_HEMISPHERE        1
#define AMBIENT_ENVIRONMENT_PROBE 2

/*
    Face `face`'s own (right, up, forward) camera basis -- the shader-side
    twin of `probe_face_vert_data` (ambient.odin), which this must match
    exactly or a bake would write a face's own image rotated relative to how
    this reads it back (see ambient.odin's own top comment). Built from the
    same `shadow_cube_face_index`'s inverse -- the six (direction, up_hint)
    pairs `shadow_cube_face_direction` (shadow_cube.odin) already established
    for the point-light cube shadow map, re-squared the same way
    `look_at_matrix` re-squares its own `up` hint against a forward
    direction.
*/
void probe_face_basis(int face, out float3 right, out float3 up, out float3 forward)
{
    float3 direction, up_hint;
    switch (face)
    {
    case 0: direction = float3( 1,  0,  0); up_hint = float3(0, 1,  0); break;
    case 1: direction = float3(-1,  0,  0); up_hint = float3(0, 1,  0); break;
    case 2: direction = float3( 0,  1,  0); up_hint = float3(0, 0, -1); break;
    case 3: direction = float3( 0, -1,  0); up_hint = float3(0, 0,  1); break;
    case 4: direction = float3( 0,  0,  1); up_hint = float3(0, 1,  0); break;
    default: direction = float3(0,  0, -1); up_hint = float3(0, 1,  0); break;
    }

    forward = normalize(direction);
    right   = normalize(cross(forward, up_hint));
    up      = cross(right, forward);
}

/*
    Projects a world-space `direction` through face `face`'s own basis to get
    the UV a bake into that face's own layer wrote it at -- the read-side
    twin of what `skybox.vert.hlsl` computes at bake time
    (`direction = forward + right*ndc.x + up*ndc.y`), undone by the same
    perspective divide `probe_face_vert_data`'s own doc comment (ambient.odin)
    notes needs no extra `tan(fov/2)` scale since a 90-degree field of view
    already has `tan(45deg) == 1`.

    `uv.y = 1.0 - uv.y` is not a fresh choice -- it is `shadow_sample_pcf`'s
    own convention (`shadow/pcf.hlsli`: "clip +Y is up, texture +V is down"),
    reused rather than re-derived because a bake through the identical
    `skybox.vert.hlsl` clip-to-pixel path obeys the identical rasterizer
    convention.
*/
float2 probe_layer_uv(float3 direction, int face)
{
    float3 right, up, forward;
    probe_face_basis(face, right, up, forward);

    float3 d   = direction / dot(direction, forward); // undo the perspective divide
    float2 ndc = float2(dot(d, right), dot(d, up));
    float2 uv  = ndc * 0.5 + 0.5;
    uv.y = 1.0 - uv.y;
    return uv;
}

/*
    `ambient.rgb`/`ambient_ground.rgb`/the probe's own `irradiance_map` --
    whichever `Ambient_Kind` (lighting.odin) selected. `irradiance_map`/
    `probe_sampler0` are declared by whichever shader includes this file
    (today, `mesh.frag.hlsl`), the same "the including shader owns the
    actual texture/sampler declarations" shape `shadow_map0` already has
    (`shadow/pcf.hlsli`'s own top comment).

    `HEMISPHERE` blends by `surface.normal.y` against world +Y rather than a
    configurable axis: this is P4's own cheap approximation of an outdoor
    sky/ground split, not a general-purpose directional gradient, and a
    scene that wants a tilted split is exactly what `ENVIRONMENT_PROBE`
    is for.
*/
float3 ambient_light(Surface surface)
{
    int kind = int(ambient.w);

    if (kind == AMBIENT_HEMISPHERE)
    {
        float t = surface.normal.y * 0.5 + 0.5;
        return lerp(ambient_ground.rgb, ambient.rgb, t);
    }

    if (kind == AMBIENT_ENVIRONMENT_PROBE)
    {
        int    face = shadow_cube_face_index(surface.normal);
        float2 uv   = probe_layer_uv(surface.normal, face);
        return irradiance_map.Sample(probe_sampler0, float3(uv, float(face))).rgb;
    }

    return ambient.rgb; // AMBIENT_CONSTANT
}

#include "brdf/blinn_phong.hlsli"
#include "brdf/unlit.hlsli"
#include "brdf/pbr_common.hlsli"
#include "brdf/pbr_metallic.hlsli"
#include "brdf/pbr_specgloss.hlsli"
#include "brdf/toon.hlsli"
#include "brdf/subsurface.hlsli"

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
    case SHADING_PBR_METALLIC:
        return brdf_light_pbr_metallic(surface, light);
    case SHADING_PBR_SPECGLOSS:
        return brdf_light_pbr_specgloss(surface, light);
    case SHADING_TOON:
        return brdf_light_toon(surface, light);
    case SHADING_SUBSURFACE:
        return brdf_light_subsurface(surface, light);
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
    case SHADING_PBR_METALLIC:
        return brdf_resolve_pbr_metallic(surface, total);
    case SHADING_PBR_SPECGLOSS:
        return brdf_resolve_pbr_specgloss(surface, total);
    case SHADING_TOON:
        return brdf_resolve_toon(surface, total);
    case SHADING_SUBSURFACE:
        return brdf_resolve_subsurface(surface, total);
    case SHADING_UNLIT:
    default:
        return brdf_resolve_unlit(surface, total);
    }
}

/*
    Which cluster (light_cull.odin's own `tx + ty*nx + tz*nx*ny` indexing)
    fragment `screen_pos` falls into -- the shader's own half of an agreement
    `cluster_build` (light_cull.odin) already kept when it built
    `cluster_ranges`/`cluster_light_indices` around this exact grid, once per
    frame, on the CPU (see that file's own top comment for why there and not
    in a compute shader). Read only by `shade_lights` below, and only under
    `CLUSTERED` (`cluster_grid.w`) -- computing it under `FORWARD` too would
    be wasted ALU, not a wrong answer, since nothing reads the result there;
    kept unconditional anyway because `shade_surface` calling this once,
    always, is simpler than threading a second branch through its own
    caller.

    Tile x/y come straight from the fragment's own pixel position divided
    into `cluster_grid.x`/`.y` columns/rows -- the same tiling
    `cluster_ndc_range` (light_cull.odin) built cluster boundaries from,
    since a screen pixel and its own NDC coordinate move together regardless
    of projection.

    **The Z slice assumes a perspective camera.** `screen_pos.w` is
    `SV_Position`'s own reciprocal of clip-space w, and clip-space w is
    exactly `-view_z` for the perspective matrix `math3d.odin` writes (that
    file's own top comment: row 3 is `(0, 0, -1, 0)`), so `1 / screen_pos.w`
    recovers the same positive view-space depth `cluster_build` sliced with
    no further work. An orthographic camera's own row 3 is `(0, 0, 0, 1)`,
    so `screen_pos.w` is always 1 there and this always resolves to slice 0
    -- known, not fixed this phase, see `light_cull.odin`'s own top comment
    for why. `cluster_build`'s own CPU-side assignment is correct for both
    projections regardless; only this reconstruction is perspective-only.
*/
uint cluster_index_for_fragment(float4 screen_pos)
{
    uint nx = uint(cluster_grid.x);
    uint ny = uint(cluster_grid.y);
    uint nz = uint(cluster_grid.z);

    uint tile_x = min(uint(screen_pos.x / cluster_camera.x * float(nx)), nx - 1);
    uint tile_y = min(uint(screen_pos.y / cluster_camera.y * float(ny)), ny - 1);

    float near = cluster_camera.z;
    float far  = cluster_camera.w;

    /*
        **Two reconstructions, because `SV_Position.w` carries a depth only
        under a perspective projection.** In a pixel shader that component is
        1/w_clip, so inverting it gives view depth directly -- but an
        orthographic projection's clip w is 1 for every vertex, so the same
        expression yields 1 for every fragment on screen and every one of them
        lands in whichever slice `log(1/near)/log(far/near)` happens to name.
        Not slice 0 necessarily, but one fixed slice, which means a fragment
        reads a light list belonging to some other depth entirely and any
        light outside that slice simply stops lighting it.

        That was a live defect rather than a theoretical one:
        `Camera3D_Projection.ORTHOGRAPHIC` is a supported mode
        (camera3d.odin), and `cluster_test` (light_cull.odin) already builds
        correct parallel-sided cluster boxes for it -- only this lookup was
        perspective-only, so an orthographic scene opting into `CLUSTERED`
        got silently wrong lighting with nothing to point at.

        An orthographic projection's NDC z is linear in view depth, and
        SDL_GPU's depth range is [0, 1], so undoing it is the plain lerp
        below. The exponential slice curve is still what both sides use --
        `cluster_z_bounds` (light_cull.odin) builds bounds with it and this
        inverts the same one, so the two agree by construction. It is merely
        a less useful *distribution* for an orthographic camera, which has no
        perspective compression for it to compensate for; that costs cluster
        resolution, not correctness, and is not worth a second curve until
        something measures it.

        `shadow_caster1.z` is `Camera3D_Projection`'s own ordinal, packed at
        `push_lighting` (lighting.odin) into a component that was two spare
        zeroes -- no `Scene_Frag_Data` size change, and so no packing to
        re-measure.
    */
    float view_depth;
    if (shadow_caster1.z > 0.5)
    {
        view_depth = near + saturate(screen_pos.z) * (far - near);
    }
    else
    {
        view_depth = 1.0 / max(screen_pos.w, 1e-8);
    }

    // The inverse of cluster_z_bounds's own exponential curve
    // (light_cull.odin): solving `near * (far/near)^(slice/count) <= depth`
    // for `slice` gives this log ratio directly.
    float t = log(max(view_depth, near) / near) / log(far / near);
    uint slice = uint(clamp(floor(t * float(nz)), 0.0, float(nz - 1)));

    return tile_x + tile_y * nx + slice * nx * ny;
}

/*
    The light loop itself -- shared, written once, the replacement for every
    model owning its own copy of this. `lighting_rework.md` section 2.1's own
    sketch, unchanged under FORWARD: sample each light, dispatch its
    contribution into the running `Radiance`, then dispatch once more to
    resolve the sums into a colour. No shading model ever appears here by
    name -- this loop only knows the contract (`brdf/contract.hlsli`), not
    which models implement it, which is what keeps a new model from having
    to touch this function.

    **CLUSTERED loops a cluster's own light list instead of every light** --
    P5's one addition, and the only difference between the two pipelines
    anywhere in this file: same `sample_light`, same `brdf_light`, same
    `brdf_resolve`, same `Radiance` accumulation, just a different set of
    indices to iterate. `lighting_rework.md` section 3.6 asks for exactly
    this ("shares the forward fragment path; the only difference is which
    lights it loops over"), and this function is where that promise is kept
    literally rather than approximately.
*/
float3 shade_lights(Surface surface, float4 screen_pos)
{
    Radiance total = (Radiance)0;

    if (cluster_grid.w > 0.5) // CLUSTERED
    {
        Cluster_Range range = cluster_ranges[cluster_index_for_fragment(screen_pos)];

        for (uint j = 0; j < range.count; j++)
        {
            uint         i     = cluster_light_indices[range.offset + j];
            Light_Sample light = sample_light(i, surface);
            Radiance     r     = brdf_light(surface, light);

            total.diffuse  += r.diffuse;
            total.specular += r.specular;
        }
    }
    else // FORWARD
    {
        uint count = uint(flags.x);
        for (uint i = 0; i < count; i++)
        {
            Light_Sample light = sample_light(i, surface);
            Radiance     r     = brdf_light(surface, light);

            total.diffuse  += r.diffuse;
            total.specular += r.specular;
        }
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
float4 shade_surface(Surface surface, float4 screen_pos)
{
    surface.shading_model = flags.y > 0.5 ? surface.shading_model : SHADING_UNLIT;

    float3 color = shade_lights(surface, screen_pos);

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
