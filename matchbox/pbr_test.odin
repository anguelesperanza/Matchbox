package matchbox

/*
	PBR: closed-form anchors and the white-furnace test
	-----------------------------------------------------
	`lighting_rework.md` section 8's P2 gate for this phase: a white-furnace
	test for both PBR models -- under a uniform environment, an energy-
	conserving BRDF must not return more energy than it received, at any
	roughness -- plus the individual terms checked against independently
	worked-out numbers rather than against this file's own output. Both
	halves live here, following `brdf_test.odin`'s own pattern (a hand-written
	CPU mirror of the shader maths, not an import of it -- there is nothing on
	this side of the boundary to import, since the real maths is HLSL) and
	`tonemap_test.odin`'s (closed-form or independently-derived expected
	values, not a copy of whatever this file's own procs happen to return).

	**The two closed-form anchors.** GGX's distribution term has an exact
	value at `n_dot_h = 1` (worked out by hand in each test's own comment,
	not derived from `pbr_distribution_ggx` below), and Schlick's Fresnel
	term is exactly `f0` at normal incidence by construction (`pow(0, 5)` is
	0). Both are named directly in `brdf/pbr_common.hlsli`'s own doc comments
	as the anchors this file checks against.

	**The furnace test.** A numerical integration, not a single sample: for
	several roughness values, at two view angles (straight-on and grazing --
	energy conservation is most at risk near the Fresnel edge, so checking
	only normal incidence would miss the case most likely to break), sum
	`(diffuse + specular) * n_dot_l` over the whole hemisphere for a uniform,
	radiance-1 environment, and confirm the total never exceeds 1 by more
	than the sum's own numerical-integration error. A Riemann sum in
	spherical coordinates is used rather than Monte Carlo so the test is
	deterministic -- no seed to pin down or explain, and no flaked run to
	investigate later.

	`pbr_test_metallic_furnace_total` and `pbr_test_specgloss_furnace_total`
	below duplicate the same integration loop rather than sharing it behind a
	passed-in evaluator -- Odin's `proc` values do not close over locals, so
	the natural way to parameterize the loop over "which model" would be a
	context pointer threaded through by hand, which buys nothing here over
	two short, obviously-parallel functions. `brdf_test.odin` makes the same
	choice for its own fused/split mirrors.

	**What "energy-conserving" does not mean here.** A single-scattering
	microfacet BRDF is well known to *lose* energy at high roughness --
	light that would have bounced between microfacets a second time before
	leaving is simply gone, which is why some engines add a Kulla-Conty (or
	similar) multi-scatter compensation term. Neither PBR model in this phase
	adds one (out of scope for P2c -- a compensation term is a rendering
	choice layered on top of a BRDF, not part of the contract), so the totals
	below are expected to sit at or under 1, not pinned to it. The property
	under test is "never over 1 at any roughness", which is what an actual
	energy-gaining bug (a missing division, a doubled Fresnel term) would
	violate.
*/

import "core:math"
import "core:math/linalg"
import "core:testing"

@(private = "file")
PBR_TEST_PI :: f32(3.14159265358979323846)

// A small margin over 1 for the furnace totals below to still count as "did
// not gain energy" -- this absorbs the Riemann sum's own quadrature error
// (a finite grid), not a bug's. Every configuration this file actually
// checks lands under 1.01; anything pushing meaningfully past this margin is
// the BRDF creating energy, which is the failure this test exists to catch.
@(private = "file")
FURNACE_TEST_MARGIN :: f32(1.02)

/*
	The Riemann grid's own resolution, shared by both furnace integrals below.
	120x240 (the first value tried) looked fine everywhere except one corner:
	a near-mirror surface (roughness 0.05) viewed straight along the normal
	puts the entire specular lobe's energy into an angular width of a few
	tenths of a degree, sitting exactly at spherical coordinates' own pole --
	the single worst case for a uniform theta/phi grid, since the solid angle
	per cell shrinks to zero there while the function value does not. That
	configuration's own total did not converge monotonically as the grid was
	refined (120x240 gave 1.039, 250x500 gave 1.168, worse) -- a sign of
	aliasing against the lobe's width, not of slowly-diminishing quadrature
	error -- and only settled below 1 once the grid was refined past roughly
	1500x3000 in an independent Python check. 800x1600 is the point along that
	same convergence curve chosen for this file: comfortably under
	`FURNACE_TEST_MARGIN` for that worst case (measured ~1.011, against
	1500x3000's ~1.001) without paying for the last, unnecessary digit of
	precision in a test that only needs to know the total did not exceed 1.
*/
@(private = "file")
FURNACE_N_THETA :: 800
@(private = "file")
FURNACE_N_PHI :: 1600

