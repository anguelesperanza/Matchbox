/*
    G-buffer packing
    -----------------
    The four render targets the G-buffer fill pass (`gbuffer.frag.hlsl`)
    writes and the deferred lighting pass (`deferred_lighting.frag.hlsl`)
    reads back -- the shared "how" both ends of P6's own MRT boundary have
    to agree on byte for byte, the same role `shadow/contract.hlsli` plays
    for a shadow technique and `brdf/contract.hlsli` for a shading model.
    Assumes `surface.hlsli` and `brdf/contract.hlsli` are already visible --
    it declares neither itself, the same "the including shader owns the
    actual declarations" shape `shadow/pcf.hlsli` already has for
    `shadow_map0` (see `lighting_core.hlsli`'s own top comment) -- so this is
    included after `lighting_core.hlsli` (deferred_lighting.frag.hlsl) or
    after `surface.hlsli`/`brdf/contract.hlsli` directly (gbuffer.frag.hlsl,
    which wants neither the light loop nor the Scene cbuffer this file's
    other includer needs).

    **Four targets, not one per `Surface` field, because Vulkan's own
    guaranteed floor for simultaneous colour attachments is 4**
    (`MAX_COLOR_TARGETS`, init.odin -- see that constant's own doc comment
    for why this package pins against Vulkan's floor rather than a desktop
    driver's higher, actual number). `Surface` carries more scalars than 4
    RGBA16 targets have channels for if every one gets its own -- so the
    `param` group below packs several *mutually exclusive* per-model scalars
    into the same four floats, the way `Material_Frag_Data` (material.odin)
    already packs `specular`/`emissive`/`params`/`subsurface` into one flat
    cbuffer for the identical reason: exactly one shading model ever runs
    for a given pixel, so the other five models' own fields cost nothing to
    overlap rather than each reserving a channel of their own. The layout:

        GB_A: base_color.rgb, occlusion
        GB_B: normal (octahedral, 2 channels), shading_model, param.x
        GB_C: emissive.rgb, param.y
        GB_D: param.z, param.w, reserved (0), reserved (0)

    `param`'s meaning, keyed by `Surface.shading_model` (`shading.odin`'s own
    ordinals, `SHADING_*` in `brdf/contract.hlsli`) -- the maximum any one
    model needs is 4 floats (spec-gloss's `specular.xyz` + `glossiness`, or
    subsurface's `subsurface.xyz` + `thickness`), which is exactly what
    `param.x/y/z/w` provides regardless of which physical target each half
    of it actually lands in:

        BLINN_PHONG:   x = specular_power                     y/z/w unused
        UNLIT:         (nothing read)
        PBR_METALLIC:  x = metallic          y = roughness     z/w unused
        PBR_SPECGLOSS: x/y/z = specular.rgb  w = glossiness
        TOON:          x = bands             y = rim           z/w unused
        SUBSURFACE:    x/y/z = subsurface.rgb  w = thickness

    GB_D's own two reserved channels are written 0 and never read -- room
    for a field a later phase adds without a fifth target, the same "rides
    along unread" shape `Light.cone` already has for a light that is not a
    spot.

    **Not stored at all, because they are cheaper to reconstruct than to
    write:**

    - `Surface.position` -- rebuilt by the lighting pass from its own sampled
      depth target and the inverse view-projection matrix
      (`Deferred_Lighting_Frag_Data.inverse_view_projection`,
      `deferred_lighting.frag.hlsl`) rather than a fifth target. The
      standard deferred-shading trade: a position target is three more
      channels bought back for one matrix-vector multiply per pixel, on a
      pass that is already the frame's one fullscreen draw regardless.
    - `Surface.view` -- `normalize(view_pos.xyz - position)` once `position`
      above is known; `view_pos` already rides in the `Scene` cbuffer every
      mesh fragment shader (and now this pass) declares.
    - `Surface.alpha` -- deferred is opaque-only by construction (see
      `Material.transparent`, material.odin, for the forward fallback), so
      the lighting pass always resolves at alpha 1 and this is never read.

    **Sentinel, not a fifth target or a stencil bit, for "no geometry
    here".** `GBUFFER_EMPTY` is what the G-buffer fill pass's own colour
    clear puts in GB_B's `shading_model` channel, and no real
    `Shading_Model` ordinal is ever negative -- `deferred_lighting.frag.hlsl`
    discards on exactly that value, which is what lets whatever the final
    HDR pass already painted (the skybox, most of the time) show through
    where nothing was drawn into the G-buffer, rather than the lighting pass
    overwriting every pixel unconditionally. See `pipeline_deferred.odin`'s
    own top comment for the pass ordering this depends on.

    Every target is `R16G16B16A16_FLOAT`. A signed floating-point range is
    what lets octahedral-encoded normals (below) live here with no [-1,1] ->
    [0,1] remap a `UNORM` target would need, and it is more precision than
    any field here needs to round-trip cleanly -- `gbuffer_test.odin`'s own
    sweep is the measurement, not this sentence.
*/

#define GBUFFER_EMPTY -1.0

