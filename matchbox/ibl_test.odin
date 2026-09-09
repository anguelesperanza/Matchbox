package matchbox

/*
	Image-based lighting -- closed-form anchors and a uniform-environment sweep
	--------------------------------------------------------------------------
	`lighting_rework.md` section 8's own P4 gate: "the split-sum BRDF LUT is a
	function of roughness and n.v with closed-form behaviour at its edges, and
	a white-furnace sweep applies the way pbr_test.odin already sweeps
	roughness." Two independent things get checked here, following
	`pbr_test.odin`'s own pattern (a hand-written CPU mirror of the shader
	maths, expected values sourced independently rather than by running this
	file's own procs and reading off the answer):

	- **`pbr_env_brdf_approx`'s (brdf/pbr_common.hlsli) own closed-form
	  identity.** Not "scale=1, bias=0 at roughness 0" -- that is the real
	  split-sum integral's own anchor, and this polynomial fit does not reach
	  it exactly (see that function's own doc comment for the corrected
	  claim, found while writing this test rather than assumed going in).
	  What the fit *does* hit exactly, derivable from its own algebra:
	  `scale + bias == 1 - 0.55 * roughness`, for every `n_dot_v`. Checked
	  both as that exact identity (swept across roughness and n_dot_v) and,
	  once, against a numeric anchor worked out independently in Node
	  (`node`, a separate language and runtime from both the Odin mirror
	  below and the HLSL original) rather than derived from either.
	- **The two bake convolutions' own normalization, under a uniform
	  environment.** `probe_irradiance.frag.hlsl` and `probe_prefilter.frag.hlsl`
	  cannot be run here -- no GPU capture tooling exists in this environment,
	  so this is the shader maths mirrored on the CPU, the same limit
	  `pbr_test.odin`'s own top comment already states plainly for the PBR
	  furnace test. A uniform environment of radiance L is the one case where
	  the "correct" output is known in closed form for both bakes:
	  irradiance's cosine-weighted hemisphere integral of a constant L
	  converges to exactly L once divided by pi (a fact about the continuous
	  integral, not this code), and the prefilter's cone blur is an
	  algebraic weighted average of L samples, which returns exactly L
	  regardless of cone width or grid resolution. The irradiance mirror's
	  own grid (12x24, matching the shader's) converges to that L slowly
	  enough to have a measurable quadrature error at that exact resolution
	  -- worked out independently in Node below, not read off this file's own
	  output -- while the prefilter mirror's weighted average has no such
	  error at any resolution.
*/

import "core:math"
import "core:testing"

// Mirrors pbr_env_brdf_approx (brdf/pbr_common.hlsli) statement for
// statement.
@(private = "file")
ibl_test_env_brdf_approx :: proc(roughness, n_dot_v: f32) -> (scale, bias: f32) {
	c0 := [4]f32{-1.0, -0.0275, -0.572, 0.022}
	c1 := [4]f32{1.0, 0.0425, 1.04, -0.04}

	r := c0 * roughness + c1
	// HLSL's exp2(x) is pow(2, x) -- core:math has no exp2 of its own.
	a004 := min(r.x * r.x, math.pow(f32(2), -9.28 * n_dot_v)) * r.x + r.y

	scale = -1.04 * a004 + r.z
	bias  = 1.04 * a004 + r.w
	return
}

/*
	The exact identity, swept: `scale + bias` never depends on `n_dot_v` or on
	`a004` at all, since both cancel out of the sum algebraically (see
	pbr_env_brdf_approx's own doc comment for the derivation) -- so this must
	hold to float precision, not to the "a few percent" tolerance the fit's
	own *accuracy against a real split-sum integral* would need.
*/
@(test)
test_env_brdf_approx_scale_plus_bias_is_exact_identity :: proc(t: ^testing.T) {
	roughnesses := []f32{0.0, 0.05, 0.25, 0.5, 0.75, 1.0}
	n_dot_vs    := []f32{1.0, 0.7, 0.3, 0.05}

	for roughness in roughnesses {
		want := 1.0 - 0.55 * roughness

		for n_dot_v in n_dot_vs {
			scale, bias := ibl_test_env_brdf_approx(roughness, n_dot_v)
			got := scale + bias

			testing.expectf(t, math.abs(got - want) < 1e-5,
				"scale+bias must equal 1-0.55*roughness regardless of n_dot_v (roughness=%.2f, n_dot_v=%.2f): got %.7f, want %.7f",
				roughness, n_dot_v, got, want)
		}
	}
}

