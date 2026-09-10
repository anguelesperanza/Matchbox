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
	there is none; a kernel whose taps all lie on one spiral turns the
	per-pixel rotation into a visible pattern; a kernel longer than the unit
	hemisphere samples outside the radius the settings asked for. Each of
	those is a wrong picture with no error attached, and each is decidable
	here -- the middle one only after P7c went looking for it, having shipped
	it.

	The expected values were worked out in Python from the definitions in
	`ssao_kernel`'s own doc comment, and the van der Corput terms are written
	out here as a table rather than recomputed, so the check is against the
	sequence's own definition rather than against a second copy of the code.

	**One of these tests used to assert the bug.** Until P7c
	`test_ssao_kernel_lengths_grow_toward_the_rim` required a tap's distance
	from the origin to rise monotonically with its index -- which, since the
	index also drives the azimuth, is precisely the statement "the kernel is a
	spiral". It passed for two phases and pinned a defect in place. What
	replaced it is below: the *distribution* of lengths is still required to
	lean toward the origin, and the azimuth and the radius are required to be
	independent, which is the property that actually matters and the one the
	old test ruled out.

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
	The van der Corput sequence's first terms in both bases the kernel uses,
	which are a closed-form thing rather than a measurement: index `i`'s digits
	in the base, reflected about the point. In base 2, 1 is 0.5, 2 is 0.25, 3
	is 0.75; in base 3, 1 is 1/3 and 2 is 2/3.

	Written out rather than recomputed, because the point is to catch the
	digit loop being subtly wrong -- an off-by-one in the fraction's starting
	value still produces a plausible spread of numbers in [0, 1), which is
	exactly the kind of wrong a "looks distributed" check would pass.
*/
@(test)
test_radical_inverse_first_terms :: proc(t: ^testing.T) {
	base2 := [8]f32{0, 0.5, 0.25, 0.75, 0.125, 0.625, 0.375, 0.875}

	for want, i in base2 {
		got := radical_inverse(u32(i), 2)
		testing.expectf(t, math.abs(got - want) < SSAO_TEST_EPSILON,
			"radical_inverse(%d, 2) = %.9f, want %.9f", i, got, want)
	}

	third  := f32(1) / 3
	base3  := [7]f32{0, third, 2 * third, third / 3, third + third / 3, 2 * third + third / 3, 2 * third / 3}

	for want, i in base3 {
		got := radical_inverse(u32(i), 3)
		testing.expectf(t, math.abs(got - want) < 1e-5,
			"radical_inverse(%d, 3) = %.9f, want %.9f", i, got, want)
	}
}

// Never leaves [0, 1) in either base, which is what the caller relies on to
// feed it into a square root. Swept over the whole range the kernel can ask
// for rather than the terms above, since a digit loop that goes wrong tends
// to go wrong at magnitudes the first few indices never reach.
@(test)
test_radical_inverse_stays_in_unit_range :: proc(t: ^testing.T) {
	bases := [?]u32{2, 3}

	for base in bases {
		for i in 0 ..< 4096 {
			v := radical_inverse(u32(i), base)
			testing.expectf(t, v >= 0 && v < 1, "radical_inverse(%d, %d) = %.9f", i, base, v)
		}
	}

	// A base with no digits to reflect would not terminate, so it is refused
	// rather than looped on.
	testing.expect(t, radical_inverse(7, 1) == 0, "base 1 was not refused")
	testing.expect(t, radical_inverse(7, 0) == 0, "base 0 was not refused")
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

@(private)
ssao_test_length :: proc(v: [4]f32) -> f32 {
	return math.sqrt(v.x * v.x + v.y * v.y + v.z * v.z)
}

// A tap's angle around the normal, which is what the per-pixel rotation turns.
@(private)
ssao_test_azimuth :: proc(v: [4]f32) -> f32 {
	return math.atan2(v.y, v.x)
}

/*
	**A tap's angle around the normal and its distance from it must be
	independent, and this is the test P7c had to add because the shape it
	replaced asserted the opposite.**

	Every pixel rotates the whole tap set by its own angle before sampling. If
	angle and radius rise together the set is a rigid spiral, so the occlusion
	a pixel measures becomes a strong smooth function of that rotation -- and
	whatever structure the rotation has (interleaved gradient noise has a great
	deal: a fine diagonal weave) prints straight through into the picture. That
	is what the first render of SSAO looked like.

	Measured as a Pearson correlation between the two, which was **0.965** for
	the kernel this replaced and is under 0.35 for every count now. The
	threshold is loose on purpose: what matters is that the two are not locked
	together, not that they reach any particular small number, and a low-
	discrepancy sequence is not a random one -- some correlation at small
	counts is expected and harmless.
*/
@(test)
test_ssao_kernel_azimuth_and_radius_are_independent :: proc(t: ^testing.T) {
	for count in 8 ..= MAX_SSAO_SAMPLES {
		kernel := ssao_kernel(count)

		mean_azimuth, mean_radius: f32
		for i in 0 ..< count {
			mean_azimuth += ssao_test_azimuth(kernel[i])
			mean_radius  += ssao_test_length(kernel[i])
		}
		mean_azimuth /= f32(count)
		mean_radius  /= f32(count)

		covariance, azimuth_spread, radius_spread: f32
		for i in 0 ..< count {
			da := ssao_test_azimuth(kernel[i]) - mean_azimuth
			dr := ssao_test_length(kernel[i]) - mean_radius

			covariance     += da * dr
			azimuth_spread += da * da
			radius_spread  += dr * dr
		}

		if azimuth_spread <= 0 || radius_spread <= 0 do continue

		correlation := covariance / math.sqrt(azimuth_spread * radius_spread)

		testing.expectf(t, math.abs(correlation) < 0.35,
			"count %d: azimuth and radius correlate at %.4f -- the kernel is a spiral, and the per-pixel rotation will print its own structure into the image",
			count, correlation)
	}
}

/*
	The lengths still lean toward the origin, which is the property the old
	monotone assertion was really there for: a crease is dark because of what
	is a few centimetres away, not because of what is at the edge of the
	radius. Checked as a *distribution* -- the median tap sits in the nearer
	half of the range -- rather than as an ordering, since the ordering is
	exactly what had to go.

	The bounds are checked too: nothing shorter than the 0.1 floor and nothing
	past the unit hemisphere, at every count.
*/
@(test)
test_ssao_kernel_lengths_lean_toward_the_origin :: proc(t: ^testing.T) {
	for count in 8 ..= MAX_SSAO_SAMPLES {
		kernel := ssao_kernel(count)

		nearer := 0
		for i in 0 ..< count {
			length := ssao_test_length(kernel[i])

			testing.expectf(t, length >= 0.1 - SSAO_TEST_EPSILON && length <= 1 + SSAO_TEST_EPSILON,
				"count %d, sample %d has length %.9f, outside [0.1, 1]", count, i, length)

			if length < 0.55 do nearer += 1 // the midpoint of [0.1, 1]
		}

		testing.expectf(t, nearer * 2 > count,
			"count %d: only %d of %d taps sit in the nearer half of the radius, so the sampling is not weighted toward the contact occlusion it exists for",
			count, nearer, count)
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
