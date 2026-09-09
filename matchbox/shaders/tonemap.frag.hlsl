/*
    HDR resolve -- tonemap and gamma encode
    ----------------------------------------
    The other half of `lighting_rework.md` section 3.7's split. The 3D pass
    (`mesh.frag.hlsl`, `mesh_line.frag.hlsl`, `skybox_panorama.frag.hlsl`,
    `skybox_cubemap.frag.hlsl`) writes pure linear light into an
    `RGBA16_FLOAT` scene target and never encodes anything -- see
    `lighting_core.hlsli`'s own `shade_surface` doc comment for why that
    encode used to live there, per shading model, and had to leave. This is
    the one place it happens now: exposure, one of four tonemap curves, then
    the same 1/2.2 gamma every colour in this package has always used.

    Takes the shared `quad.vert` vertex shader, same as `post.frag.hlsl`,
    `psx.frag.hlsl` and `vhs.frag.hlsl` -- but unlike those, which are a
    `Post_Effect` a game opts a `Render_Target` into, this runs
    unconditionally, once per 3D pass, over the internal HDR target
    `Renderer.lighting.targets` (`tonemap.odin`) owns.

    Mirrors `matchbox/tonemap.odin`'s `tonemap_apply` and its own helpers,
    statement for statement -- deliberately, so `tonemap_test.odin`'s
    numbers are also a check on the *intended* arithmetic here, since there
    is no GPU capture tooling in this environment to check the compiled
    shader itself against. A change to the arithmetic on one side without
    the matching change here is wrong lighting for every future tonemap
    edit, silently, so keep the two textually parallel rather than merely
    equivalent.

    Must match matchbox.Tonemap_Resolve_Frag_Data.
*/

#define TONEMAP_NONE     0
#define TONEMAP_REINHARD 1
#define TONEMAP_ACES     2
#define TONEMAP_AGX      3

cbuffer FragData : register(b0, space3)
{
    float exposure;
    float tonemap;
    float2 _pad;
};

Texture2D<float4> tex : register(t0, space2);
SamplerState      smp : register(s0, space2);

// Tonemap.NONE -- not a no-op, see that enum value's own doc comment
// (lighting.odin) for why clamping to [0, 1] here is what makes every curve
// hand the final gamma step the same range to work with.
float3 tonemap_none(float3 c)
{
    return saturate(c);
}

float3 tonemap_reinhard(float3 c)
{
    return c / (1.0 + c);
}

// Narkowicz's fit to the ACES filmic reference curve -- see
// tonemap_aces_channel's own comment in tonemap.odin.
float3 tonemap_aces(float3 c)
{
    const float a = 2.51, b = 0.03, cc = 2.43, d = 0.59, e = 0.14;
    return saturate((c * (a * c + b)) / (c * (cc * c + d) + e));
}

/*
    The per-channel half of a minimal AgX -- log2-encode into Sobotka's own
    EV window, normalize, then a polynomial fit to AgX's default contrast
    sigmoid. Mirrors tonemap_agx_channel (tonemap.odin) exactly; see that
    proc's own comment for the epsilon floor below log2 and why it does not
    need to agree bit-for-bit with HLSL's own log2(0) behaviour to be safe.
*/
float agx_channel(float x)
{
    const float min_ev = -12.47393;
    const float max_ev = 4.026069;

    float v = log2(max(x, 1e-10));
    v = clamp(v, min_ev, max_ev);
    v = (v - min_ev) / (max_ev - min_ev);

    float v2 = v * v;
    float v4 = v2 * v2;
    v = 15.5 * v4 * v2 - 40.14 * v4 * v + 31.96 * v4 - 6.868 * v2 * v + 0.4298 * v2 + 0.1191 * v - 0.00232;

    return saturate(v);
}

/*
    A minimal approximation of Troy Sobotka's AgX -- the inset matrix and the
    log2/contrast pipeline (agx_channel) only, not AgX's own outset matrix or
    display transform. See tonemap_agx's own doc comment in tonemap.odin for
    what that leaves out and why it is a stated gap rather than a silent one.

    Written as three explicit dot products rather than a float3x3, so this
    and tonemap.odin's own tonemap_agx cannot silently disagree on which is
    being multiplied -- HLSL's default row-major storage and Odin's array-of-
    arrays matrix layout are not the same convention, and getting that wrong
    is a wrong-looking-sky bug rather than one that fails to compile (see
    skybox_cubemap.frag.hlsl's own left-handed sampling comment for the same
    lesson learned once already).
*/
float3 tonemap_agx(float3 c)
{
    float r = 0.842479062253094  * c.r + 0.0784335999999992 * c.g + 0.0792237451477643 * c.b;
    float g = 0.0423282422610123 * c.r + 0.878468636469772  * c.g + 0.0791661274605434 * c.b;
    float b = 0.0423756549057051 * c.r + 0.0784336           * c.g + 0.879142973793104  * c.b;

    return float3(agx_channel(r), agx_channel(g), agx_channel(b));
}

float4 main(float4 pos : SV_Position, float2 uv : TEXCOORD0) : SV_Target0
{
    float3 color = max(tex.Sample(smp, uv).rgb * exposure, 0.0);

    switch (int(tonemap))
    {
    case TONEMAP_REINHARD: color = tonemap_reinhard(color); break;
    case TONEMAP_ACES:     color = tonemap_aces(color);     break;
    case TONEMAP_AGX:      color = tonemap_agx(color);      break;
    case TONEMAP_NONE:
    default:               color = tonemap_none(color);     break;
    }

    // The shared final step, after whichever curve ran -- 1/2.2 rather than
    // the real sRGB piecewise transfer function, matching every colour
    // already tuned against that constant elsewhere in this package. Alpha
    // is always 1: this resolve writes opaque across the whole viewport, the
    // same as draw_post (render_target.odin) already does for the same
    // reason -- whatever transparency happened inside the 3D pass is already
    // resolved into the HDR target's own colour by the time this runs.
    color = pow(color, 1.0 / 2.2);
    return float4(color, 1.0);
}
