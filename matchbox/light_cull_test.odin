package matchbox

/*
	Clustered forward -- CPU-side assignment
	-------------------------------------------
	`lighting_rework.md` section 5's own P5 gate, and the honest half of it:
	there is no GPU or capture tooling in this environment, so "identical
	picture to plain forward" and a measured scaling curve are both out of
	reach here (see this file's own report for what that leaves unmeasured).
	What *is* checked, per CLAUDE.md's "verify by measuring":

	- **Cluster assignment correctness, swept**, including the four cases
	  named as breaking naive implementations: a light entirely outside the
	  frustum, one straddling the near plane, one larger than the whole
	  frustum, and one exactly on a cluster boundary.
	- **A generative sweep across the whole grid**: for every cluster in a
	  128-cluster grid, a point constructed by direct unprojection (not by
	  calling any function under test) is confirmed to land inside its own
	  cluster and outside its immediate neighbour -- the "no fewer, no more"
	  property stated at the top of this rework's own P5 brief, checked by
	  construction rather than by spot-checking a handful of hand-picked
	  cases.
	- **`light_cull_radius` against an independent quadratic solve**
	  (`cluster_check.py`, run once, printed to full precision, copied in
	  below rather than recomputed here).
	- **A directional light in every cluster**, and never culled by the
	  radius test meant for point lights -- the specific bug this file's own
	  top comment (light_cull.odin) warns is "the classic clustered-renderer
	  bug".
	- **`cluster_build`'s own bookkeeping** (offsets contiguous, counts sum
	  to the flattened list's own length, and a specific cluster's assigned
	  lights matching what a direct per-light `cluster_light_sphere`/
	  `cluster_test` call says it should hold) -- this is where a counting or
	  flattening mistake would show up, as distinct from the geometry itself.

	All of it runs with `mbi.window_width`/`window_height` set directly
	(`800x800`, matching `cluster_check.py`'s own `aspect = 1`) rather than
	through a real window -- the same "drive it with synthetic input" shape
	`mbi.input.keys[.W].pressing = true` already has elsewhere in this
	package's tests.
*/

import "core:math"
import "core:testing"

// A camera at the world origin looking down -Z with +Y up -- look_at_matrix
// (math3d.odin) then produces the identity view matrix for this exact case
// (f = (0,0,-1), s = (1,0,0), u = (0,1,0), eye at the origin), so a world
// position and its own view-space position are numerically identical here.
// Every test below leans on that to use `cluster_check.py`'s own printed
// numbers as world-space coordinates directly, with nothing lost in
// translation between "what Python computed" and "what Odin receives".
@(private = "file")
cluster_test_camera :: proc() -> Camera3D {
	return Camera3D{
		position = {0, 0, 0}, target = {0, 0, -1}, up = {0, 1, 0},
		fov = 90, projection = .PERSPECTIVE, near = 1, far = 100,
	}
}

@(private = "file")
cluster_test_set_window :: proc() {
	mbi.window_width  = 800
	mbi.window_height = 800
}

// -----------------------------------------------------------------------
// light_cull_radius -- against cluster_check.py's own independent solve
// -----------------------------------------------------------------------

@(test)
test_light_cull_radius_matches_independent_solve :: proc(t: ^testing.T) {
	// python3 cluster_check.py, printed to full precision -- see this file's
	// own top comment. light_cull_radius does not depend on the window or
	// the camera at all, so no synthetic state is needed for this one.
	cases := [3]struct{ cutoff, expected: f32 }{
		{1.0 / 256.0, 87.87268110394243},
		{1.0 / 64.0,  42.98662712080059},
		{0.5,         4.358083358030224},
	}

	for c in cases {
		got := light_cull_radius(c.cutoff)
		testing.expect(t, math.abs(got - c.expected) < 0.0001,
			"light_cull_radius did not match the independent quadratic solve")
	}
}

// -----------------------------------------------------------------------
// The four named sweep cases
// -----------------------------------------------------------------------