// Mirrors `pbr_distribution_ggx` (`shaders/brdf/pbr_common.hlsli`) statement
// for statement, epsilon included -- see that function's own comment for why
// the epsilon is 1e-12 and not merely "some small number".
@(private = "file")
pbr_test_distribution_ggx :: proc(n_dot_h, roughness: f32) -> f32 {
	a  := roughness * roughness
	a2 := a * a
	d  := (n_dot_h * n_dot_h) * (a2 - 1.0) + 1.0

	return a2 / (PBR_TEST_PI * d * d + 1e-12)
}

// Mirrors `pbr_visibility_smith_ggx` (`shaders/brdf/pbr_common.hlsli`).
@(private = "file")
pbr_test_visibility_smith_ggx :: proc(n_dot_v, n_dot_l, roughness: f32) -> f32 {
	a  := roughness * roughness
	a2 := a * a

	ggx_v := n_dot_l * math.sqrt(n_dot_v * n_dot_v * (1.0 - a2) + a2)
	ggx_l := n_dot_v * math.sqrt(n_dot_l * n_dot_l * (1.0 - a2) + a2)

	return 0.5 / max(ggx_v + ggx_l, 1e-5)
}

// Mirrors `pbr_fresnel_schlick` (`shaders/brdf/pbr_common.hlsli`).
@(private = "file")
pbr_test_fresnel_schlick :: proc(cos_theta: f32, f0: [3]f32) -> [3]f32 {
	m := clamp(1.0 - cos_theta, 0, 1)
	return f0 + (1 - f0) * (m * m * m * m * m)
}

@(test)
test_ggx_distribution_closed_form_at_normal_incidence :: proc(t: ^testing.T) {
	// At n_dot_h = 1: d = 1*(a2 - 1) + 1 = a2, so
	// D = a2 / (PI * a2^2) = 1 / (PI * a2) = 1 / (PI * roughness^4).
	// Worked out by hand from pbr_distribution_ggx's own formula, not by
	// running it and reading off the answer.
	//
	// A relative tolerance, not TONEMAP_TEST_EPSILON's absolute 1e-4: D
	// legitimately spans from single digits (rough) into the thousands
	// (roughness=0.1's own closed form is ~3183), and an absolute epsilon
	// tuned for tonemap's own [0,1]-ish outputs would be meaninglessly tight
	// at one end of that range and meaninglessly loose at the other.
	//
	// 1e-3, not 1e-4: `d = n_dot_h^2 * (a2 - 1) + 1` is exactly `a2` by
	// algebra at `n_dot_h = 1`, but computed in float32 as `(a2 - 1) + 1` --
	// subtracting two values near 1 and adding 1 back destroys the low-order
	// bits of the small `a2` those two near-cancelling terms were hiding
	// (catastrophic cancellation), so the smaller `roughness` is, the more of
	// `a2`'s own precision this specific formula throws away before `D` ever
	// divides by it. That precision loss is a real, measured property of the
	// exact formula `pbr_distribution_ggx` uses (checked here, not asserted
	// on faith) rather than a mistake in either it or this test -- the
	// alternative would be a different, less standard formulation of GGX
	// solely to make one closed-form test tighter, which is not a trade this
	// phase makes.
	roughnesses := []f32{0.1, 0.3, 0.5, 0.8, 1.0}

	for roughness in roughnesses {
		got  := pbr_test_distribution_ggx(1.0, roughness)
		a    := roughness * roughness
		want := 1.0 / (PBR_TEST_PI * a * a)

		testing.expectf(t, math.abs(got - want) / want < 1e-3,
			"GGX D at n_dot_h=1, roughness=%.2f: got %.7f, want %.7f (closed form 1/(pi*roughness^4))",
			roughness, got, want)
	}
}

@(test)
test_schlick_fresnel_at_normal_incidence_equals_f0_exactly :: proc(t: ^testing.T) {
	// pow(1 - cos_theta, 5) at cos_theta = 1 is pow(0, 5) = 0 exactly, so the
	// whole (1 - f0) * (...) term vanishes and this reduces to f0 -- true for
	// any f0, so a dielectric, a coloured metal and a degenerate all-zero f0
	// are all checked.
	f0s := [][3]f32{{0.04, 0.04, 0.04}, {1.0, 0.86, 0.57}, {0.0, 0.0, 0.0}}

	for f0 in f0s {
		got := pbr_test_fresnel_schlick(1.0, f0)
		expect_close3(t, got, f0, "Schlick Fresnel at cos_theta=1 must equal f0 exactly")
	}
}