// The one numeric anchor, worked out independently in Node
// (`node /tmp/env_brdf.js`, the same formula transcribed into JavaScript
// rather than derived from this file or from the HLSL): at roughness=0,
// n_dot_v=1, scale=0.99412708, bias=0.00587292 -- close to the real
// split-sum integral's own exact (1, 0) anchor but not equal to it, which is
// the point of not claiming exactness in the doc comment this test backs.
@(test)
test_env_brdf_approx_near_mirror_anchor :: proc(t: ^testing.T) {
	scale, bias := ibl_test_env_brdf_approx(0.0, 1.0)

	testing.expectf(t, math.abs(scale - 0.99412708) < 1e-6, "scale at roughness=0,n_dot_v=1: got %.8f, want 0.99412708", scale)
	testing.expectf(t, math.abs(bias - 0.00587292) < 1e-6, "bias at roughness=0,n_dot_v=1: got %.8f, want 0.00587292", bias)
}

// -----------------------------------------------------------------------
// The two probe bakes, mirrored -- see this file's own top comment for why
// a uniform environment is the one input with a known closed-form answer.
// -----------------------------------------------------------------------

@(private = "file")
IBL_TEST_PI :: f32(3.14159265358979323846)

// Mirrors probe_irradiance.frag.hlsl's own loop exactly: same grid
// (12x24), same tangent-frame construction, same cosine-weighted solid
// angle, same division by pi. `env` stands in for a sampled TextureCube --
// a plain proc value, since this runs on the CPU and never touches a GPU
// resource.
@(private = "file")
ibl_test_irradiance_convolution :: proc(n: [3]f32, env: proc(dir: [3]f32) -> [3]f32) -> [3]f32 {
	n_theta :: 12
	n_phi   :: 24

	up_hint := abs(n.y) < 0.999 ? [3]f32{0, 1, 0} : [3]f32{1, 0, 0}
	right   := la_normalize(la_cross(up_hint, n))
	up      := la_cross(n, right)

	dtheta := (IBL_TEST_PI * 0.5) / f32(n_theta)
	dphi   := (2.0 * IBL_TEST_PI) / f32(n_phi)

	irradiance := [3]f32{0, 0, 0}

	for ti in 0 ..< n_theta {
		theta  := (f32(ti) + 0.5) * dtheta
		sin_t  := math.sin(theta)
		cos_t  := math.cos(theta)
		weight := sin_t * cos_t * dtheta * dphi

		for pi_i in 0 ..< n_phi {
			phi        := (f32(pi_i) + 0.5) * dphi
			local_dir  := [3]f32{sin_t * math.cos(phi), sin_t * math.sin(phi), cos_t}
			sample_dir := local_dir.x * right + local_dir.y * up + local_dir.z * n

			c := env(sample_dir)
			irradiance += c * weight
		}
	}

	return irradiance / IBL_TEST_PI
}

// Mirrors probe_prefilter.frag.hlsl's own loop: same grid (8x16), same
// roughness-squared cone half-angle, same mirror short-circuit at
// roughness 0, same weighted-average normalization.
@(private = "file")
ibl_test_prefilter_convolution :: proc(r: [3]f32, roughness: f32, env: proc(dir: [3]f32) -> [3]f32) -> [3]f32 {
	n_theta :: 8
	n_phi   :: 16

	cone_half_angle := roughness * roughness * (IBL_TEST_PI * 0.5)
	if cone_half_angle <= 1e-5 {
		return env(r)
	}

	up_hint := abs(r.y) < 0.999 ? [3]f32{0, 1, 0} : [3]f32{1, 0, 0}
	right   := la_normalize(la_cross(up_hint, r))
	up      := la_cross(r, right)

	dtheta := cone_half_angle / f32(n_theta)
	dphi   := (2.0 * IBL_TEST_PI) / f32(n_phi)

	total      := [3]f32{0, 0, 0}
	weight_sum := f32(0)

	for ti in 0 ..< n_theta {
		theta  := (f32(ti) + 0.5) * dtheta
		sin_t  := math.sin(theta)
		cos_t  := math.cos(theta)
		weight := sin_t * cos_t

		for pi_i in 0 ..< n_phi {
			phi        := (f32(pi_i) + 0.5) * dphi
			local_dir  := [3]f32{sin_t * math.cos(phi), sin_t * math.sin(phi), cos_t}
			sample_dir := local_dir.x * right + local_dir.y * up + local_dir.z * r

			total      += env(sample_dir) * weight
			weight_sum += weight
		}
	}

	return total / max(weight_sum, 1e-6)
}