// A 4x4x8 grid, fov 90, aspect 1, near 1, far 100 -- the exact configuration
// cluster_check.py used to produce every expected value below.
@(private = "file")
cluster_test_frustum :: proc() -> Cluster_Frustum {
	tan := f32(math.tan(math.to_radians(f32(45)))) // half of fov 90
	return Cluster_Frustum{
		projection = .PERSPECTIVE,
		tan_x = tan, tan_y = tan,
		near = 1, far = 100,
		nx = 4, ny = 4, nz = 8,
	}
}

@(test)
test_cluster_light_entirely_outside_frustum_reaches_no_cluster :: proc(t: ^testing.T) {
	f := cluster_test_frustum()

	// Far off to the side at mid-depth, radius 1 -- cluster_check.py:
	// "outside-far-side" -> False for both the near-axis tile and the tile
	// at the far edge of X, and by the same argument every tile between
	// them.
	center := [3]f32{1000, 0, -10}
	for tx in 0 ..< f.nx {
		for ty in 0 ..< f.ny {
			for tz in 0 ..< f.nz {
				testing.expect(t, !cluster_test(f, center, 1, tx, ty, tz),
					"a light 1000 units off-axis with radius 1 must reach no cluster at all")
			}
		}
	}
}

@(test)
test_cluster_light_straddling_near_plane :: proc(t: ^testing.T) {
	f := cluster_test_frustum()

	// Centered exactly at the near plane, radius 5 -- part of the sphere is
	// behind the camera entirely. cluster_check.py: reaches slice 0 (True)
	// but not the far slice, whose own near edge (56.23) is well past where
	// this light's radius (5) still reaches from depth 1.
	center := [3]f32{0, 0, -1}
	testing.expect(t, cluster_test(f, center, 5, 0, 0, 0),
		"a light straddling the near plane must still reach the slice it is sitting in")
	testing.expect(t, !cluster_test(f, center, 5, 0, 0, f.nz - 1),
		"a light straddling the near plane must not reach a slice 50+ units away")
}

@(test)
test_cluster_light_larger_than_frustum_reaches_every_cluster :: proc(t: ^testing.T) {
	f := cluster_test_frustum()

	// Radius 500 against a far plane of 100 -- this sphere contains the
	// entire frustum regardless of which cluster is asked about.
	center := [3]f32{0, 0, -10}
	for tx in 0 ..< f.nx {
		for ty in 0 ..< f.ny {
			for tz in 0 ..< f.nz {
				testing.expect(t, cluster_test(f, center, 500, tx, ty, tz),
					"a light bigger than the whole frustum must reach every cluster")
			}
		}
	}
}

@(test)
test_cluster_light_exactly_on_boundary_reaches_both_neighbors :: proc(t: ^testing.T) {
	f := cluster_test_frustum()

	// Tile 2's own left edge (x0) lands at NDC 0 for a 4-wide grid, which
	// puts view-space x at exactly 0 for any depth -- cluster_check.py's own
	// "boundary_x" came out 0 for exactly this reason. A radius-0 light
	// sitting precisely on that shared plane must count as reaching *both*
	// tile 1 and tile 2 -- the conservative, safe-by-construction answer
	// cluster_plane_overlap's own `>= -r` gives, not an arbitrary tie-break
	// that could drop it from both.
	center := [3]f32{0, 0, -10}
	testing.expect(t, cluster_test(f, center, 0, 1, 1, 3), "on-boundary light must reach the lower-indexed neighbour")
	testing.expect(t, cluster_test(f, center, 0, 2, 1, 3), "on-boundary light must reach the higher-indexed neighbour")
	testing.expect(t, !cluster_test(f, center, 0, 0, 1, 3), "on-boundary light must not reach a tile two columns away")
}

// -----------------------------------------------------------------------
// Generative sweep -- every cluster in the grid, "no fewer, no more"
// -----------------------------------------------------------------------