/*
	The furnace integral for the metallic-roughness model: fix a view
	direction at `view_cos_theta` above a flat surface with `roughness` and
	`metallic`, then sum `(diffuse + specular) * n_dot_l * domega` over the
	whole hemisphere for a uniform radiance-1 environment. A Riemann sum in
	spherical coordinates (`n_theta` x `n_phi` cells) rather than Monte Carlo
	-- see this file's own top comment for why determinism was chosen over
	an unbiased estimator here.

	Mirrors `brdf_light_pbr_metallic` (`shaders/brdf/pbr_metallic.hlsli`)
	minus `light.radiance`/`light.n_dot_l` -- this integral supplies both
	itself (radiance 1 for every direction, `n_dot_l` as the integration
	weight), so what runs per grid cell is the bare BRDF value the shader
	would otherwise multiply those into.
*/
@(private = "file")
pbr_test_metallic_furnace_total :: proc(roughness, metallic: f32, base_color: [3]f32, view_cos_theta: f32) -> [3]f32 {
	n_theta := FURNACE_N_THETA
	n_phi   := FURNACE_N_PHI

	sin_v  := math.sqrt(max(f32(0), 1 - view_cos_theta * view_cos_theta))
	view   := [3]f32{sin_v, 0, view_cos_theta}
	normal := [3]f32{0, 0, 1}
	n_dot_v := max(view_cos_theta, 1e-4)

	f0 := (1 - metallic) * [3]f32{0.04, 0.04, 0.04} + metallic * base_color

	dtheta := (PBR_TEST_PI * 0.5) / f32(n_theta)
	dphi   := (2 * PBR_TEST_PI) / f32(n_phi)

	total := [3]f32{0, 0, 0}

	for ti in 0 ..< n_theta {
		theta   := (f32(ti) + 0.5) * dtheta
		sin_t   := math.sin(theta)
		cos_t   := math.cos(theta)
		n_dot_l := cos_t // dot(normal, l) where normal = (0, 0, 1)
		domega  := sin_t * dtheta * dphi

		if n_dot_l <= 0 do continue

		for pi_i in 0 ..< n_phi {
			phi := (f32(pi_i) + 0.5) * dphi
			l   := [3]f32{sin_t * math.cos(phi), sin_t * math.sin(phi), cos_t}
			h   := linalg.normalize(view + l)

			n_dot_h := max(linalg.dot(normal, h), 0)
			v_dot_h := max(linalg.dot(view, h), 0)

			d := pbr_test_distribution_ggx(n_dot_h, roughness)
			v := pbr_test_visibility_smith_ggx(n_dot_v, n_dot_l, roughness)
			f := pbr_test_fresnel_schlick(v_dot_h, f0)

			specular := f * (d * v)

			// Two-sided diffuse Fresnel transmission -- mirrors the fix
			// documented in brdf/pbr_metallic.hlsli's own top comment, found
			// by an earlier version of this exact furnace test failing with
			// the specular term's own v_dot_h-based F used for diffuse too.
			f_v     := pbr_test_fresnel_schlick(n_dot_v, f0)
			f_l     := pbr_test_fresnel_schlick(n_dot_l, f0)
			kd      := (1 - f_v) * (1 - f_l) * (1 - metallic)
			diffuse := kd * base_color / PBR_TEST_PI

			total += (diffuse + specular) * n_dot_l * domega
		}
	}

	return total
}

@(test)
test_pbr_metallic_furnace_never_gains_energy :: proc(t: ^testing.T) {
	base_color := [3]f32{1, 1, 1} // white -- isolates the BRDF's own shape from any albedo darkening

	// The full roughness range 0..1, avoiding the literal 0 endpoint -- a
	// perfect mirror is a Dirac delta this Riemann sum's finite grid cannot
	// resolve (the real shader clamps away from it for the same reason, see
	// PBR_MIN_ROUGHNESS's own comment in brdf/pbr_common.hlsli), so the sweep
	// starts just above that floor instead of pretending to test a value no
	// renderer in this package ever actually evaluates.
	roughnesses := []f32{0.05, 0.15, 0.3, 0.5, 0.7, 0.85, 1.0}
	view_angles := []f32{1.0, 0.2} // straight-on, then grazing (~78.5 degrees)
	metallics   := []f32{0.0, 1.0} // dielectric, then full metal

	for view_cos in view_angles {
		for metallic in metallics {
			for roughness in roughnesses {
				total := pbr_test_metallic_furnace_total(roughness, metallic, base_color, view_cos)
				peak  := max(total.x, max(total.y, total.z))

				testing.expectf(t, peak < FURNACE_TEST_MARGIN,
					"pbr_metallic furnace total exceeded 1 at roughness=%.2f, metallic=%.1f, view_cos=%.2f: got %.5f",
					roughness, metallic, view_cos, peak)
				testing.expectf(t, peak > 0,
					"pbr_metallic furnace total was zero at roughness=%.2f, metallic=%.1f, view_cos=%.2f -- the integral is not exercising the BRDF",
					roughness, metallic, view_cos)
			}
		}
	}
}

