/*
    The PlayStation's two rasterizer quirks, for the 3D vertex shaders and the
    fragment shaders they feed. See `matchbox.Psx_Geometry` for what a game
    turns on, and psx_geometry.odin for the CPU mirrors of both procedures
    here, which are what is actually tested -- there is no GPU capture here to
    test these directly, so they are trusted to match their mirrors.

    Both are runtime switches rather than shader variants. A variant per
    combination would be four copies of every mesh pipeline (forward, skinned,
    lines, G-buffer, both on the HDR format), for two effects most games never
    turn on.
*/

/*
    Rounds a clip-space position so that it lands on a corner of a coarse
    `grid` of cells across the destination -- the PlayStation had no subpixel
    precision, so every vertex sat on a whole pixel of its 320x240 screen, and
    a model moving slowly jittered from one to the next. That jitter is the
    wobble.

    The cells are the same ones `draw_post`'s `.PSX` and `.PIXELATE` sample
    on for the same `grid`, so a triangle's edges fall on the edges of the
    coarse pixels rather than across them.

    Only x and y move. z is left alone so the depth test sees what it always
    did, and w is left alone because the divide is undone with it -- snapping
    in NDC and multiplying back by the same w is what keeps this a change of
    where the vertex lands on screen and nothing else.

    A vertex with w <= 0 is behind the eye and is about to be clipped; dividing
    by it would be dividing by zero or flipping the sign, so it is passed
    through as it came.
*/
float4 psx_snap(float4 clip, float2 grid)
{
    if (grid.x <= 0.0 || grid.y <= 0.0 || clip.w <= 0.0) return clip;

    // NDC -1..1 to 0..grid, round to a whole cell corner, and back. Going
    // through 0..grid rather than rounding `ndc * grid / 2` directly keeps
    // an odd grid right: the corners are at whole numbers of cells from the
    // edge, which is not the same set of points as whole numbers of half-grids
    // from the middle when the grid is odd.
    float2 ndc   = clip.xy / clip.w;
    float2 cells = floor((ndc * 0.5 + 0.5) * grid + 0.5);
    clip.xy      = (cells / grid * 2.0 - 1.0) * clip.w;

    return clip;
}

/*
    What the vertex shader writes for its texture coordinate: (uv, 1) for the
    ordinary perspective-correct mapping, (uv * w, w) for the PlayStation's
    affine one. The fragment shader always divides xy by z (`psx_uv_resolve`)
    and does not know which it got.

    **Why the pair works.** The rasterizer interpolates every varying
    perspective-correctly: a value `a` at the three corners arrives as
    `sum(b_i * a_i / w_i) / sum(b_i / w_i)`, with `b_i` the screen-space
    barycentrics. Hand it `uv * w` and the `w_i` cancel on top, leaving
    `sum(b_i * uv_i) / sum(b_i / w_i)`; hand it `w` and the top is `sum(b_i)`,
    which is 1. The ratio is `sum(b_i * uv_i)` -- the texture coordinate
    interpolated linearly across the screen, which is exactly what affine
    mapping is. With (uv, 1) the same ratio is the ordinary perspective-correct
    answer divided by 1.

    **Why not `noperspective`.** HLSL's interpolation modifier says the same
    thing in one word, and was the first thing to reach for. But it is fixed
    when the shader is compiled, so a game switching affine mapping on at
    runtime would need a second copy of every mesh pipeline; this is one
    multiply here and one divide in the fragment shader instead.

    **No guard for w <= 0**, unlike psx_snap. A triangle crossing the near
    plane is clipped before it is rasterized, and the clipper makes its new
    corner by interpolating every varying linearly in clip space -- `uv * w`
    and `w` both, and w is interpolated the same way for its position, so the
    new corner's q is its own w like every other corner's. Falling back to
    (uv, 1) for the corner behind the eye would give the new corner a q that
    is neither, and bend the texture along the clipped edge.
*/
float3 psx_uv(float2 uv, float4 clip, float affine)
{
    float q = affine > 0.5 ? clip.w : 1.0;
    return float3(uv * q, q);
}

// The other half of psx_uv, in the fragment shader. z is never zero on a
// fragment that is drawn: it is 1, or the w of a point in front of the near
// plane, which is positive.
float2 psx_uv_resolve(float3 uvq)
{
    return uvq.xy / uvq.z;
}