/*
	For every one of the 128 clusters in `cluster_test_frustum`'s own grid, a
	point built by direct unprojection (not by calling anything this file is
	testing) must land inside its own cluster and outside a same-axis
	neighbour -- checked with radius 0, the tightest case cluster_plane_overlap
	ever has to get right.

	This is the sweep `lighting_rework.md`'s own gate asks for -- "do not
	spot-check where a sweep is possible" -- run across the entire grid
	rather than a handful of hand-picked tiles, and it is a fresh
	construction (the unprojection formula is the geometric *definition* of
	where a cluster is, independent of cluster_test's own plane arithmetic)
	rather than a restatement of the code under test.
*/
@(test)
test_cluster_grid_sweep_every_cluster_contains_its_own_center :: proc(t: ^testing.T) {
	f := cluster_test_frustum()
	tested := 0

	for tz in 0 ..< f.nz {
		z_near, z_far := cluster_z_bounds(tz, f.nz, f.near, f.far)
		d := (z_near + z_far) * 0.5 // mid-depth of the slice

		for ty in 0 ..< f.ny {
			y0, y1 := cluster_ndc_range_y_for_test(ty, f.ny)
			ndc_y := (y0 + y1) * 0.5

			for tx in 0 ..< f.nx {
				x0, x1 := cluster_ndc_range(tx, f.nx)
				ndc_x := (x0 + x1) * 0.5

				// Direct unprojection: at view-space depth d, the frustum's
				// own half-width/half-height is d*tan_x/d*tan_y, so a point
				// at NDC fraction ndc_x/ndc_y is exactly (ndc_x*d*tan_x,
				// ndc_y*d*tan_y, -d) -- the textbook inverse of the
				// perspective projection this whole grid is built from.
				center := [3]f32{ndc_x * d * f.tan_x, ndc_y * d * f.tan_y, -d}

				testing.expectf(t, cluster_test(f, center, 0, tx, ty, tz),
					"cluster (%d,%d,%d)'s own centre must be found inside it", tx, ty, tz)

				// One column to the right (if one exists) must not contain
				// this same point -- the tightness half of the same sweep.
				if tx + 1 < f.nx {
					testing.expectf(t, !cluster_test(f, center, 0, tx + 1, ty, tz),
						"cluster (%d,%d,%d)'s own centre must not also be inside the next column over", tx, ty, tz)
				}

				tested += 1
			}
		}
	}

	testing.expect_value(t, tested, f.nx * f.ny * f.nz)
}

// cluster_test's own Y convention is private to light_cull.odin's file scope
// only insofar as it is inlined there -- this mirrors the same top-down
// mapping (tile 0 is the top row) so the sweep above builds NDC ranges the
// same way cluster_test itself interprets tx/ty/tz.
@(private = "file")
cluster_ndc_range_y_for_test :: proc(ty, ny: int) -> (lo, hi: f32) {
	hi = 1 - 2 * f32(ty) / f32(ny)
	lo = 1 - 2 * f32(ty + 1) / f32(ny)
	return
}

// -----------------------------------------------------------------------
// Directional lights, and area-light padding
// -----------------------------------------------------------------------

// The classic clustered-renderer bug this file's own top comment (light_cull.odin)
// names: a directional light culled by the punctual-light radius test. Every
// cluster in a real grid, not a sample of them.
@(test)
test_cluster_directional_light_is_never_culled :: proc(t: ^testing.T) {
	cluster_test_set_window()

	sun := create_directional_light({0, -1, 0})
	u   := light_uniform(sun, Shadow_Bias{})

	center, radius, always := cluster_light_sphere(u, CLUSTER_DEFAULTS.cutoff)
	testing.expect(t, always, "a directional light must be marked 'always', not tested against a radius")
	testing.expect_value(t, center, [3]f32{0, 0, 0})
	testing.expect_value(t, radius, f32(0))

	ranges: [dynamic]Cluster_Range
	indices: [dynamic]u32
	defer delete(ranges)
	defer delete(indices)

	settings := Cluster_Settings{grid = {4, 4, 8}, cutoff = CLUSTER_DEFAULTS.cutoff}
	cluster_build(cluster_test_camera(), []Light_Uniform{u}, settings, &ranges, &indices)

	for r, i in ranges {
		testing.expectf(t, r.count == 1, "cluster %d must hold the directional light exactly once, got count %d", i, r.count)
	}
	testing.expect_value(t, len(indices), 4 * 4 * 8)
}

