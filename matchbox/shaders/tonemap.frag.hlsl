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

    // How much of `bloom` below is added back. 0 whenever bloom is off, which
    // is what makes the 1x1 black placeholder bound at t1 in that case cost
    // nothing but the sample -- see resolve_tonemap (tonemap.odin).
    float bloom_intensity;

    // 1 when Color_Grade.enabled, 0 otherwise. A uniform branch, the same
    // shape shade_surface's own model dispatch is -- see lighting_core.hlsli.
    float grade_enabled;

    // xyz each; w unused. See color_grade below for the order they run in and
    // why every one of them is a delta from identity rather than a factor.
    float4 grade_lift;
    float4 grade_gamma;
    float4 grade_gain;

    float grade_contrast;
    float grade_saturation;
    float2 _pad;
};

Texture2D<float4> tex : register(t0, space2);
SamplerState      smp : register(s0, space2);

// Level 0 of the bloom chain (bloom.odin), at half the scene's resolution --
// sampled with the same linear clamped sampler the chain itself was built
// with, so the upscale back to full resolution is the bilinear filter rather
// than another pass. 1x1 black when bloom is off.
Texture2D<float4> bloom     : register(t1, space2);
SamplerState      bloom_smp : register(s1, space2);

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

/*
    Colour grading -- lift/gamma/gain, then contrast, then saturation.

    **Runs after the tonemap curve and before the gamma encode**, on a value
    already compressed into [0, 1]. That is a decision, not an accident: lift,
    gamma, gain and a contrast pivot are all display-referred operations by
    definition -- "contrast around mid grey" means nothing when the input is
    unbounded scene light and mid grey could be 0.5 or 500. Grading here also
    means a game's grade composes the same way with every `Tonemap` curve,
    since all four hand this the same range. See `color_grade_apply`
    (post.odin), which mirrors this statement for statement, and `Color_Grade`
    itself for what the alternative (grading in linear HDR before the curve)
    would have bought and cost.

    **Every field is a delta from identity, so an all-zero `Color_Grade` is
    an exact no-op.** That is why this reads `1.0 + grade_gain` rather than
    `grade_gain`: a partial composite literal naming only the two fields a
    game cares about leaves the rest zero, and a zero *factor* would be a
    black screen -- the exact trap `lighting_settings_normalized`'s own doc
    comment (lighting.odin) exists to describe. Expressing them as deltas
    removes the trap by construction rather than papering over it with a
    sentinel that would then collide with a legitimate zero (a fully
    desaturated grade is a real thing to want).
*/
float3 color_grade(float3 c)
{
    c = c * (1.0 + grade_gain.rgb) + grade_lift.rgb;

    // Lift can legitimately push a channel negative and pow() of a negative
    // is undefined. Applied whether or not the pow below runs, so that
    // skipping it changes nothing but the pow.
    c = max(c, 0.0);

    /*
        Skipped entirely at the zero value, and not as an optimization:
        pow(x, 1) is exp2(log2(x)) and does not return x exactly, which would
        make Color_Grade's zero value a nearly-no-op rather than the exact one
        its whole design rests on. See color_grade_apply (post.odin), which
        skips it the same way and for the same reason. The branch is uniform.

        max() on the exponent's divisor, because a gamma delta at or below -1
        would otherwise divide by zero or flip the curve inside out.
    */
    if (any(grade_gamma.rgb != 0.0))
    {
        c = pow(c, 1.0 / max(1.0 + grade_gamma.rgb, 1e-4));
    }

    /*
        Written as a delta rather than as (c - 0.5) * (1 + contrast) + 0.5,
        which is the same arithmetic and is not an identity at zero: going out
        to -0.499 and back loses the low bits of a small channel. Same
        multiply-add either way. See color_grade_apply (post.odin) for the
        algebra and for why the exactness is the point.
    */
    c = c + (c - 0.5) * grade_contrast;

    // Rec. 709 luminance, matching the primaries everything else in this
    // package assumes -- desaturating toward a flat average of the three
    // channels instead would turn a saturated blue lighter than a saturated
    // green, which is backwards.
    float luma = dot(c, float3(0.2126, 0.7152, 0.0722));

    // The same delta form, for the same reason -- lerp(luma, c, 1 + s) is the
    // usual spelling and cancels the same way at s = 0.
    c = c + (c - luma) * grade_saturation;

    return c;
}

float4 main(float4 pos : SV_Position, float2 uv : TEXCOORD0) : SV_Target0
{
    float3 color = tex.Sample(smp, uv).rgb;

    // Bloom is added before exposure, not after: it is scene light that spilled
    // inside a lens, so it belongs on the same side of the exposure multiply as
    // the light it spilled from. Adding it afterward would mean turning the
    // exposure down brightened the bloom relative to the scene.
    color += bloom.Sample(bloom_smp, uv).rgb * bloom_intensity;

    color = max(color * exposure, 0.0);

    switch (int(tonemap))
    {
    case TONEMAP_REINHARD: color = tonemap_reinhard(color); break;
    case TONEMAP_ACES:     color = tonemap_aces(color);     break;
    case TONEMAP_AGX:      color = tonemap_agx(color);      break;
    case TONEMAP_NONE:
    default:               color = tonemap_none(color);     break;
    }

    // saturate() after the grade rather than trusting it to stay in range:
    // every curve above already hands over a [0, 1] value, but lift, contrast
    // and a saturation boost can each push back out of it, and pow() of a
    // negative below is a NaN that spreads. A no-op when grading is off.
    if (grade_enabled > 0.5)
    {
        color = saturate(color_grade(color));
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
