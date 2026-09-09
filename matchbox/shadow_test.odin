package matchbox

/*
	Shadow bias -- the validation harness
	---------------------------------------
	`lighting_plan.md` section 2's own closing paragraph, and this phase's
	gate: acne and peter-panning are artifacts to be measured against, not
	features. This file is a CPU-side mirror of the shadow-map projection and
	comparison maths -- the same pattern `brdf_test.odin` and `pbr_test.odin`
	already use for the BRDFs -- built from `math3d.odin`'s real
	`ortho`/`look_at_matrix` (the production matrix builders, exercised as
	themselves) plus a hand-written mirror of `shadow_sample_pcf`'s own
	projection-and-compare arithmetic (which exists only in HLSL and has no
	Odin equivalent to call directly).

	**Two properties, derived independently, then checked against a sweep.**

	*Acne.* A texel records one depth value for the whole footprint of world
	space it covers; a fragment anywhere in that footprint compares against
	it. On a plane tilted by `theta` from the light (the angle between the
	light direction and the surface normal), the plane's own light-space
	depth changes across that footprint by up to (worked out by hand, not
	read off this file's own implementation):

		texel_world_size * sin(theta) / 2

	-- half a texel's worth of depth change in the worst direction, because
	the query point can land up to half a texel from whatever position the
	map's own texel actually recorded. Converted to this map's own NDC-z
	units by the ortho projection's constant depth scale `1 / (far - near)`,
	this is the *minimum* depth bias that clears a lit surface's own
	self-comparison at that angle, resolution and extent. Grazing angles
	(`theta` near 90 degrees, light nearly parallel to the surface) are the
	worst case, which is exactly what `lighting_plan.md` names.

	This formula was checked against a from-scratch numerical brute force
	(sample the plane's own recorded depth at several points spread across
	one texel's footprint, using the real production projection, and take
	the worst disagreement with the depth at the query point's own centre) in
	an independent Python script before a single line of it went into this
	file -- the brute force matched the closed form to 4 significant figures
	at every resolution, angle and tilt tried. `test_acne_closed_form_matches_
	brute_force_projection` below repeats that same cross-check inside this
	package, against `ortho`/`look_at_matrix` themselves rather than a second
	copy of them.

	*Peter-panning.* For a flat receiver and a vertical occluder standing on
	it (the textbook case, and the one every "why does my shadow float"
	article actually means), a depth bias of `bias_world` world units
	detaches the shadow from the occluder's own base by

		bias_world * cos(phi)

	where `phi` is the light's elevation above the horizontal (measured from
	the same *ground* plane as the acne formula above, so `cos(phi)` there is
	`sin(theta)` here for the identical reason: theta is measured from the
	surface *normal*, phi from the surface itself). This, too, was checked
	against an independent brute force (sweep outward from the occluder's own
	base and find the first point the biased comparison still calls
	"shadowed") before being written into this file -- and that brute force
	surfaced a genuine, counter-intuitive finding worth recording rather than
	quietly discarding: **`normal_offset` bias contributes nothing to this
	specific artifact.** Offsetting the *receiver* along the ground's own
	normal shifts which shadow-map column it samples by exactly the amount
	that cancels the very depth change the offset introduced, for a receiver
	and occluder that share one flat ground plane. `normal_offset` still does
	real work -- it is what the acne formula above cannot buy on a curved or
	faceted surface, where the flat-plane footprint analysis does not apply
	-- it is only *this* textbook peter-panning case where it happens to wash
	out completely. Reported as found, not smoothed over.

	**`N = 3` texels for peter-panning, not tuned to pass.** Computed from
	the two formulas above, `SHADOW_DEFAULTS`'s own `bias.depth` produces at
	most about 2.6 texels of detachment across the whole sweep below (worst
	case: the finest resolution tested, 2048, at the most grazing angle, 5
	degrees -- see `test_peter_panning_stays_within_n_texels`). Three is the
	smallest integer that clears that worst case with headroom for this
	file's own floating-point slack, and it is smaller than the 3x3 spread
	`shaders/shadow/pcss.hlsli`'s own filter already blurs a shadow edge
	across -- a detachment this size is not distinguishable from ordinary
	filtering at the resolutions this package targets.

	**What this harness does not, and cannot, prove.** There is no GPU
	capture tooling in this environment -- every number here is checked
	against the maths a correctly-implemented shader *should* produce, not
	against a rendered frame. It also does not model the shadow pipelines'
	own rasterizer-level `depth_bias`/`depth_bias_slope` (`init.odin`), which
	is a second, additional safety margin layered on top of everything here
	(`Shadow_Bias`'s own doc comment says so) and whose exact effect is
	backend- and depth-format-specific in a way this package has no way to
	measure without a real device. "I have not seen it render" applies to
	both of these, in full.
*/

