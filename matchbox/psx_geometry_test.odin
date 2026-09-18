package matchbox

/*
	PSX geometry -- the vertex snap and the affine uv pair, on the CPU
	------------------------------------------------------------------
	The mirrors in psx_geometry.odin, checked against what the rasterizer will
	do with their output. The rasterizer's perspective-correct interpolation is
	written out here as the formula every GPU implements -- a value `a` at three
	corners arrives as `sum(b_i * a_i / w_i) / sum(b_i / w_i)`, with `b_i` the
	screen-space barycentrics -- so the affine claim is tested against the
	hardware's arithmetic rather than against itself.

	**Not tested here:** that the HLSL matches these mirrors, or that the result
	looks like a PlayStation. There is no GPU capture here; the shader was
	compiled, and `examples/post` is where it is seen.
*/

import "core:math"
import "core:testing"

@(private = "file")
EPSILON :: 1e-4

@(private = "file")
near :: proc(a, b: f32, epsilon: f32 = EPSILON) -> bool {
	return abs(a - b) <= epsilon * max(1, abs(a), abs(b))
}

@(private = "file")
is_whole :: proc(x: f32) -> bool {
	return near(x, math.round(x))
}

// The rasterizer's perspective-correct interpolation of one value across a
// triangle, at screen-space barycentrics `b`.
@(private = "file")
rasterize :: proc(values: [3]f32, w: [3]f32, b: [3]f32) -> f32 {
	top, bottom: f32
	for i in 0 ..< 3 {
		top    += b[i] * values[i] / w[i]
		bottom += b[i] / w[i]
	}
	return top / bottom
}

@(test)
test_psx_snap_lands_every_vertex_on_a_cell_corner :: proc(t: ^testing.T) {
	// An odd grid as well as the PlayStation's: the corners of an odd grid are
	// not whole numbers of half-grids from the middle, which is the mistake
	// the 0..grid round trip in psx_snap exists to avoid.
	grids := [][2]f32{{320, 240}, {5, 3}}

	// Points all over the screen, near and far -- w is what the divide undoes,
	// so a snap that only worked at w = 1 would pass a test that only used 1.
	clips := [][4]f32{
		{ 0.123,  0.456, 0.3,  1},
		{-1.7,    2.9,   0.5,  3.7},
		{ 13.2,  -8.05,  0.9, 40},
		{ 0.49,  -0.49,  0.1,  0.5},
		{ 0,      0,     0.2,  2},
	}

	for grid in grids {
		for clip in clips {
			snapped := psx_snap(clip, grid)

			testing.expectf(t, snapped.z == clip.z && snapped.w == clip.w,
				"z and w must come through untouched, got %v from %v", snapped, clip)

			before := (clip.xy / clip.w * 0.5 + 0.5) * grid
			after  := (snapped.xy / snapped.w * 0.5 + 0.5) * grid

			// On a corner, counted from the bottom-left the way NDC is...
			testing.expectf(t, is_whole(after.x) && is_whole(after.y),
				"%v on grid %v snapped to %v cells, not a corner", clip, grid, after)

			// ...and from the top-left the way draw_post's cells are, which is
			// what makes an edge fall on a coarse pixel's edge.
			from_top := grid.y - after.y
			testing.expectf(t, is_whole(from_top),
				"%v on grid %v is %v cells from the top, not a corner", clip, grid, from_top)

			// And the nearest one: never more than half a cell away.
			testing.expectf(t, abs(after.x - before.x) <= 0.5 + EPSILON && abs(after.y - before.y) <= 0.5 + EPSILON,
				"%v moved from %v to %v cells, more than half a cell", clip, before, after)
		}
	}
}

@(test)
test_psx_snap_leaves_a_vertex_alone_when_off_or_behind_the_eye :: proc(t: ^testing.T) {
	clip := [4]f32{0.123, 0.456, 0.3, 1}

	testing.expect_value(t, psx_snap(clip, {0, 0}), clip)
	testing.expect_value(t, psx_snap(clip, {320, 0}), clip)
	testing.expect_value(t, psx_snap(clip, {-320, 240}), clip)

	behind := [4]f32{0.123, 0.456, 0.3, -2}
	testing.expect_value(t, psx_snap(behind, {320, 240}), behind)

	at_the_eye := [4]f32{0.123, 0.456, 0.3, 0}
	testing.expect_value(t, psx_snap(at_the_eye, {320, 240}), at_the_eye)
}