// linalg.length(area_size) -- the rectangle's own diagonal / the disk's own
// radius -- must strictly grow a rect/disk light's culling radius past a
// same-position, same-colour point light's, matching cluster_light_sphere's
// own doc comment on why area lights are padded rather than measured
// exactly.
@(test)
test_cluster_area_light_radius_is_padded_by_its_own_extent :: proc(t: ^testing.T) {
	cutoff := f32(1.0 / 256.0)

	point := create_point_light({0, 0, -5})
	point_u := light_uniform(point, Shadow_Bias{})
	_, point_radius, _ := cluster_light_sphere(point_u, cutoff)

	rect := create_area_rect_light({0, 0, -5}, normal = {0, 0, 1}, right = {1, 0, 0}, width = 4, height = 2)
	rect_u := light_uniform(rect, Shadow_Bias{})
	_, rect_radius, always_rect := cluster_light_sphere(rect_u, cutoff)

	disk := create_area_disk_light({0, 0, -5}, normal = {0, 0, 1}, radius = 3)
	disk_u := light_uniform(disk, Shadow_Bias{})
	_, disk_radius, always_disk := cluster_light_sphere(disk_u, cutoff)

	testing.expect(t, !always_rect && !always_disk, "area lights are not 'always', they still have a finite reach")

	// half-width 2, half-height 1 -> diagonal sqrt(5) ~= 2.2360679...
	expected_rect_padding := f32(math.sqrt(f32(5)))
	testing.expect(t, math.abs((rect_radius - point_radius) - expected_rect_padding) < 0.0001,
		"a rect light's own padding must be its diagonal, not its half-width or half-height alone")

	// disk radius 3, area_size.y is 0 for a disk -- padding is exactly 3.
	testing.expect(t, math.abs((disk_radius - point_radius) - 3) < 0.0001,
		"a disk light's own padding must be exactly its radius")
}

// -----------------------------------------------------------------------
// cluster_build's own bookkeeping
// -----------------------------------------------------------------------

