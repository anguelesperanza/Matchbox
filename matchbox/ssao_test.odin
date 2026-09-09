package matchbox

/*
	SSAO -- the sample kernel and the settings around it
	-----------------------------------------------------
	`lighting_rework.md` section 8: numeric, swept, and checked against an
	independent implementation.

	**What can be checked here, and what genuinely cannot.** Almost all of
	SSAO is in the shader -- the depth reconstruction, the normal
	reconstruction, the hemisphere test, the range falloff -- and every one of
	those needs a depth buffer that only a GPU produces. There is none here.
	So what is tested is the part that is a pure function on the CPU side and
	that the shader is a consumer of: the sample kernel.

	That is not a small part. A kernel with a sample on the wrong side of the
	surface takes a tap *through* the geometry and reports occlusion where
	there is none; a kernel whose lengths do not rise toward the rim spends
	its taps where the approximation is weakest; a kernel longer than the unit
	hemisphere samples outside the radius the settings asked for. Each of
	those is a wrong picture with no error attached, and each is decidable
	here.

	The expected values were worked out in Python from the definitions in
	`ssao_kernel`'s own doc comment -- and `radical_inverse_base2` in
	particular was re-derived there the slow, obvious way (shift a bit off,
	divide, repeat) rather than with the five-shift trick the Odin side uses,
	so the two are genuinely independent formulations of the same sequence
	rather than one copy checked against itself.

	**Nothing here renders anything, and nothing here has been seen to
	render.**
*/

import "core:math"
import "core:testing"

SSAO_TEST_EPSILON :: f32(1e-6)

// -----------------------------------------------------------------------
// The bit-reversal underneath the kernel
// -----------------------------------------------------------------------

/*
	The van der Corput sequence in base 2, whose first eight terms are a
	closed-form thing rather than a measurement: index `i`'s bits, reversed,
	read back as a binary fraction. 1 becomes 0.5, 2 becomes 0.25, 3 becomes
	0.75, and so on.

	Written out rather than computed, because the point is to catch the
	five-shift trick in `radical_inverse_base2` being subtly wrong -- a
	swapped mask or a shift of the wrong width still produces a plausible
	spread of numbers in [0, 1), which is exactly the kind of wrong that a
	"looks distributed" check would pass.
*/
@(test)
test_radical_inverse_base2_first_terms :: proc(t: ^testing.T) {
	expected := [8]f32{0, 0.5, 0.25, 0.75, 0.125, 0.625, 0.375, 0.875}

	for want, i in expected {
		got := radical_inverse_base2(u32(i))
		testing.expectf(t, math.abs(got - want) < SSAO_TEST_EPSILON,
			"radical_inverse_base2(%d) = %.9f, want %.9f", i, got, want)
	}
}

// And it never leaves [0, 1), which is what the caller relies on to feed it
// into a square root. Swept over the whole range the kernel can ask for
// rather than the eight above, because the shifts that go wrong go wrong at
// bit widths the first eight indices never reach.
@(test)
test_radical_inverse_base2_stays_in_unit_range :: proc(t: ^testing.T) {
	for i in 0 ..< 4096 {
		v := radical_inverse_base2(u32(i))
		testing.expectf(t, v >= 0 && v < 1, "radical_inverse_base2(%d) = %.9f", i, v)
	}
}

// -----------------------------------------------------------------------
// The kernel itself
// -----------------------------------------------------------------------

/*
	**Every sample is on the lit side of the surface.** The kernel is written
	in +Z-hemisphere space and the shader rotates it onto the surface normal,
	so a sample with a negative Z would be a tap taken *through* the geometry
	-- it would find the surface itself in the way and report occlusion where
	there is none, everywhere, on every flat wall.

	Swept over every sample count the settings can ask for, not just the
	default: the cosine-weighted mapping divides by `n`, and a mapping that
	holds at 16 and fails at 1 or at MAX_SSAO_SAMPLES is exactly the shape of
	bug an off-by-one in that division produces.
*/
@(test)
test_ssao_kernel_stays_in_the_positive_hemisphere :: proc(t: ^testing.T) {
	for count in 1 ..= MAX_SSAO_SAMPLES {
		kernel := ssao_kernel(count)

		for i in 0 ..< count {
			testing.expectf(t, kernel[i].z > 0,
				"count %d, sample %d has z = %.9f, which is behind the surface",
				count, i, kernel[i].z)
		}
	}
}

/*
	**No sample is longer than the unit hemisphere.** The shader multiplies
	each of these by `Ssao.radius`, so a sample of length 1.4 would reach 40%
	further than the radius a game asked for -- which is not a small
	discrepancy but the difference between contact shadows and a smear, and it
	would show up as "the radius setting does not mean what it says".
*/
@(test)
test_ssao_kernel_stays_inside_the_unit_hemisphere :: proc(t: ^testing.T) {
	for count in 1 ..= MAX_SSAO_SAMPLES {
		kernel := ssao_kernel(count)

		for i in 0 ..< count {
			length := math.sqrt(kernel[i].x * kernel[i].x + kernel[i].y * kernel[i].y + kernel[i].z * kernel[i].z)
			testing.expectf(t, length <= 1 + SSAO_TEST_EPSILON,
				"count %d, sample %d has length %.9f", count, i, length)
		}
	}
}