/*
    Octahedral normal encoding (Cigolle et al. 2014's "signed" variant,
    building on Meyer et al. 2010's projection) -- a unit vector as two
    floats instead of three, which is what makes normal + shading_model +
    one model-specific scalar fit in a single RGBA target (GB_B above).

    **The method.** Project the sphere onto the octahedron |x|+|y|+|z|=1 by
    dividing by the L1 norm, then unfold the octahedron's lower half (`n.z <
    0`) flat by reflecting each fold across the diagonal it hinges on --
    `OctWrap` in the cited survey's own listing, inlined here as the
    `signs`/`abs(p.yx)` line below. `gbuffer_decode_normal` undoes exactly
    that, not an approximation of it: `gbuffer_test.odin`'s round-trip
    sweep is checked against normals generated independently (Python, not
    this file, not this file's own Odin mirror), so the residual it finds
    is the encoding's own geometric error at `R16G16B16A16_FLOAT` precision,
    not a transcription mismatch between this file and its test.

    No [-1,1] -> [0,1] remap either direction, unlike the survey's own
    listing -- that step exists only because the reference stores into a
    `UNORM` target, and this package's G-buffer does not (this file's own
    top comment).
*/
float2 gbuffer_encode_normal(float3 n)
{
    float  l1 = abs(n.x) + abs(n.y) + abs(n.z);
    float3 p3 = n / max(l1, 1e-8);
    float2 p  = p3.xy;

    if (p3.z < 0.0)
    {
        float2 signs = float2(p.x >= 0.0 ? 1.0 : -1.0, p.y >= 0.0 ? 1.0 : -1.0);
        p = (1.0 - abs(p.yx)) * signs;
    }

    return p;
}

float3 gbuffer_decode_normal(float2 p)
{
    float3 n = float3(p.x, p.y, 1.0 - abs(p.x) - abs(p.y));

    float  t     = saturate(-n.z);
    float2 signs = float2(n.x >= 0.0 ? 1.0 : -1.0, n.y >= 0.0 ? 1.0 : -1.0);
    n.xy -= t * signs;

    return normalize(n);
}

// The four targets, named the way `PSOutput`/the lighting pass's own texture
// declarations refer to them -- one struct so `gbuffer_encode`/`gbuffer_decode`
// below are the one place either side of the boundary has to change together.
struct Gbuffer_Encoded
{
    float4 a; // base_color.rgb, occlusion
    float4 b; // normal.xy (octahedral), shading_model, param.x
    float4 c; // emissive.rgb, param.y
    float4 d; // param.z, param.w, reserved, reserved
};

/*
    `Surface` -> the four targets above. `surface.position`/`.view`/`.alpha`
    are never read -- see this file's own top comment for why the lighting
    pass reconstructs or hardcodes each instead.
*/
Gbuffer_Encoded gbuffer_encode(Surface surface)
{
    float param_x = 0.0, param_y = 0.0, param_z = 0.0, param_w = 0.0;

    switch (surface.shading_model)
    {
    case SHADING_BLINN_PHONG:
        param_x = surface.specular_power;
        break;
    case SHADING_PBR_METALLIC:
        param_x = surface.metallic;
        param_y = surface.roughness;
        break;
    case SHADING_PBR_SPECGLOSS:
        param_x = surface.specular.x;
        param_y = surface.specular.y;
        param_z = surface.specular.z;
        param_w = surface.glossiness;
        break;
    case SHADING_TOON:
        param_x = surface.bands;
        param_y = surface.rim;
        break;
    case SHADING_SUBSURFACE:
        param_x = surface.subsurface.x;
        param_y = surface.subsurface.y;
        param_z = surface.subsurface.z;
        param_w = surface.thickness;
        break;
    case SHADING_UNLIT:
    default:
        break; // nothing extra to carry
    }

    Gbuffer_Encoded g;
    g.a = float4(surface.base_color, surface.occlusion);
    g.b = float4(gbuffer_encode_normal(surface.normal), float(surface.shading_model), param_x);
    g.c = float4(surface.emissive, param_y);
    g.d = float4(param_z, param_w, 0.0, 0.0);
    return g;
}

/*
    The four targets, plus the position and view the lighting pass already
    worked out from depth and the camera, -> a `Surface` ready for
    `shade_surface`. `position`/`view` are taken as arguments rather than
    reconstructed in here, so this function stays a pure decode of the four
    targets and the one place that math lives is
    `deferred_lighting.frag.hlsl` itself.
*/
Surface gbuffer_decode(Gbuffer_Encoded g, float3 position, float3 view)
{
    Surface s = (Surface)0;

    s.position = position;
    s.view     = view;
    s.normal   = gbuffer_decode_normal(g.b.xy);

    s.base_color = g.a.rgb;
    s.alpha      = 1.0; // deferred is opaque-only -- see this file's own top comment
    s.occlusion  = g.a.a;

    s.emissive = g.c.rgb;

    s.shading_model = uint(round(g.b.z));

    float param_x = g.b.w;
    float param_y = g.c.a;
    float param_z = g.d.x;
    float param_w = g.d.y;

    switch (s.shading_model)
    {
    case SHADING_BLINN_PHONG:
        s.specular_power = param_x;
        break;
    case SHADING_PBR_METALLIC:
        s.metallic  = param_x;
        s.roughness = param_y;
        break;
    case SHADING_PBR_SPECGLOSS:
        s.specular   = float3(param_x, param_y, param_z);
        s.glossiness = param_w;
        break;
    case SHADING_TOON:
        s.bands = param_x;
        s.rim   = param_y;
        break;
    case SHADING_SUBSURFACE:
        s.subsurface = float3(param_x, param_y, param_z);
        s.thickness  = param_w;
        break;
    case SHADING_UNLIT:
    default:
        break;
    }

    return s;
}
