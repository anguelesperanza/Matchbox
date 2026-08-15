/*
    Ellipses and triangles, cut out of the same unit quad everything else draws.

    Matchbox had draw_rect, draw_rect_border, draw_text and draw_sprite and
    nothing else, which is why the dropdown drew its open/closed caret as the
    ASCII characters `v` and `^`.

    A triangle is not a quad, so the honest version of this is a second vertex
    format and a second pipeline layout. This does it in the fragment stage
    instead: the quad covers the shape's bounding box and the shape is a signed
    distance field tested per pixel. That keeps the one shared quad, the one
    vertex shader and the one vertex format the rest of the renderer is built
    on, and a triangle ends up costing exactly what a rect costs.

    Every shape is described in the quad's own uv space rather than being
    inscribed in it, so the caller can make the quad larger than the shape. It
    has to: the smoothed edge needs a pixel of room on the outside, and a
    shape drawn flush to the quad's border loses the outer half of it.

    Must match matchbox.Shape_Frag_Data. Each float2 pair fills one 16-byte
    register: (color) (p0,p1) (p2,kind,thickness).
*/
cbuffer FragData : register(b0, space3)
{
    float4 color;
    float2 p0;        // ellipse: centre.     triangle: first corner
    float2 p1;        // ellipse: radii.      triangle: second corner
    float2 p2;        // ellipse: unused.     triangle: third corner
    float  kind;      // 0 = ellipse, 1 = triangle
    float  thickness; // 0 = filled; above that, an outline this many pixels wide
};

/*
    How far outside the shape `uv` is. Negative inside, zero on the edge.

    Not a true distance for an ellipse -- the gradient of that expression varies
    around the perimeter -- and it does not need to be. main divides by the
    measured gradient, which is a first-order distance estimate for any smooth
    function and is exact where it matters, right at the edge.
*/
float shape_distance(float2 uv)
{
    if (kind < 0.5)
    {
        return length((uv - p0) / max(p1, 1e-6)) - 1.0;
    }

    float2 pts[3] = { p0, p1, p2 };

    // Which way the corners wind is the caller's business and not worth making
    // it their problem, so the third point decides which side of the first edge
    // counts as inside, and the other two edges follow it.
    //
    // Negated because the test says where *inside* is: the third corner lying on
    // the negative side of the first edge's perpendicular is what means that
    // perpendicular already points out. Getting this backwards does not draw a
    // mirrored triangle, it draws nothing at all -- three half-planes all facing
    // inwards have no overlap to fill.
    float2 e0   = pts[1] - pts[0];
    float  side = -sign(dot(float2(e0.y, -e0.x), pts[2] - pts[0]));
    if (side == 0.0) return 1.0; // three points on one line: nothing to fill

    // Inside all three half-planes is inside the triangle, so the distance is
    // the largest of the three -- the edge the point is furthest outside of.
    float d = -1e9;

    [unroll]
    for (int i = 0; i < 3; ++i)
    {
        float2 a = pts[i];
        float2 e = pts[(i + 1) % 3] - a;
        float2 n = normalize(float2(e.y, -e.x)) * side;
        d = max(d, dot(n, uv - a));
    }

    return d;
}

float4 main(float4 pos : SV_Position, float2 uv : TEXCOORD0) : SV_Target0
{
    float d = shape_distance(uv);

    // How much d changes from this pixel to the next, which is the only thing
    // here that knows how big a pixel is. It is what makes the edge smooth, and
    // it is also what lets `thickness` be given in pixels: the quad may be
    // stretched, rotated, scaled by the letterbox and zoomed by the camera, and
    // all of that arrives already folded into this one number.
    float g = max(length(float2(ddx(d), ddy(d))), 1e-6);

    float alpha;
    if (thickness > 0.0)
    {
        // Half the thickness each side of the edge, so a line comes out centred
        // on the shape rather than growing inwards from it.
        float half_t = thickness * 0.5 * g;
        alpha = saturate(0.5 - (abs(d) - half_t) / g);
    }
    else
    {
        alpha = saturate(0.5 - d / g);
    }

    return float4(color.rgb, color.a * alpha);
}