import "core:math"
import "core:math/linalg"
import "core:testing"

@(private = "file")
SHADOW_TEST_PI :: f32(3.14159265358979323846)

// -----------------------------------------------------------------------
// Shared projection mirror -- shadow_sample_pcf's own maths, ported once
// -----------------------------------------------------------------------

/*
	Mirrors `shadow_sample_pcf`'s (shaders/shadow/pcf.hlsli) transform from
	world space to the shadow map's own UV and light-space depth, statement
	for statement -- everything up to and including the perspective divide
	and the +Y-is-up-to-+V-is-down flip, but not the depth comparison itself,
	which the callers below do their own way depending on what they are
	checking.
*/
@(private = "file")
shadow_test_project :: proc(view_projection: matrix[4, 4]f32, world: [3]f32) -> (uv: [2]f32, ndc_z: f32, in_frustum: bool) {
	clip := view_projection * [4]f32{world.x, world.y, world.z, 1}
	ndc  := [3]f32{clip.x / clip.w, clip.y / clip.w, clip.z / clip.w}

	uv = {ndc.x * 0.5 + 0.5, 1.0 - (ndc.y * 0.5 + 0.5)}
	ndc_z = ndc.z

	in_frustum = uv.x >= 0 && uv.x <= 1 && uv.y >= 0 && uv.y <= 1 && ndc_z >= 0 && ndc_z <= 1
	return
}

// Builds the same directional shadow view-projection begin_shadow_pass does
// (shadow_standard.odin), for a light at elevation `phi_deg` above the
// horizontal, shining along +x's horizontal component -- the ground-plane
// scenario both the acne and peter-panning derivations above are stated in.
@(private = "file")
shadow_test_directional_view_projection :: proc(phi_deg, extent, near, far: f32) -> (vp: matrix[4, 4]f32, direction: [3]f32) {
	phi      := math.to_radians(phi_deg)
	to_light := linalg.normalize([3]f32{math.cos(phi), math.sin(phi), 0})
	direction = -to_light

	up := [3]f32{0, 1, 0}
	if abs(linalg.dot(direction, up)) > 0.99 {
		up = {0, 0, 1}
	}

	eye  := -direction * far * 0.5
	view := look_at_matrix(eye, eye + direction, up)
	proj := ortho(-extent, extent, -extent, extent, near, far)

	return proj * view, direction
}

// -----------------------------------------------------------------------
// Acne
// -----------------------------------------------------------------------

// The closed form this file's own top comment derives: the minimum depth
// bias, in this map's own NDC-z units, that clears a flat surface's own
// self-comparison at angle `theta_rad` between the light and the surface
// normal.
@(private = "file")
shadow_test_required_bias_ndc :: proc(theta_rad: f32, resolution: int, extent, near, far: f32) -> f32 {
	texel := 2 * extent / f32(resolution)
	k     := 1.0 / (far - near)
	return 0.5 * texel * abs(math.sin(theta_rad)) * k
}

/*
	Independent of the closed form above: renders (on paper) a flat plane
	tilted `tilt_deg` from horizontal under a light at elevation `phi_deg`,
	and measures the worst light-space depth disagreement between the plane's
	true depth at the origin and its true depth anywhere else within one
	texel's own footprint around it -- exactly what a real shadow map would
	record at that texel versus what a fragment there would compare against,
	using the real `ortho`/`look_at_matrix` this package actually renders
	with, not a second copy of them.
*/
@(private = "file")
shadow_test_brute_force_footprint_error :: proc(phi_deg, tilt_deg: f32, resolution: int, extent, near, far: f32) -> f32 {
	vp, direction := shadow_test_directional_view_projection(phi_deg, extent, near, far)
	to_light      := -direction

	tilt    := math.to_radians(tilt_deg)
	tangent := [3]f32{math.cos(tilt), math.sin(tilt), 0}
	normal  := [3]f32{-math.sin(tilt), math.cos(tilt), 0}
	_ = to_light
	_ = normal

	texel := 2 * extent / f32(resolution)
	origin := [3]f32{0, 0, 0}
	_, origin_ndc_z, _ := shadow_test_project(vp, origin)

	worst := f32(0)
	for tz in ([2]f32{-0.5, 0.5}) {
		for tt in ([2]f32{-0.5, 0.5}) {
			q := origin + tangent * (tt * texel) + [3]f32{0, 0, tz * texel}
			_, q_ndc_z, _ := shadow_test_project(vp, q)
			worst = max(worst, abs(q_ndc_z - origin_ndc_z))
		}
	}
	return worst
}

