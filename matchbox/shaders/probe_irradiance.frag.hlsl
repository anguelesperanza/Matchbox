/*
    Environment probe -- diffuse irradiance convolution
    -----------------------------------------------------
    One of `create_environment_probe`'s (ambient.odin) two bake passes: for
    every texel of every one of the six faces, cosine-weight-integrate the
    source cube map over the whole hemisphere around that texel's own world
    direction, and store the result divided by pi -- see this file's own
    normalization comment below for why that specific division is what makes
    the result a drop-in replacement for the flat `ambient.rgb` every
    `brdf_resolve_*` used to read directly (`ambient_light`,
    lighting_core.hlsli).

    Reuses `skybox.vert.hlsl` for the per-face camera basis exactly the way
    `draw_skybox` does -- see ambient.odin's own top comment for why a
    fragment shader convolving an environment and one drawing it need the
    same "which direction does this pixel look" input. The `dir` interpolant
    it hands over is this texel's own un-normalized world direction; this
    file normalizes it once and builds a tangent frame around it to walk the
    hemisphere.

    No uniform buffer -- which face this is baking is entirely a function of
    which `dir` the vertex shader computed for this draw, and every face
    shares the identical convolution kernel.
*/

TextureCube<float4> env : register(t0, space2);
SamplerState        smp : register(s0, space2);

static const float PROBE_PI = 3.14159265358979323846;

// 12 x 24 -- see ambient.odin's own top comment for why this can be coarse:
// irradiance is a low-frequency function of direction by construction (a
// cosine-weighted hemisphere integral is a strong low-pass filter on its
// own), and this runs once at load, not per frame.
#define IRRADIANCE_N_THETA 12
#define IRRADIANCE_N_PHI   24

float4 main(float4 pos : SV_Position, float3 dir : TEXCOORD0) : SV_Target
{
    float3 n = normalize(dir);

    // An arbitrary tangent frame around `n` -- irradiance is being averaged
    // over the whole hemisphere, so unlike a normal map's tangent space,
    // nothing downstream cares which way "up" points within it, only that
    // the frame is orthonormal.
    float3 up_hint = (abs(n.y) < 0.999) ? float3(0, 1, 0) : float3(1, 0, 0);
    float3 right   = normalize(cross(up_hint, n));
    float3 up      = cross(n, right);

    float dtheta = (PROBE_PI * 0.5) / float(IRRADIANCE_N_THETA);
    float dphi   = (2.0 * PROBE_PI) / float(IRRADIANCE_N_PHI);

    float3 irradiance = float3(0.0, 0.0, 0.0);

    for (int ti = 0; ti < IRRADIANCE_N_THETA; ti++)
    {
        float theta   = (float(ti) + 0.5) * dtheta;
        float sin_t   = sin(theta);
        float cos_t   = cos(theta);
        float weight  = sin_t * cos_t * dtheta * dphi; // cosine-weighted solid angle

        for (int pi_i = 0; pi_i < IRRADIANCE_N_PHI; pi_i++)
        {
            float  phi         = (float(pi_i) + 0.5) * dphi;
            float3 local_dir   = float3(sin_t * cos(phi), sin_t * sin(phi), cos_t);
            float3 sample_dir  = local_dir.x * right + local_dir.y * up + local_dir.z * n;

            // Same left-handed hardware cube-map convention
            // skybox_cubemap.frag.hlsl's own x-negation exists for -- see
            // that file's own top comment. The source here is the identical
            // kind of TextureCube, sampled the identical way.
            float3 c = env.Sample(smp, float3(-sample_dir.x, sample_dir.y, sample_dir.z)).rgb;

            irradiance += c * weight;
        }
    }

    /*
        Dividing by pi turns this from the raw irradiance integral
        (integral of L(w) * cos(theta) dw, which is L * pi for a uniform
        environment of radiance L) into the same quantity `ambient.rgb`
        already meant: a colour that stands in for the incoming light
        itself, not scaled by pi, so `ambient_light`'s callers can add this
        exactly where they used to add a flat `ambient.rgb` with no further
        conversion. `ibl_test.odin`'s own uniform-environment check is what
        confirms this lands back on the input radiance rather than on pi
        times it.
    */
    return float4(irradiance / PROBE_PI, 1.0);
}