// The same integral under the specular-glossiness parameterization -- mirrors
// `brdf_light_pbr_specgloss` (`shaders/brdf/pbr_specgloss.hlsli`) the same
// trimmed way `pbr_test_metallic_furnace_total` mirrors its own model. `f0`
// is passed straight through rather than derived, since spec-gloss reads it
// straight off `Surface.specular` with no metallic lerp.
@(private = "file")
pbr_test_specgloss_furnace_total :: proc(roughness: f32, f0, base_color: [3]f32, view_cos_theta: f32) -> [3]f32 {
	n_theta := FURNACE_N_THETA
	n_phi   := FURNACE_N_PHI

	sin_v   := math.sqrt(max(f32(0), 1 - view_cos_theta * view_cos_theta))
	view    := [3]f32{sin_v, 0, view_cos_theta}
	normal  := [3]f32{0, 0, 1}
	n_dot_v := max(view_cos_theta, 1e-4)

	dtheta := (PBR_TEST_PI * 0.5) / f32(n_theta)
	dphi   := (2 * PBR_TEST_PI) / f32(n_phi)

	total := [3]f32{0, 0, 0}

	for ti in 0 ..< n_theta {
		theta   := (f32(ti) + 0.5) * dtheta
		sin_t   := math.sin(theta)
		cos_t   := math.cos(theta)
		n_dot_l := cos_t
		domega  := sin_t * dtheta * dphi

		if n_dot_l <= 0 do continue

		for pi_i in 0 ..< n_phi {
			phi := (f32(pi_i) + 0.5) * dphi
			l   := [3]f32{sin_t * math.cos(phi), sin_t * math.sin(phi), cos_t}
			h   := linalg.normalize(view + l)

			n_dot_h := max(linalg.dot(normal, h), 0)
			v_dot_h := max(linalg.dot(view, h), 0)

			d := pbr_test_distribution_ggx(n_dot_h, roughness)
			v := pbr_test_visibility_smith_ggx(n_dot_v, n_dot_l, roughness)
			f := pbr_test_fresnel_schlick(v_dot_h, f0)

			specular := f * (d * v)

			f_v     := pbr_test_fresnel_schlick(n_dot_v, f0)
			f_l     := pbr_test_fresnel_schlick(n_dot_l, f0)
			diffuse := (1 - f_v) * (1 - f_l) * base_color / PBR_TEST_PI

			total += (diffuse + specular) * n_dot_l * domega
		}
	}

	return total
}

@(test)
test_pbr_specgloss_furnace_never_gains_energy :: proc(t: ^testing.T) {
	base_color := [3]f32{1, 1, 1}

	roughnesses := []f32{0.05, 0.15, 0.3, 0.5, 0.7, 0.85, 1.0}
	view_angles := []f32{1.0, 0.2}
	// A dielectric-typical f0 and a coloured, highly-reflective one -- the
	// spec-gloss equivalent of the metallic sweep's two `metallic` values,
	// since this parameterization has no metalness dial of its own to sweep.
	f0s := [][3]f32{{0.04, 0.04, 0.04}, {0.9, 0.7, 0.3}}

	for view_cos in view_angles {
		for f0 in f0s {
			for roughness in roughnesses {
				total := pbr_test_specgloss_furnace_total(roughness, f0, base_color, view_cos)
				peak  := max(total.x, max(total.y, total.z))

				testing.expectf(t, peak < FURNACE_TEST_MARGIN,
					"pbr_specgloss furnace total exceeded 1 at roughness=%.2f, f0=%v, view_cos=%.2f: got %.5f",
					roughness, f0, view_cos, peak)
				testing.expectf(t, peak > 0,
					"pbr_specgloss furnace total was zero at roughness=%.2f, f0=%v, view_cos=%.2f -- the integral is not exercising the BRDF",
					roughness, f0, view_cos)
			}
		}
	}
}
