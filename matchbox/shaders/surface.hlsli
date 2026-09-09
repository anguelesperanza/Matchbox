/*
    Surface
    -------
    Everything a BRDF needs to know about one point, with nothing in it about
    how that point was reached. A forward fragment shader (today, the only
    kind this package has) fills one from interpolants and texture samples; a
    future deferred lighting pass would fill the identical struct from
    G-buffer reads instead. No `brdf_light_*`/`brdf_resolve_*` in any shading
    model's own .hlsli (`brdf/contract.hlsli`) ever learns which of the two
    happened -- that is the property that lets a shading model be written
    once and used from any render pipeline, see `lighting_rework.md`
    section 3.2.

    **Must also be fillable from a 2D sprite fragment**, even though that is
    P8's work and not this phase's. That is a decision made now rather than
    later (`lighting_rework.md` section 7.3) and it constrains this struct:
    no field here may assume a 3D mesh produced it. A sprite would fill
    `position` with its world position at z = 0, `normal` with {0, 0, 1} or
    its own normal map, and `view` with the 2D camera's forward -- every field
    below already accepts those values, so nothing needs to change when that
    phase arrives.

    Fields a given shading model does not use ride along unread, the same way
    `Light_Uniform.cone` already does for a light that is not a spot.
*/
struct Surface
{
    float3 position; // world
    float3 normal;   // world, normalized, normal map already applied
    float3 view;     // normalized, toward the eye

    float3 base_color;
    float  alpha;

    float  metallic;   // metallic-roughness (brdf/pbr_metallic.hlsli)
    float  roughness;  // metallic-roughness (brdf/pbr_metallic.hlsli)
    float3 specular;   // specular-glossiness (brdf/pbr_specgloss.hlsli)
    float  glossiness; // specular-glossiness (brdf/pbr_specgloss.hlsli)

    float3 emissive;
    float  occlusion; // hardcoded to 1.0 until the occlusion texture lands (the loader job after this one)

    float3 subsurface; // tint for the SSS model (P2)
    float  thickness;  // P2

    uint  shading_model; // which brdf_light/brdf_resolve this point runs -- see shading.odin
    float bands;         // toon (brdf/toon.hlsli)
    float rim;           // toon (brdf/toon.hlsli)
};