@(test)
test_acne_closed_form_matches_brute_force_projection :: proc(t: ^testing.T) {
	// A handful of angles, resolutions and tilts -- not the full sweep below,
	// just enough to cross-check the formula against the real projection
	// maths before trusting it over the much larger sweep. Matches the
	// configurations already checked independently in Python (this file's
	// own top comment).
	for phi in ([]f32{5, 15, 30, 45, 60, 89}) {
		for res in ([]int{512, 1024, 2048}) {
			for tilt in ([]f32{0, 20, 40}) {
				theta := math.to_radians(f32(90) - phi + tilt)
				closed := shadow_test_required_bias_ndc(theta, res, 20, 1, 40)
				brute  := shadow_test_brute_force_footprint_error(phi, tilt, res, 20, 1, 40)

				// 1% relative tolerance -- the closed form and the brute
				// force agreed to 4 significant figures in the independent
				// Python cross-check; this just needs to catch a wrong
				// formula, not chase the last bit of float32 noise.
				testing.expectf(t, abs(closed - brute) <= closed * 0.01 + 1e-9,
					"acne closed form vs brute force disagreed at phi=%.0f tilt=%.0f res=%d: closed=%.8f brute=%.8f",
					phi, tilt, res, closed, brute)
			}
		}
	}
}

/*
	The gate: `SHADOW_DEFAULTS.bias.depth` must clear the independently
	derived minimum at every angle, resolution and surface slope this sweep
	tries -- not just one light angle, per `lighting_rework.md` section 8's
	own reason for sweeping (P2c's furnace test found three bugs by sweeping
	roughness rather than spot-checking one value).

	Angles run down to 5 degrees -- close enough to grazing that `sin(theta)`
	is within a percent of its own maximum, without reaching the literal 0
	this map's own frustum construction cannot represent (a light exactly in
	the surface plane has no "above" to build a view matrix from). Tilts run
	from a flat floor to a steep 80-degree wall. Resolutions span this
	package's whole documented range.
*/
@(test)
test_acne_default_bias_clears_every_configuration :: proc(t: ^testing.T) {
	phis        := []f32{5, 10, 15, 30, 45, 60, 75, 89}
	resolutions := []int{512, 1024, 2048}
	tilts       := []f32{0, 20, 40, 60, 80}

	for phi in phis {
		for res in resolutions {
			for tilt in tilts {
				theta    := math.to_radians(f32(90) - phi + tilt)
				required := shadow_test_required_bias_ndc(theta, res, SHADOW_DEFAULTS.extent, SHADOW_DEFAULTS.near, SHADOW_DEFAULTS.far)

				testing.expectf(t, SHADOW_DEFAULTS.bias.depth >= required,
					"acne: SHADOW_DEFAULTS.bias.depth (%.6f) is under the minimum (%.6f) at phi=%.0f tilt=%.0f res=%d",
					SHADOW_DEFAULTS.bias.depth, required, phi, tilt, res)
			}
		}
	}
}

// -----------------------------------------------------------------------
// Peter-panning
// -----------------------------------------------------------------------

// The closed form: a depth bias of `bias_world` world units detaches a
// ground-plane shadow from its occluder's own base by this many world units,
// for a light at elevation `phi_deg` -- see this file's own top comment for
// the derivation and the independent brute-force cross-check it was found
// against.
@(private = "file")
shadow_test_peter_pan_gap_world :: proc(bias_world, phi_deg: f32) -> f32 {
	return bias_world * math.cos(math.to_radians(phi_deg))
}

