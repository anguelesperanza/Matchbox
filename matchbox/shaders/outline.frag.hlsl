/*
    A hollow rectangle: keep the frame, punch out the middle.

    `border` is a half-extent in UV, given per axis. The old version took one
    float and compared it against uv on both axes, so what came out was
    border * size per axis -- a single thickness on a square and two on
    anything else, with the long side getting the heavy one. A 460x52 text box
    with 0.04 drew eighteen pixels down the sides against two along the top.

    Splitting it per axis moves the decision to the caller, which is the only
    place that knows whether an even frame or a proportional one is wanted.
    draw_outline divides a pixel thickness by size to get an even frame;
    draw_outline_proportional passes the same fraction on both axes to keep the
    old behaviour where an outline should scale with its shape.

    Must match matchbox.Outline_Frag_Data.
*/
cbuffer FragData : register(b0, space3)
{
    float4 color;
    float2 border;
    float2 _pad;
};

float4 main(float4 pos : SV_Position, float2 uv : TEXCOORD0) : SV_Target0
{
    if (uv.x > border.x && uv.x < 1.0 - border.x &&
        uv.y > border.y && uv.y < 1.0 - border.y)
    {
        // Transparent rather than discard, matching what the original returned:
        // the interior is blended away by the alpha blend every draw sets up.
        return float4(0.0, 0.0, 0.0, 0.0);
    }

    return color;
}