/*
	Builds a mixed scene (directional, two points -- one that reaches a
	chosen cluster and one that clearly does not, a spot, and an area light)
	and checks `cluster_build`'s own flattened output two ways: the
	structural invariant every cluster's range has to satisfy regardless of
	what is in the scene, and, for one specific cluster, that its assigned
	light set matches exactly what calling `cluster_light_sphere`/
	`cluster_test` directly for each light says it should hold. The second
	check is this file's own version of "equivalence with FORWARD as a set"
	(`lighting_rework.md`'s own P5 gate): FORWARD would shade every one of
	these lights at any point in the scene, so the set CLUSTERED assigns to a
	fragment's own cluster must be exactly the subset whose own
	`cluster_light_sphere` reach genuinely includes it -- not a sample of
	that set, the actual one, recomputed independently of `cluster_build`'s
	own loop.
*/
@(test)
test_cluster_build_matches_direct_per_light_membership :: proc(t: ^testing.T) {
	cluster_test_set_window()

	sun          := light_uniform(create_directional_light({0, -1, 0}), Shadow_Bias{})
	near_point   := light_uniform(create_point_light({0, 0, -10}), Shadow_Bias{})   // reaches the chosen cluster

	/*
		Far enough that even light_cull_radius's own generous reach (~87.87
		units at the default 1/256 cutoff -- the curve decays slowly, so a
		"culled" light still reaches a long way) cannot bridge the gap: at
		distance 500 the light's own influence starts at 500-87.87 = 412.13,
		past every cluster's own z_far (capped at the camera's own far
		plane, 100). Placing this only just past the target cluster's own
		z_far (17.78, see below) would not test "genuinely does not reach"
		at all -- it would test whether this file's author can subtract, the
		exact anti-pattern lighting_rework.md warns against copying an
		implementation's own output into an expected value. 500 leaves no
		such ambiguity either way.
	*/
	far_point := light_uniform(create_point_light({0, 0, -500}), Shadow_Bias{})
	spot         := light_uniform(create_spot_light({0, 0, -10}, {0, 0, -1}), Shadow_Bias{})
	area         := light_uniform(create_area_rect_light({0, 0, -10}, normal = {0, 0, 1}, right = {1, 0, 0}, width = 2, height = 2), Shadow_Bias{})

	light_data := []Light_Uniform{sun, near_point, far_point, spot, area}

	settings := Cluster_Settings{grid = {4, 4, 8}, cutoff = CLUSTER_DEFAULTS.cutoff}

	ranges: [dynamic]Cluster_Range
	indices: [dynamic]u32
	defer delete(ranges)
	defer delete(indices)
	cluster_build(cluster_test_camera(), light_data, settings, &ranges, &indices)

	nx, ny, nz := settings.grid.x, settings.grid.y, settings.grid.z
	total := nx * ny * nz
	testing.expect_value(t, len(ranges), total)

	// Bookkeeping: offsets contiguous and increasing by exactly the
	// previous range's own count, and the last range's own end matches the
	// flattened list's own length.
	expected_offset: u32 = 0
	for r, i in ranges {
		testing.expectf(t, r.offset == expected_offset,
			"cluster %d's own offset (%d) must continue where the previous cluster's own range ended (%d)",
			i, r.offset, expected_offset)
		expected_offset += r.count
	}
	testing.expect_value(t, expected_offset, u32(len(indices)))

	// The specific cluster the camera's own forward axis passes through at
	// depth 10 -- tile (2,2) is the grid's own centre column/row for a 4x4
	// split, and cluster_z_bounds(3, 8, 1, 100) brackets depth 10.
	target_tz := -1
	for tz in 0 ..< nz {
		zn, zf := cluster_z_bounds(tz, nz, 1, 100)
		if 10 >= zn && 10 < zf {
			target_tz = tz
			break
		}
	}
	testing.expect(t, target_tz >= 0, "depth 10 must fall inside one of the grid's own slices")

	f := cluster_test_frustum()
	tx, ty := 2, 2

	expected: map[u32]bool
	defer delete(expected)
	for u, i in light_data {
		center, radius, always := cluster_light_sphere(u, settings.cutoff)
		if always || cluster_test(f, view_point_for_test(cluster_test_camera(), center), radius, tx, ty, target_tz) {
			expected[u32(i)] = true
		}
	}

	index := tx + ty * nx + target_tz * nx * ny
	got: map[u32]bool
	defer delete(got)
	r := ranges[index]
	for j in r.offset ..< r.offset + r.count {
		got[indices[j]] = true
	}

	testing.expect_value(t, len(got), len(expected))
	for i in expected {
		testing.expectf(t, i in got, "light %d should reach cluster (%d,%d,%d) but cluster_build did not assign it", i, tx, ty, target_tz)
	}
	for i in got {
		testing.expectf(t, i in expected, "light %d was assigned to cluster (%d,%d,%d) but its own sphere test says it should not reach it", i, tx, ty, target_tz)
	}

	// The far point light must specifically be absent -- the concrete case
	// this test exists to pin down, not just a side effect of the set
	// comparison above.
	far_index := u32(2)
	testing.expect(t, !(far_index in got), "a point light 99 units past the camera must not reach a cluster at depth 10")
}

// cluster_test_camera's own view matrix is the identity (this file's own top
// comment), so this only exists to make that assumption explicit at the one
// call site that would silently give the wrong answer the day the test
// camera stops looking straight down -Z.
@(private = "file")
view_point_for_test :: proc(camera: Camera3D, world: [3]f32) -> [3]f32 {
	view := camera3d_view(camera)
	p := view * [4]f32{world.x, world.y, world.z, 1}
	return p.xyz
}

// -----------------------------------------------------------------------
// Cluster_Settings normalization
// -----------------------------------------------------------------------

@(test)
test_cluster_settings_normalized_fills_in_zeroes_only :: proc(t: ^testing.T) {
	zero := cluster_settings_normalized(Cluster_Settings{})
	testing.expect_value(t, zero.grid, CLUSTER_GRID_DEFAULTS)
	testing.expect_value(t, zero.cutoff, CLUSTER_DEFAULTS.cutoff)

	// A deliberately chosen, non-default grid and cutoff must survive
	// untouched -- the same "does not collide with a real value" test
	// every other normalized-on-store field in this package already has to
	// pass (Body.tint, Lighting_Settings.exposure).
	chosen := Cluster_Settings{grid = {8, 8, 8}, cutoff = 0.1}
	normalized := cluster_settings_normalized(chosen)
	testing.expect_value(t, normalized, chosen)
}