@(test)
test_the_uv_pair_gives_perspective_correct_or_affine_mapping :: proc(t: ^testing.T) {
	// A triangle leaning away from the camera: one corner near, one far. The
	// further apart the three w's, the further apart the two mappings -- equal
	// w's would make them agree and prove nothing.
	w  := [3]f32{1, 4, 10}
	uv := [3][2]f32{{0, 0}, {1, 0}, {0, 1}}

	samples := [][3]f32{
		{1.0 / 3, 1.0 / 3, 1.0 / 3},
		{0.5, 0.25, 0.25},
		{0.1, 0.7, 0.2},
		{0.2, 0.2, 0.6},
	}

	differed := false

	for b in samples {
		for affine in ([]f32{0, 1}) {
			// What the vertex shader writes at each corner, and what the
			// rasterizer hands the fragment shader from it.
			uvq: [3][3]f32
			for i in 0 ..< 3 do uvq[i] = psx_uv(uv[i], {0, 0, 0, w[i]}, affine)

			arrived: [3]f32
			for c in 0 ..< 3 do arrived[c] = rasterize({uvq[0][c], uvq[1][c], uvq[2][c]}, w, b)

			got := psx_uv_resolve(arrived)

			want: [2]f32
			if affine > 0.5 {
				// Linear across the screen: the barycentrics alone.
				want = b[0] * uv[0] + b[1] * uv[1] + b[2] * uv[2]
			} else {
				// The ordinary perspective-correct answer.
				want = {
					rasterize({uv[0].x, uv[1].x, uv[2].x}, w, b),
					rasterize({uv[0].y, uv[1].y, uv[2].y}, w, b),
				}
			}

			testing.expectf(t, near(got.x, want.x) && near(got.y, want.y),
				"affine = %v at %v: resolved %v, wanted %v", affine, b, got, want)
		}

		affine_uv      := b[0] * uv[0] + b[1] * uv[1] + b[2] * uv[2]
		perspective_uv := [2]f32{
			rasterize({uv[0].x, uv[1].x, uv[2].x}, w, b),
			rasterize({uv[0].y, uv[1].y, uv[2].y}, w, b),
		}
		if !near(affine_uv.x, perspective_uv.x, 1e-2) do differed = true
	}

	testing.expect(t, differed, "the two mappings agreed everywhere, so this test showed nothing")
}

// A triangle crossing the near plane is clipped before it is rasterized, and
// the clipper interpolates position and varyings linearly in clip space. The
// new corner has to come out with q equal to its own w, or the texture bends
// along the clipped edge -- the reason psx_uv has no w <= 0 guard.
@(test)
test_a_clipped_corner_keeps_the_affine_pair_consistent :: proc(t: ^testing.T) {
	behind := [4]f32{0.3, -0.2, -0.5, -1}
	ahead  := [4]f32{-0.4, 0.6, 2.5, 3}
	uv_behind := [2]f32{0.2, 0.9}
	uv_ahead  := [2]f32{0.7, 0.1}

	a := psx_uv(uv_behind, behind, 1)
	b := psx_uv(uv_ahead,  ahead,  1)

	for s in ([]f32{0.3, 0.5, 0.8}) {
		corner := behind + (ahead - behind) * s
		pair   := a + (b - a) * s

		testing.expectf(t, near(pair.z, corner.w),
			"at %v along the edge the new corner has q %v and w %v", s, pair.z, corner.w)
	}
}

@(test)
test_psx_geometry_is_off_by_default_and_never_reaches_the_shadow_pass :: proc(t: ^testing.T) {
	grid, affine := psx_geometry_switches({}, false)
	testing.expect_value(t, grid, [2]f32{0, 0})
	testing.expect_value(t, affine, 0)

	on := psx_geometry_normalized({snap_vertices = true, affine_textures = true})

	grid, affine = psx_geometry_switches(on, false)
	testing.expect_value(t, grid, [2]f32{320, 240})
	testing.expect_value(t, affine, 1)

	grid, affine = psx_geometry_switches(on, true)
	testing.expect_value(t, grid, [2]f32{0, 0})
	testing.expect_value(t, affine, 0)

	// Through set_lighting's own normalization, from the partial literal a game
	// writes: a grid nobody filled in is the PlayStation's, one somebody did is
	// kept.
	settings := lighting_settings_normalized({enabled = true, psx = {snap_vertices = true}})
	testing.expect_value(t, settings.psx.grid, [2]f32{320, 240})

	settings = lighting_settings_normalized({enabled = true, psx = {snap_vertices = true, grid = {640, 480}}})
	testing.expect_value(t, settings.psx.grid, [2]f32{640, 480})
}

// Where the HLSL cbuffer puts the two fields: a float2 straight after three
// float4x4s, then a float in the same 16-byte row. The size #assert in init
// catches a struct that grew; this catches one that was reordered.
@(test)
test_mesh_vert_data_lays_out_the_psx_switches_where_the_shader_reads_them :: proc(t: ^testing.T) {
	testing.expect_value(t, offset_of(Mesh_Vert_Data, snap_grid), 192)
	testing.expect_value(t, offset_of(Mesh_Vert_Data, affine), 200)
	testing.expect_value(t, size_of(Mesh_Vert_Data), 208)
}
