/*
    Bloom, pass two -- halve it again
    ---------------------------------
    Reads one level of the bloom chain and writes the next one down, at half
    the width and half the height. Run `levels - 1` times per frame
    (`bloom_run`, bloom.odin), which is what builds the wide skirt: each
    level's own 13 taps cover twice the screen distance the level above it
    did, so five levels reach about as far as a gaussian of some hundreds of
    taps at full resolution would.

    No threshold here -- `bloom_prefilter.frag.hlsl` already decided what
    blooms, once, at the top of the chain. Applying a knee again per level
    would make the answer depend on how many levels a game asked for.

    Must match matchbox.Bloom_Filter_Frag_Data.
*/

#include "bloom.hlsli"

cbuffer FragData : register(b0, space3)
{
    float2 texel; // one texel of the source level, in uv -- not the destination's

    // Rides along unread. bloom_upsample.frag.hlsl is the pass that needs it,
    // and both share matchbox.Bloom_Filter_Frag_Data rather than having a
    // struct apiece for one float -- the same "a field a given consumer does
    // not use rides along" shape Light_Uniform.cone already has for a light
    // that is not a spot.
    float scatter;
    float _pad;
};

Texture2D<float4> tex : register(t0, space2);
SamplerState      smp : register(s0, space2);

float4 main(float4 pos : SV_Position, float2 uv : TEXCOORD0) : SV_Target0
{
    return float4(bloom_downsample_13(tex, smp, uv, texel), 1.0);
}
