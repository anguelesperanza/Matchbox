/*
    SSAO -- how much of the sky each pixel can actually see
    -------------------------------------------------------
    Reads this frame's depth buffer and writes a single-channel occlusion
    factor: 1 where a point is open to the sky, falling toward 0 in a crease.
    `shade_surface` (lighting_core.hlsli) multiplies it into
    `Surface.occlusion`, which is the only thing every BRDF's ambient term
    has ever been scaled by -- see `ssao.odin`'s own top comment for why this
    is lighting rather than post, and for what it cannot know.

    **Depth is the only input, and normals are reconstructed from it.** Under
    `DEFERRED` a real world-space normal is sitting in the G-buffer and would
    be better at silhouettes; using it would mean this shader had two versions
    or a branch on a pipeline it otherwise knows nothing about, and one of
    `lighting_plan.md`'s standing requirements is that a module not assume a
    pipeline upstream. So: one input, one code path, three pipelines. What it
    costs is stated at `reconstruct_normal` below rather than hidden.

    **Position comes back through the inverse view-projection**, the same way
    `deferred_lighting.frag.hlsl` reconstructs it, rather than through a
    linear-depth formula built from near and far. That is not a stylistic
    match: a linear-depth reconstruction has to know whether the projection
    was perspective or orthographic and gets an entire frame silently wrong
    if it guesses (`lighting_rework.md` section 5 records that happening to
    `cluster_index_for_fragment` in P5). An inverse matrix does not care.

    Must match matchbox.Ssao_Frag_Data.
*/

// Must equal matchbox.MAX_SSAO_SAMPLES -- a fixed compile-time number that
// only this comment keeps in step with the Odin side, the same shape
// MAX_CASCADES/MAX_CASCADES_HLSL already has.
#define MAX_SSAO_SAMPLES_HLSL 32

cbuffer FragData : register(b0, space3)
{
    float4x4 inverse_view_projection;
    float4x4 view_projection;

    float4 camera;  // xyz eye position,      w sample count
    float4 forward; // xyz camera forward,    w radius, in world units
    float4 params;  // x bias, y intensity,   zw one texel of the AO target, in uv
    float4 screen;  // xy AO target size in pixels, z 1 when orthographic, w unused

    float4 kernel[MAX_SSAO_SAMPLES_HLSL]; // xyz a tap in +Z hemisphere space
};

Texture2D<float> depth_map : register(t0, space2);
SamplerState     depth_smp : register(s0, space2);

/*
    A depth-buffer texel back to the world point that wrote it.

    The z the depth buffer holds is already in clip space's own [0, 1] range
    on every backend SDL_GPU offers (this is the D3D convention, which its
    Vulkan backend normalizes to -- the same convention quad.vert.hlsl's own
    y-negation comment describes), so it goes straight into the clip position
    with no remap. The perspective divide afterward is what makes this work
    for a perspective camera; for an orthographic one w is 1 and the divide
    is a no-op, which is exactly why this shape needs no branch on the
    projection at all.
*/
float3 world_from_depth(float2 uv, float raw_depth)
{
    // uv is top-down and clip space is y-up, hence the negation -- the same
    // flip quad.vert.hlsl applies going the other way.
    float4 clip = float4(uv.x * 2.0 - 1.0, 1.0 - uv.y * 2.0, raw_depth, 1.0);
    float4 world = mul(inverse_view_projection, clip);

    return world.xyz / world.w;
}

// How far along the camera's own forward axis a world point sits. Used
// instead of the distance to the eye because that is what a depth comparison
// actually wants: two points side by side at the same distance from the eye
// are at the same depth only under a spherical projection, and neither of
// this package's two projections is one.
float view_depth(float3 world)
{
    return dot(world - camera.xyz, forward.xyz);
}

/*
    A surface normal from the depth buffer alone.

    The naive version is `cross(ddx(P), ddy(P))`, and it produces a bright rim
    of wrong normals along every silhouette: at a depth discontinuity one of
    those two derivatives spans the gap and describes a surface that is not
    there. This is the standard improvement -- take both neighbours on each
    axis and keep whichever is closer in depth to the centre, so the
    derivative is taken *along* the surface rather than across the edge of it.

    Four extra depth taps for it. Still an approximation: a one-pixel-wide
    feature has no correct answer here at all, and a surface nearly edge-on to
    the camera reconstructs poorly because its neighbours are many world units
    away. A G-buffer normal would have neither problem, and would cost this
    module its independence from which pipeline drew the frame.
*/
float3 reconstruct_normal(float2 uv, float3 center, float center_depth)
{
    float2 texel = params.zw;

    float dl = depth_map.Sample(depth_smp, uv - float2(texel.x, 0)).r;
    float dr = depth_map.Sample(depth_smp, uv + float2(texel.x, 0)).r;
    float du = depth_map.Sample(depth_smp, uv - float2(0, texel.y)).r;
    float dd = depth_map.Sample(depth_smp, uv + float2(0, texel.y)).r;

    float3 left  = world_from_depth(uv - float2(texel.x, 0), dl);
    float3 right = world_from_depth(uv + float2(texel.x, 0), dr);
    float3 up    = world_from_depth(uv - float2(0, texel.y), du);
    float3 down  = world_from_depth(uv + float2(0, texel.y), dd);

    // Whichever neighbour is nearer the centre in view depth is the one on
    // the same surface. Written as a difference of view depths rather than of
    // raw depth values because raw depth is nonlinear under a perspective
    // projection, so comparing two raw gaps compares nothing meaningful.
    float3 dx = abs(view_depth(right) - center_depth) < abs(view_depth(left) - center_depth)
        ? (right - center) : (center - left);
    float3 dy = abs(view_depth(down) - center_depth) < abs(view_depth(up) - center_depth)
        ? (down - center) : (center - up);

    float3 n = cross(dx, dy);

    // A cross product's sign depends on which pair happened to be picked
    // above, so the result is flipped toward the camera rather than trusted.
    // A normal pointing away from the eye would invert the whole hemisphere
    // and turn occlusion into its own opposite.
    if (dot(n, forward.xyz) > 0.0) n = -n;

    return normalize(n);
}

