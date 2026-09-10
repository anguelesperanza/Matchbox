/*
    Cube shadow maps
    -----------------
    A point light's own shadow -- six depth maps around it, one per cube
    face, rather than the one map every directional/spot technique reads.
    See `shadow_cube.odin`'s own top comment for why these are six layers of
    one `Texture2DArray` rather than either six separate `Texture2D`s (P3's
    own shape) or a real `TextureCube`, and for the face convention
    `shadow_cube_face_index` below mirrors exactly.

    **Not one more case in `Shadow_Technique`'s switch.** `shadow_visibility`
    (`lighting_core.hlsli`) checks whether `light_index` is the cube caster
    *before* it ever looks at `shadow_caster1.y` (the scene's PCF/PCSS/
    CASCADED choice) -- a point light was never eligible for that switch's
    other three cases, so routing it there first, unconditionally, is what
    lets a scene run cascaded shadows for its sun and a real shadow for a
    point-light torch at the same time. See `Shadow_Technique`'s own doc
    comment (shadow.odin) for the fuller reasoning.

    Reuses `shadow_sample_pcf_array` (`shadow/pcf.hlsli`) for the actual depth
    compare, the same way `shadow/cascaded.hlsli` does -- picking the right
    face and matrix is this file's entire job, not a new comparison
    algorithm. `cube_maps`/`cube_sampler` (one `Texture2DArray`, six layers)
    are declared by whichever shader includes `lighting_core.hlsli` (today,
    `mesh.frag.hlsl`), the same shape `cascade_maps`/`cascade_sampler`
    already have.
*/

#define CUBE_FACE_COUNT 6

// `cube_view_projection` and `cube_caster` live in `shadow/cascaded.hlsli`'s
// own `Shadow_Data` block now, which lighting_core.hlsli includes first --
// see that declaration for why the two techniques share one cbuffer. Nothing
// is declared here; the names simply resolve.

/*
    Which of the six faces a direction away from the light falls into --
    mirrors `shadow_cube_face_index` (shadow_cube.odin) exactly: same
    major-axis test, same tie-break (`>=`, x then y then z), since the two
    must agree on which face wins a tie or this would sample a face whose
    depth was never rendered from this direction at all.
*/
int shadow_cube_face_index(float3 direction)
{
    float ax = abs(direction.x);
    float ay = abs(direction.y);
    float az = abs(direction.z);

    if (ax >= ay && ax >= az) return direction.x > 0.0 ? 0 : 1;
    if (ay >= ax && ay >= az) return direction.y > 0.0 ? 2 : 3;
    return direction.z > 0.0 ? 4 : 5;
}

/*
    `light_index` is checked against `cube_caster.x` rather than against a
    two-slot array the way `shadow_visibility_pcf` checks `flags.z`/
    `shadow_caster1.x` -- `MAX_POINT_SHADOW_CASTERS` is 1 (shadow.odin), so
    there is only ever the one to compare against.
*/
float shadow_visibility_cube(int light_index, float3 world, float3 normal)
{
    if (light_index != int(cube_caster.x))
        return 1.0;

    float2 bias           = lights[light_index].shadow_bias.xy;
    float3 light_position = lights[light_index].position.xyz;
    int    face           = shadow_cube_face_index(world - light_position);

    return shadow_sample_pcf_array(cube_maps, cube_sampler, face, cube_view_projection[face], world, normal, bias);
}