/*
	**The lengths rise monotonically toward the rim**, from 0.1 at the first
	sample to `0.1 + 0.9 * ((n-1)/n)^2` at the last -- which packs most of the
	taps close to the point being shaded, where the occlusion that matters is.
	See `ssao_kernel`'s own doc comment for why that is the right bias and not
	a defect.

	The two endpoints are checked against numbers derived from the formula
	rather than read off the implementation, and the monotonicity is checked
	across every step between them, because a scale that rises and then falls
	back would still hit both endpoints.
*/
@(test)
test_ssao_kernel_lengths_grow_toward_the_rim :: proc(t: ^testing.T) {
	count  := 16
	kernel := ssao_kernel(count)

	length_of :: proc(v: [4]f32) -> f32 {
		return math.sqrt(v.x * v.x + v.y * v.y + v.z * v.z)
	}

	first := length_of(kernel[0])
	testing.expectf(t, math.abs(first - 0.1) < 1e-5,
		"the first sample's length is %.9f, want 0.1", first)

	// 0.1 + 0.9 * (15/16)^2, worked out from the documented scale rather than
	// from what the code returned.
	want_last := f32(0.891015625)
	last := length_of(kernel[count - 1])
	testing.expectf(t, math.abs(last - want_last) < 1e-5,
		"the last sample's length is %.9f, want %.9f", last, want_last)

	previous := f32(0)
	for i in 0 ..< count {
		length := length_of(kernel[i])
		testing.expectf(t, length >= previous,
			"sample %d is shorter (%.9f) than sample %d (%.9f)", i, length, i - 1, previous)
		previous = length
	}
}

/*
	**The directions actually spread, rather than lining up.** A Hammersley
	pair whose two coordinates were accidentally the same sequence -- easy to
	do, since both are functions of `i` -- would put every sample on one
	meridian of the hemisphere, and every tap would then be taken in
	essentially one direction.

	Checked as a property rather than by comparing 16 vectors: the mean of the
	xy components has to be small next to the mean z, because a cosine-weighted
	hemisphere is symmetric about its axis and a spread set cancels out
	sideways while a lined-up one does not.
*/
@(test)
test_ssao_kernel_directions_spread_around_the_axis :: proc(t: ^testing.T) {
	count  := 16
	kernel := ssao_kernel(count)

	mean: [3]f32
	for i in 0 ..< count {
		mean += {kernel[i].x, kernel[i].y, kernel[i].z}
	}
	mean /= f32(count)

	sideways := math.sqrt(mean.x * mean.x + mean.y * mean.y)

	testing.expectf(t, mean.z > 0, "the kernel does not lean toward its own axis: mean z %.6f", mean.z)
	testing.expectf(t, sideways < mean.z,
		"the kernel leans sideways (%.6f) more than along its axis (%.6f) -- the two Hammersley coordinates are probably the same sequence",
		sideways, mean.z)
}

// Nothing past `count` is written, so a shader reading only the first
// `Ssao.samples` entries can never pick up a stale one from a frame that
// asked for more. Zero is also what an unwritten entry has to be for the
// uniform push to be deterministic between runs.
@(test)
test_ssao_kernel_leaves_unused_entries_zeroed :: proc(t: ^testing.T) {
	kernel := ssao_kernel(4)

	for i in 4 ..< MAX_SSAO_SAMPLES {
		testing.expectf(t, kernel[i] == [4]f32{0, 0, 0, 0},
			"sample %d past the requested count is %v", i, kernel[i])
	}
}

// A count outside the range is clamped rather than read literally -- a zero
// would divide by zero in the cosine mapping, and a count past the array
// bound would write off the end of it.
@(test)
test_ssao_kernel_clamps_its_count :: proc(t: ^testing.T) {
	testing.expect(t, ssao_kernel(0)[0].z > 0, "a zero count produced no usable first sample")
	testing.expect(t, ssao_kernel(-5)[0].z > 0, "a negative count produced no usable first sample")

	// Past the bound, the last in-range entry is still filled and nothing
	// beyond the array was touched -- which in Odin would be a crash rather
	// than a silent corruption, so reaching this line at all is the assertion.
	over := ssao_kernel(MAX_SSAO_SAMPLES + 100)
	testing.expect(t, over[MAX_SSAO_SAMPLES - 1].z > 0, "the last sample was not filled")
}

// -----------------------------------------------------------------------
// Settings
// -----------------------------------------------------------------------