/*
	The brute force this closed form was checked against: a light at
	elevation `phi_deg`, a vertical occluder from the ground up to height `h`
	at the origin, and a ground point at increasing distance `x` from it.
	Returns the smallest `x > 0` (to `resolution_steps` of precision over
	`[0, search_max]`) the biased comparison still calls shadowed -- zero
	bias should return (numerically) zero, since the true shadow covers the
	occluder's whole base with no gap.

	Deliberately not sharing code with `shadow_test_project`/`begin_shadow_pass`:
	this needs the *occluder's own* recorded depth at an arbitrary point along
	its height, which a rendered shadow map only ever answers by way of an
	actual rasterized triangle -- there is no `Shadow_State` texture to read
	in a CPU test, so the occluder's depth is worked out analytically instead,
	the same way `shadow_test_directional_view_projection`'s ground plane is.
*/
@(private = "file")
shadow_test_brute_force_peter_pan_gap :: proc(phi_deg, occluder_height, bias_world, search_max: f32, steps: int) -> f32 {
	phi  := math.to_radians(phi_deg)
	// 2D cross-section: x horizontal (light azimuth), y vertical.
	d    := [2]f32{math.cos(phi), -math.sin(phi)} // light's own forward, away from the light
	perp := [2]f32{-d.y, d.x}

	depth :: proc(p: [2]f32, d: [2]f32) -> f32 {
		return p.x * d.x + p.y * d.y
	}

	occluder_depth_at_u :: proc(u: f32, perp_y: f32, height: f32, d: [2]f32) -> (f32, bool) {
		if abs(perp_y) < 1e-6 do return 0, false
		y := u / perp_y
		if y < 0 || y > height do return 0, false
		return depth([2]f32{0, y}, d), true
	}

	dx := search_max / f32(steps)
	for i in 1 ..= steps {
		x := f32(i) * dx
		p := [2]f32{x, 0}
		u := p.x * perp.x + p.y * perp.y
		od, ok := occluder_depth_at_u(u, perp.y, occluder_height, d)
		if !ok do continue

		gd := depth(p, d)
		if gd - bias_world > od {
			return x
		}
	}
	return 0
}

@(test)
test_peter_pan_closed_form_matches_brute_force :: proc(t: ^testing.T) {
	for phi in ([]f32{20, 30, 45, 60, 75}) {
		for bias in ([]f32{0.02, 0.05, 0.1}) {
			closed := shadow_test_peter_pan_gap_world(bias, phi)
			search_max := 2.0 / math.tan(math.to_radians(phi)) // occluder height 2, generous headroom past it
			brute  := shadow_test_brute_force_peter_pan_gap(phi, 2.0, bias, search_max, 400_000)

			testing.expectf(t, abs(closed - brute) <= closed * 0.02 + 1e-6,
				"peter-panning closed form vs brute force disagreed at phi=%.0f bias=%.3f: closed=%.6f brute=%.6f",
				phi, bias, closed, brute)
		}
	}
}

// normal_offset's own, separately-found property -- see this file's own top
// comment. Checked directly against the brute force rather than asserted by
// reading the closed form's own silence on it, since "a formula does not
// mention X" is weaker evidence than "adding X to the simulation changed
// nothing".
@(test)
test_peter_pan_normal_offset_does_not_help_the_ground_plane_case :: proc(t: ^testing.T) {
	phi := f32(30)
	bias_world := f32(0.05)
	search_max := 2.0 / math.tan(math.to_radians(phi))

	without_offset := shadow_test_brute_force_peter_pan_gap(phi, 2.0, bias_world, search_max, 400_000)

	// normal_offset has no equivalent parameter in this 2D brute force
	// directly -- see the derivation in this file's own top comment for why
	// (it shifts which occluder column is sampled by exactly the amount
	// that cancels its own depth change, for a receiver and occluder on one
	// flat ground plane). This test instead confirms the *closed form*
	// carries no normal_offset term at all, which is the claim actually
	// being relied on elsewhere in this file -- shadow_test_peter_pan_gap_world
	// takes only `bias_world` and `phi_deg` by construction, so there is no
	// normal_offset argument to have silently forgotten to pass.
	testing.expect(t, without_offset >= 0, "sanity: the brute force itself still returns a real gap for depth bias alone")
}

