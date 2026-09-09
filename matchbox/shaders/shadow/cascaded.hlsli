/*
    Cascaded shadow maps
    ---------------------
    Picks which of up to `MAX_CASCADES` maps covers `world`, then samples it
    exactly the way `shadow/pcf.hlsli` samples its own single map -- CSM's
    only real difference from plain PCF is *which* map a fragment reads, not
    how the read itself works, so `shadow_sample_pcf_array` (declared earlier
    in `lighting_core.hlsli`'s own include order, in `shadow/pcf.hlsli`) is
    reused rather than copied.

    **`Cascade_Data` is this technique's own uniform block**, not part of the
    shared `Scene` cbuffer every technique reads -- see `Cascade_Frag_Data`'s
    own doc comment (lighting.odin) for why splitting it out keeps a scene
    running `PCF`/`PCSS` from paying to push data only this file ever reads.
    `cascade_maps`/`cascade_sampler` are declared by whichever shader
    includes `lighting_core.hlsli` (today, `mesh.frag.hlsl`), the same
    "the including shader owns the actual texture/sampler declarations"
    shape `shadow_map0`/`shadow_sampler0` already have (see `shadow/pcf.hlsli`'s
    own top comment). Since P3b, `cascade_maps` is one `Texture2DArray` with
    `CASCADE_MATRIX_COUNT` layers rather than an HLSL resource array of that
    many flat `Texture2D`s -- one sampler instead of eight, see
    `shadow.odin`'s own doc comment on `Shadow_State` for why the layer this
    file picks is now a slice of one texture rather than a whole texture of
    its own.

    `MAX_CASCADES_HLSL`/`CASCADE_MATRIX_COUNT` below must track
    `MAX_CASCADES`/`MAX_SHADOW_CASTERS` (shadow.odin) exactly -- nothing
    checks that agreement beyond this comment and the fact that getting it
    wrong reads the wrong cascade's matrix rather than failing to compile,
    the same "nothing on this side enforces it" property `shading_model_index`
    already has with `SHADING_*`.
*/

#define MAX_CASCADES_HLSL     4
#define CASCADE_MATRIX_COUNT  8 // MAX_SHADOW_CASTERS (2) * MAX_CASCADES_HLSL (4)

cbuffer Cascade_Data : register(b2, space3)
{
    // [caster][cascade], caster-major and flattened -- Cascade_Frag_Data's
    // own layout (lighting.odin), read here the same way it was written.
    float4x4 cascade_view_projection[CASCADE_MATRIX_COUNT];

    // View-space depth of each cascade's far edge, shared by both caster
    // slots since both are directional lights inside the one camera frustum.
    float4 cascade_splits;

    // x how many cascades are actually configured (<= MAX_CASCADES_HLSL), y-w unused.
    float4 cascade_count;

    /*
        The camera's own forward direction, xyz -- needed to turn `world`
        into a view-space depth for cascade selection below. Carried in this
        technique's own cbuffer rather than the shared `Scene` block for the
        same reason the rest of this data is: PCF/PCSS/CUBE never read it,
        so a scene running any of those never pays to have it pushed.
    */
    float4 camera_forward;
};

/*
    Which of up to `cascade_count.x` cascades `world` falls into, for
    whichever caster slot is asking -- the first whose own `cascade_splits[i]`
    reaches at least as far as `world`'s own view-space depth (distance along
    the camera's forward axis, not straight-line distance to the camera --
    the two agree exactly down the centre of the frustum and diverge toward
    its edges, the same approximation the projection's own depth buffer
    already makes everywhere else in this renderer), or the last configured
    cascade if `world` is beyond every split.

    A point beyond every cascade is not a special case here: that last
    cascade's own `shadow_sample_pcf_array` call fades it to fully lit once
    it falls outside that map's own frustum, the same out-of-range degrade
    every other technique already has -- nothing further needs to happen in
    this function for that case.
*/
int shadow_cascade_index(float3 world)
{
    float view_depth = dot(world - view_pos.xyz, camera_forward.xyz);
    int   count      = int(cascade_count.x);

    for (int i = 0; i < count - 1; i++)
    {
        if (view_depth <= cascade_splits[i])
            return i;
    }

    return max(count - 1, 0);
}

float shadow_visibility_cascaded(int light_index, float3 world, float3 normal)
{
    float2 bias    = lights[light_index].shadow_bias.xy;
    int    cascade = shadow_cascade_index(world);

    if (light_index == int(flags.z))
    {
        int i = 0 * MAX_CASCADES_HLSL + cascade;
        return shadow_sample_pcf_array(cascade_maps, cascade_sampler, i, cascade_view_projection[i], world, normal, bias);
    }
    if (light_index == int(shadow_caster1.x))
    {
        int i = 1 * MAX_CASCADES_HLSL + cascade;
        return shadow_sample_pcf_array(cascade_maps, cascade_sampler, i, cascade_view_projection[i], world, normal, bias);
    }
    return 1.0;
}