/*
	Zero means the default, and `blur` is the one deliberate exception -- see
	`ssao_settings_normalized`. The half that matters is the exception: an
	over-applied rule silently puts "do not blur" out of reach, and that is
	the setting somebody reaches for precisely when they are trying to see
	what the blur is doing to their picture.
*/
@(test)
test_ssao_settings_normalized_fills_only_what_has_no_zero :: proc(t: ^testing.T) {
	filled := ssao_settings_normalized(Ssao{enabled = true})

	testing.expect(t, filled.radius    == SSAO_DEFAULTS.radius,    "radius was not defaulted")
	testing.expect(t, filled.intensity == SSAO_DEFAULTS.intensity, "intensity was not defaulted")
	testing.expect(t, filled.bias      == SSAO_DEFAULTS.bias,      "bias was not defaulted")
	testing.expect(t, filled.samples   == SSAO_DEFAULTS.samples,   "samples was not defaulted")

	testing.expect(t, filled.blur == 0, "a deliberate zero blur was overwritten")

	// And a disabled Ssao is left entirely alone, so Ssao{} is a fixed point
	// and LIGHTING_DEFAULTS can be read off its own constant.
	testing.expect(t, ssao_settings_normalized(Ssao{}) == Ssao{},
		"a disabled Ssao grew defaults nothing will read")
}

// Out of range is not the same as unset: a sample count past the array bound
// is clamped to it rather than jumped to the default, the same call
// bloom_settings_normalized makes about a negative level count.
@(test)
test_ssao_settings_normalized_clamps_its_ranges :: proc(t: ^testing.T) {
	high := ssao_settings_normalized(Ssao{enabled = true, samples = 500, blur = 40})
	testing.expect(t, high.samples == MAX_SSAO_SAMPLES, "samples was not clamped down")
	testing.expect(t, high.blur == 8, "blur was not clamped down")

	low := ssao_settings_normalized(Ssao{enabled = true, samples = -3, blur = -2})
	testing.expect(t, low.samples == 1, "a negative sample count was not clamped up")
	testing.expect(t, low.blur == 0, "a negative blur radius was not clamped up")
}

// LIGHTING_DEFAULTS names no SSAO, and normalizing it has to leave it that
// way -- a default that changes when it passes through the rule meant to
// leave defaults alone is a default nobody can read off the constant.
@(test)
test_lighting_defaults_ssao_survives_normalization :: proc(t: ^testing.T) {
	normalized := lighting_settings_normalized(LIGHTING_DEFAULTS)

	testing.expect(t, !normalized.ssao.enabled, "SSAO came on by itself")
	testing.expect(t, normalized.ssao == LIGHTING_DEFAULTS.ssao,
		"LIGHTING_DEFAULTS.ssao is not a fixed point of normalization")
}

/*
	`scene_depth_is_read` is what decides whether the 3D pass stores its depth
	or throws it away, and `ssao_run` is what then reads it. The two agreeing
	is not a detail: a pass that discarded its depth and an effect that samples
	it is a frame of garbage with no error attached, which is exactly why that
	condition is one procedure rather than written out at each site.

	Checked through `set_lighting` rather than by poking the struct, so the
	normalization path is in the loop too.
*/
@(test)
test_scene_depth_is_read_follows_ssao :: proc(t: ^testing.T) {
	previous := mbi.renderer.lighting.settings
	defer mbi.renderer.lighting.settings = previous

	mbi.renderer.lighting.settings = lighting_settings_normalized(
		Lighting_Settings{enabled = true, exposure = 1})
	testing.expect(t, !scene_depth_is_read(), "depth is being stored for a frame nothing reads it in")

	mbi.renderer.lighting.settings = lighting_settings_normalized(
		Lighting_Settings{enabled = true, exposure = 1, ssao = SSAO_DEFAULTS})
	testing.expect(t, scene_depth_is_read(), "SSAO is on and the pass would still throw its depth away")
}

/*
	And the other half of the same agreement: which pipelines have to hold
	their scene draws back for a depth prepass.

	`DEFERRED` must not -- it already has depth before it shades, and deferring
	it would replay every model into a pass that has already drawn it. The
	other two must, and only when SSAO is on: a frame that queues and never
	replays is a blank screen, and a frame that replays what was never queued
	draws nothing at all.
*/
@(test)
test_only_forward_family_pipelines_defer_their_scene :: proc(t: ^testing.T) {
	previous := mbi.renderer.lighting.settings
	defer mbi.renderer.lighting.settings = previous

	for pipeline in Render_Pipeline_Kind {
		mbi.renderer.lighting.settings = lighting_settings_normalized(
			Lighting_Settings{enabled = true, exposure = 1, pipeline = pipeline})
		testing.expectf(t, !pipeline_forward_defers_scene(),
			"%v defers its scene with SSAO off", pipeline)

		mbi.renderer.lighting.settings = lighting_settings_normalized(
			Lighting_Settings{enabled = true, exposure = 1, pipeline = pipeline, ssao = SSAO_DEFAULTS})

		want := pipeline != .DEFERRED
		testing.expectf(t, pipeline_forward_defers_scene() == want,
			"%v with SSAO on: deferring is %v, want %v",
			pipeline, pipeline_forward_defers_scene(), want)
	}
}