/*
    Interleaved gradient noise -- one rotation angle per pixel, from the pixel
    position alone.

    A noise *texture* is the classic way to do this and would cost a sampler
    slot, an upload, and a decision about its wrap mode. This is a hash: the
    same three constants every implementation of it uses, chosen so that the
    values decorrelate across a 3x3 neighbourhood, which is what lets the blur
    pass average the noise out over a small kernel rather than a large one.

    Without a per-pixel rotation, every pixel samples the identical hemisphere
    directions and the result is not noise but banding -- visible, structured
    arcs that no blur removes.
*/
float interleaved_gradient_noise(float2 pixel)
{
    return frac(52.9829189 * frac(0.06711056 * pixel.x + 0.00583715 * pixel.y));
}

float4 main(float4 pos : SV_Position, float2 uv : TEXCOORD0) : SV_Target0
{
    float raw = depth_map.Sample(depth_smp, uv).r;

    // Nothing was drawn here -- the far plane, which under this package's
    // reversed-nothing convention is 1. The sky is not occluded by anything
    // and must not darken, so this returns before any of the sampling below.
    if (raw >= 1.0) return float4(1, 1, 1, 1);

    float3 center       = world_from_depth(uv, raw);
    float  center_depth = view_depth(center);
    float3 normal       = reconstruct_normal(uv, center, center_depth);

    /*
        A basis with `normal` as +Z, so the kernel -- which is written in
        +Z-hemisphere space (`ssao_kernel`, ssao.odin) -- lands on the correct
        side of the surface. `up` is picked away from the normal so the cross
        product never degenerates: a fixed up-vector parallel to the normal
        gives a zero-length tangent and a NaN basis, which on a floor
        (normal +Y) is not an edge case but the common case.
    */
    float3 up      = abs(normal.z) < 0.999 ? float3(0, 0, 1) : float3(1, 0, 0);
    float3 tangent = normalize(cross(up, normal));
    float  angle   = interleaved_gradient_noise(pos.xy) * 6.2831853;

    // The per-pixel rotation, applied to the basis rather than to each of the
    // kernel's taps -- one sin/cos per pixel instead of one per tap, for the
    // identical result.
    float s = sin(angle), c = cos(angle);
    float3 t = tangent * c + cross(normal, tangent) * s;
    float3 b = cross(normal, t);

    float radius    = forward.w;
    float bias      = params.x;
    float intensity = params.y;

    uint  count     = uint(camera.w);
    float occlusion = 0.0;

    for (uint i = 0; i < count; i++)
    {
        float3 offset = kernel[i].xyz;
        float3 sample_world = center + (t * offset.x + b * offset.y + normal * offset.z) * radius;

        // Where that point lands on screen, and how deep it would be if
        // nothing were in front of it.
        float4 clip = mul(view_projection, float4(sample_world, 1.0));
        if (clip.w <= 0.0) continue; // behind the camera under a perspective projection

        float2 sample_uv = clip.xy / clip.w;
        sample_uv = float2(sample_uv.x * 0.5 + 0.5, 0.5 - sample_uv.y * 0.5);

        // Off screen is unknowable rather than unoccluded, but treating it as
        // occluded darkens the whole border of the frame. Skipped, which
        // biases the edges toward "open" -- the lesser of the two artifacts
        // and the one every screen-space method settles for.
        if (any(sample_uv < 0.0) || any(sample_uv > 1.0)) continue;

        float scene_raw = depth_map.Sample(depth_smp, sample_uv).r;
        if (scene_raw >= 1.0) continue; // sky: nothing there to occlude with

        float scene_depth  = view_depth(world_from_depth(sample_uv, scene_raw));
        float sample_depth = view_depth(sample_world);

        /*
            Occluded when whatever the scene actually holds at that pixel is
            nearer the camera than the point we asked about -- something is in
            the way. `bias` is what stops a flat surface from occluding itself
            through the reconstruction's own error.

            **Scaled by distance**, because that error is not constant: one
            texel of the depth buffer covers more world space the further away
            it is, so a position reconstructed from it is proportionally less
            exact -- and a flat surface seen at a grazing angle is the case
            where neighbouring texels are furthest apart and the reconstruction
            is worst. A fixed bias tuned to look right up close leaves that
            surface self-occluding in a pattern further away. Linear in view
            depth, floored at 1 so a surface right against the camera is not
            handed a bias smaller than the one that was asked for.

            The range check is what keeps a wall two metres behind a railing
            from being reported as occluding it: the further apart the two
            depths are, the less this tap counts, falling to nothing once the
            gap exceeds the sampling radius. Without it a foreground object
            draws a dark halo on everything behind it.
        */
        float scaled_bias = bias * max(center_depth, 1.0);

        if (scene_depth < sample_depth - scaled_bias)
        {
            float range = saturate(radius / max(abs(center_depth - scene_depth), 1e-4));
            occlusion += range;
        }
    }

    float ao = 1.0 - (occlusion / max(float(count), 1.0)) * intensity;
    return float4(saturate(ao).xxxx);
}