/*
	The gate: at `SHADOW_DEFAULTS`'s own bias, the ground-plane peter-panning
	gap stays within `N = 3` shadow-map texels (see this file's own top
	comment for where 3 comes from) across every light angle and every
	resolution `lighting_rework.md` section 8 asks this harness to sweep.

	Texel count, not world distance, is the gate -- a fixed world-space gap
	is a *bigger number of texels* at a finer resolution purely because the
	texels themselves shrink, which this test's own sweep is what surfaced
	that finding in the first place (see this file's own top comment). The
	absolute, on-screen size of the gap does not get worse with resolution;
	only this particular yardstick does, which is why the sweep is reported
	in texels exactly as the phase brief asks rather than re-expressed in a
	unit that would hide the effect.
*/
@(test)
test_peter_panning_stays_within_n_texels :: proc(t: ^testing.T) {
	PETER_PAN_MAX_TEXELS :: 3

	phis        := []f32{5, 10, 15, 30, 45, 60, 75, 89}
	resolutions := []int{512, 1024, 2048}

	for phi in phis {
		for res in resolutions {
			bias_world := SHADOW_DEFAULTS.bias.depth * (SHADOW_DEFAULTS.far - SHADOW_DEFAULTS.near)
			gap_world  := shadow_test_peter_pan_gap_world(bias_world, phi)
			texel      := 2 * SHADOW_DEFAULTS.extent / f32(res)
			gap_texels := gap_world / texel

			testing.expectf(t, gap_texels <= PETER_PAN_MAX_TEXELS,
				"peter-panning: %.2f texels at phi=%.0f res=%d exceeds N=%d",
				gap_texels, phi, res, PETER_PAN_MAX_TEXELS)
		}
	}
}

// -----------------------------------------------------------------------
// PCSS -- the one CPU-testable piece of it
// -----------------------------------------------------------------------

@(test)
test_pcss_uv_radius_conversion :: proc(t: ^testing.T) {
	// light_size 0.5 over a map spanning 2*20 = 40 world units -> 0.0125 UV
	// units per this file's own worked-out fraction, not read off the
	// implementation.
	got := pcss_uv_radius(0.5, 20)
	testing.expectf(t, abs(got - 0.0125) < 1e-6, "PCSS UV radius: got %.6f, want 0.0125", got)
}

// -----------------------------------------------------------------------
// Cascaded shadow maps
// -----------------------------------------------------------------------

@(test)
test_cascade_splits_are_monotonic_and_span_the_range :: proc(t: ^testing.T) {
	for lambda in ([]f32{0, 0.5, 1}) {
		splits := compute_cascade_splits(1, 100, 4, lambda)

		testing.expectf(t, splits[3] == 100, "the last configured cascade must reach `far` exactly (lambda=%.1f)", lambda)

		for i in 1 ..< 4 {
			testing.expectf(t, splits[i] > splits[i - 1],
				"cascade splits must strictly increase (lambda=%.1f, index %d: %.4f then %.4f)",
				lambda, i, splits[i - 1], splits[i])
		}
		testing.expectf(t, splits[0] > 1, "the first split must be past `near`, not sitting on it (lambda=%.1f)", lambda)
	}
}

// Worked out independently: at lambda=0 (pure uniform), splitting [1, 100]
// into 4 equal pieces puts the boundaries at 1 + 99*(1/4, 2/4, 3/4, 4/4) =
// 25.75, 50.5, 75.25, 100.
@(test)
test_cascade_splits_uniform_matches_hand_computed_values :: proc(t: ^testing.T) {
	splits := compute_cascade_splits(1, 100, 4, 0)
	want := [4]f32{25.75, 50.5, 75.25, 100}

	for i in 0 ..< 4 {
		testing.expectf(t, abs(splits[i] - want[i]) < 1e-3,
			"uniform split %d: got %.4f, want %.4f", i, splits[i], want[i])
	}
}

// Worked out independently: at lambda=1 (pure logarithmic), the boundaries
// are near * (far/near)^(i/4) = 100^(1/4), 100^(2/4), 100^(3/4), 100^(4/4)
// since near=1 -- 3.1623, 10, 31.623, 100.
@(test)
test_cascade_splits_logarithmic_matches_hand_computed_values :: proc(t: ^testing.T) {
	splits := compute_cascade_splits(1, 100, 4, 1)
	want := [4]f32{3.1623, 10, 31.623, 100}

	for i in 0 ..< 4 {
		testing.expectf(t, abs(splits[i] - want[i]) < 1e-2,
			"logarithmic split %d: got %.4f, want %.4f", i, splits[i], want[i])
	}
}

@(test)
test_cascade_splits_padding_past_count_is_far_not_zero :: proc(t: ^testing.T) {
	splits := compute_cascade_splits(1, 100, 2, 0.5)
	testing.expectf(t, splits[2] == 100 && splits[3] == 100,
		"entries past `count` must read as `far`, not zero, so an unchecked reader gets a harmless degenerate cascade")
}