@(private = "file")
la_cross :: proc(a, b: [3]f32) -> [3]f32 {
	return {a.y*b.z - a.z*b.y, a.z*b.x - a.x*b.z, a.x*b.y - a.y*b.x}
}

@(private = "file")
la_normalize :: proc(v: [3]f32) -> [3]f32 {
	l := math.sqrt(v.x*v.x + v.y*v.y + v.z*v.z)
	return v / l
}

/*
	Irradiance under a uniform environment: worked out independently in Node
	(`node /tmp/irradiance_check.js`) as the exact midpoint-rule sum this
	grid computes -- the phi axis contributes no quadrature error at all for
	a uniform environment (its own weight has no phi-dependence, so summing
	`n_phi` equal slices always totals exactly 2*pi regardless of `n_phi`),
	so the whole grid's error is the theta axis's own 12-cell midpoint sum
	of sin(theta)*cos(theta) over [0, pi/2], which does not equal the
	continuum's exact 1/2 at only 12 cells. That sum, doubled (the pi in the
	denominator cancels one of the two pi's in "phi's own exact 2*pi"),
	comes out to 1.0028615075 -- i.e. this bake overshoots a uniform
	environment's own radiance by about 0.29% at its own grid resolution,
	converging toward exactly 1.0 as the grid refines (checked in the same
	Node script at 24/100/10000 cells: 1.00071, 1.00004, 1.0000000041).
*/
@(test)
test_irradiance_convolution_uniform_environment :: proc(t: ^testing.T) {
	uniform_l := [3]f32{2.0, 0.5, 1.25}
	env := proc(dir: [3]f32) -> [3]f32 { return {2.0, 0.5, 1.25} }

	directions := [][3]f32{{0, 1, 0}, {0, -1, 0}, {1, 0, 0}, {0, 0, 1}, la_normalize({1, 1, 1})}

	want_factor := f32(1.0028615075)

	for n in directions {
		got  := ibl_test_irradiance_convolution(n, env)
		want := uniform_l * want_factor

		testing.expectf(t, abs(got.x-want.x) < 1e-4 && abs(got.y-want.y) < 1e-4 && abs(got.z-want.z) < 1e-4,
			"irradiance convolution of a uniform environment should equal L * %.7f (this grid's own known quadrature factor), direction=%v: got %v, want %v",
			want_factor, n, got, want)
	}
}

/*
	Prefilter under a uniform environment: an algebraic weighted average of
	the same constant value is that value, exactly, regardless of cone
	width or grid resolution -- Sum(w * L) / Sum(w) == L for any set of
	weights `w` as long as at least one is nonzero. Swept across every
	roughness level a real bake would use (`ENVIRONMENT_PROBE_DEFAULTS.
	prefilter_level_count` is 5, ambient.odin) plus the roughness=0 mirror
	short-circuit, rather than spot-checked at one -- CLAUDE.md's own
	"do not spot-check where a sweep is possible", and the specific
	motivation `pbr_test.odin`'s own top comment names: a sweep is what
	catches a bug a single well-chosen sample would not.
*/
@(test)
test_prefilter_convolution_uniform_environment :: proc(t: ^testing.T) {
	uniform_l := [3]f32{0.8, 1.6, 0.3}
	env := proc(dir: [3]f32) -> [3]f32 { return {0.8, 1.6, 0.3} }

	level_count := 5
	directions := [][3]f32{{0, 1, 0}, {1, 0, 0}, la_normalize({1, 1, 1}), {0, 0, -1}}

	for level in 0 ..< level_count {
		roughness := f32(level) / f32(level_count - 1)

		for r in directions {
			got := ibl_test_prefilter_convolution(r, roughness, env)

			testing.expectf(t, abs(got.x-uniform_l.x) < 1e-5 && abs(got.y-uniform_l.y) < 1e-5 && abs(got.z-uniform_l.z) < 1e-5,
				"prefilter convolution of a uniform environment should equal L exactly (roughness=%.2f, direction=%v): got %v, want %v",
				roughness, r, got, uniform_l)
		}
	}
}