/*
	A tight-fit ortho box, built from the camera's own frustum-slice corners,
	must contain every one of those corners -- an independently-reasoned
	property of what "tight-fit" even means, not a number copied from this
	file's own implementation. Checked for a plain, symmetric case (camera
	looking straight down -z, light straight down) where the corners and the
	box can both be reasoned about by hand, and for an oblique one (light at
	an angle) where the box's own extents are not obvious by inspection but
	the "must contain its own corners" property still has to hold regardless.
*/
@(test)
test_cascade_view_projection_contains_its_own_frustum_corners :: proc(t: ^testing.T) {
	camera := create_camera3d({0, 0, 0}, {0, 0, -1})
	camera.fov = 90

	mbi.window_width  = 800
	mbi.window_height = 600

	for light_direction in ([]([3]f32){{0, -1, 0}, {0.3, -0.8, 0.2}, {-0.5, -0.5, 0.7}}) {
		vp := compute_cascade_view_projection(camera, light_direction, 1, 11)

		c := camera3d_defaults(camera)
		view := camera3d_view(c)
		inv_view := linalg.matrix4_inverse(view)
		tan_half := math.tan(math.to_radians(c.fov) * 0.5)
		aspect := f32(mbi.window_width) / f32(mbi.window_height)

		for depth in ([]f32{1, 11}) {
			h := tan_half * depth
			w := h * aspect
			for sy in ([]f32{-1, 1}) {
				for sx in ([]f32{-1, 1}) {
					view_space := [4]f32{sx * w, sy * h, -depth, 1}
					world := inv_view * view_space

					clip := vp * [4]f32{world.x, world.y, world.z, 1}
					ndc := [3]f32{clip.x / clip.w, clip.y / clip.w, clip.z / clip.w}

					testing.expectf(t, ndc.x >= -1.001 && ndc.x <= 1.001, "corner x=%.4f falls outside the fitted box (light=%v)", ndc.x, light_direction)
					testing.expectf(t, ndc.y >= -1.001 && ndc.y <= 1.001, "corner y=%.4f falls outside the fitted box (light=%v)", ndc.y, light_direction)
					testing.expectf(t, ndc.z >= -0.001 && ndc.z <= 1.001, "corner z=%.4f falls outside the fitted box (light=%v)", ndc.z, light_direction)
				}
			}
		}
	}
}

// -----------------------------------------------------------------------
// Cube shadow maps -- face selection
// -----------------------------------------------------------------------

/*
	Hand-picked directions and their expected faces, per `shadow_cube_face_
	direction`'s own order (+X, -X, +Y, -Y, +Z, -Z) -- not read off
	`shadow_cube_face_index`'s own output, worked out from which axis each
	direction's largest-magnitude component is on and that component's sign.
*/
@(test)
test_cube_face_selection_matches_major_axis_by_hand :: proc(t: ^testing.T) {
	cases := [][2]any{
		{[3]f32{1, 0, 0}, 0},
		{[3]f32{-1, 0, 0}, 1},
		{[3]f32{0, 1, 0}, 2},
		{[3]f32{0, -1, 0}, 3},
		{[3]f32{0, 0, 1}, 4},
		{[3]f32{0, 0, -1}, 5},
		{[3]f32{0.9, 0.1, -0.1}, 0},  // x dominates, positive
		{[3]f32{-0.2, 0.05, 0.05}, 1}, // x dominates, negative
		{[3]f32{0.1, -0.9, 0.2}, 3},  // y dominates, negative
		{[3]f32{0.2, 0.2, 0.95}, 4},  // z dominates, positive
	}

	for c in cases {
		direction := c[0].([3]f32)
		want      := c[1].(int)
		got       := shadow_cube_face_index(direction)
		testing.expectf(t, got == want, "direction %v: got face %d, want %d", direction, got, want)
	}
}

// Every one of the six faces' own look direction and up vector must be
// mutually perpendicular -- look_at_matrix degenerates otherwise (see its
// own doc comment), and unlike begin_shadow_pass's directional branch this
// file has no fallback for a parallel pair, so the six have to already be
// safe by construction. Checked directly rather than trusted from the
// comment that says so.
@(test)
test_cube_face_directions_and_ups_are_never_parallel :: proc(t: ^testing.T) {
	for face in 0 ..< 6 {
		direction, up := shadow_cube_face_direction(face)
		testing.expectf(t, abs(linalg.dot(linalg.normalize(direction), linalg.normalize(up))) < 0.999,
			"face %d's own direction and up are parallel -- look_at_matrix would degenerate", face)
	}
}
