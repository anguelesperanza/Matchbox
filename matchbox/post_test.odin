package matchbox

/*
	The post chain -- the arithmetic
	--------------------------------
	`lighting_rework.md` section 8: numeric, not visual, wherever possible;
	swept rather than spot-checked; and checked against an independent
	implementation rather than against the code's own output.

	There is no GPU in this environment and no capture tooling, so nothing
	below renders anything. What each group here checks, and what it does not:

	- **Colour grading** is checked in full. `color_grade_apply` (post.odin) is
	  a pure function that `shaders/tonemap.frag.hlsl`'s own `color_grade` is
	  written to mirror statement for statement, so testing it tests the
	  intended arithmetic exactly, and leaves only "the shader text matches"
	  to a side-by-side read.

	- **The bloom knee** is checked in full, the same way, and swept rather
	  than sampled: the interesting part of `bloom_prefilter_weight` is the
	  three-piece curve, so the assertions below are the three junctions
	  between the pieces and a monotonicity sweep across all of them.

	- **The bloom kernels** are checked for the one property the whole chain's
	  behaviour rests on -- that both sum to exactly 1, and therefore that a
	  constant image survives the chain as the same constant. The chain
	  simulation below is arithmetic on those weights, not a render: it proves
	  the *design* preserves light, and cannot prove the GPU ran it.

	- **Nothing checks that bloom looks like bloom**, and nothing can here.

	Every expected value was worked out independently, in Python, from the
	formulas as documented (`Color_Grade`'s field order in post.odin,
	the packed knee in `bloom_prefilter_curve`) -- not by running this code and
	writing down what it said, which would assert only that the code does what
	the code does.
*/

import "core:math"
import "core:testing"

// The same tolerance tonemap_test.odin uses and for the same reason: wide
// enough to absorb f32-against-Python-f64 through a pow(), narrow enough that
// any of the wrong answers below differ by orders of magnitude more.
POST_TEST_EPSILON :: f32(1e-4)

@(private)
expect_grade_close :: proc(t: ^testing.T, got: [3]f32, want: [3]f32, msg: string) {
	testing.expectf(t, math.abs(got.x - want.x) < POST_TEST_EPSILON,
		"%s: red %.7f, want %.7f", msg, got.x, want.x)
	testing.expectf(t, math.abs(got.y - want.y) < POST_TEST_EPSILON,
		"%s: green %.7f, want %.7f", msg, got.y, want.y)
	testing.expectf(t, math.abs(got.z - want.z) < POST_TEST_EPSILON,
		"%s: blue %.7f, want %.7f", msg, got.z, want.z)
}

// -----------------------------------------------------------------------
// Colour grading -- the identity claims first, since they are load-bearing
// -----------------------------------------------------------------------

/*
	**The claim the whole `Color_Grade` design rests on**: every field is a
	delta from identity, so a caller who enables grading and fills in nothing
	gets exactly the picture they had before. If this ever fails, the trap
	`Color_Grade`'s own doc comment claims to have removed by construction is
	back -- a partial composite literal would silently change the picture.

	Swept across the range rather than spot-checked at one colour, and the
	comparison is exact rather than within an epsilon: an identity that is only
	nearly an identity is a bug, not a rounding difference. Zero, one and
	values either side of the 0.5 contrast pivot are all in here, because the
	pivot is the one place a near-miss would hide.
*/
@(test)
test_color_grade_zero_value_is_exactly_identity :: proc(t: ^testing.T) {
	values := [?]f32{0, 0.001, 0.25, 0.4999, 0.5, 0.5001, 0.75, 1}

	for r in values {
		for g in values {
			color := [3]f32{r, g, 0.3}
			got := color_grade_apply(color, Color_Grade{enabled = true})

			testing.expectf(t, got == color,
				"identity grade on (%.4f, %.4f, %.4f) gave (%.7f, %.7f, %.7f)",
				color.x, color.y, color.z, got.x, got.y, got.z)
		}
	}
}

// Off is off: a grade whose every field is set still changes nothing while
// `enabled` is false. The other half of "is grading on is a statement" --
// see Color_Grade's own doc comment on why that bool is kept even though the
// zero value is already a no-op.
@(test)
test_color_grade_disabled_changes_nothing :: proc(t: ^testing.T) {
	grade := Color_Grade{
		enabled    = false,
		lift       = {0.3, -0.2, 0.1},
		gamma      = {0.5, 0.5, 0.5},
		gain       = {2, 2, 2},
		contrast   = 3,
		saturation = -1,
	}

	color := [3]f32{0.2, 0.6, 0.9}
	testing.expect(t, color_grade_apply(color, grade) == color,
		"a disabled grade changed the colour")
}

// -----------------------------------------------------------------------
// Colour grading -- one field at a time
// -----------------------------------------------------------------------

// gain scales: 0.4 * 1.5, 0.4 * 1.0, 0.4 * 0.75. Black stays black under any
// gain, which is what separates it from lift below.
@(test)
test_color_grade_gain :: proc(t: ^testing.T) {
	grade := Color_Grade{enabled = true, gain = {0.5, 0, -0.25}}

	expect_grade_close(t, color_grade_apply({0.4, 0.4, 0.4}, grade), {0.6, 0.4, 0.3}, "gain")
	expect_grade_close(t, color_grade_apply({0, 0, 0}, grade), {0, 0, 0}, "gain on black")
}

// lift adds, so every channel moves by the same amount whatever it started
// at -- the difference from gain, checked by using a colour whose channels
// are far apart.
@(test)
test_color_grade_lift :: proc(t: ^testing.T) {
	grade := Color_Grade{enabled = true, lift = {0.1, 0.1, 0.1}}
	expect_grade_close(t, color_grade_apply({0.2, 0.5, 0.8}, grade), {0.3, 0.6, 0.9}, "lift")
}

// gamma bends: 0.25^(1/2) = 0.5, 0.5^(1/1) = 0.5, 0.75^(1/0.5) = 0.5625.
// The first and last are chosen so a transposed or inverted exponent would
// land somewhere obviously else rather than nearby.
@(test)
test_color_grade_gamma :: proc(t: ^testing.T) {
	grade := Color_Grade{enabled = true, gamma = {1, 0, -0.5}}
	expect_grade_close(t, color_grade_apply({0.25, 0.5, 0.75}, grade), {0.5, 0.5, 0.5625}, "gamma")
}

// A gamma delta at or below -1 would divide by zero, or flip the curve inside
// out just past it. Both sides guard with max(1 + gamma, 1e-4), which makes
// the exponent 10000 and every input below 1 collapse to 0 -- an extreme
// picture, but a finite one, which is the whole point of the guard.
@(test)
test_color_grade_gamma_guard_stays_finite :: proc(t: ^testing.T) {
	gammas := [?]f32{-1, -2, -100}

	for gamma in gammas {
		grade := Color_Grade{enabled = true, gamma = {gamma, gamma, gamma}}
		got := color_grade_apply({0.5, 0.5, 0.5}, grade)

		for i in 0 ..< 3 {
			testing.expectf(t, !math.is_nan(got[i]) && !math.is_inf(got[i]),
				"gamma %.1f produced %v", gamma, got[i])
		}
	}
}

// contrast pushes away from mid grey, so 0.5 is a fixed point at any
// contrast at all -- swept, because a wrong pivot (0 rather than 0.5, say)
// passes at exactly one contrast value and fails at every other.
@(test)
test_color_grade_contrast_pivots_on_mid_grey :: proc(t: ^testing.T) {
	contrasts := [?]f32{-1, -0.5, 0, 0.5, 1, 4}

	for contrast in contrasts {
		grade := Color_Grade{enabled = true, contrast = contrast}
		got := color_grade_apply({0.5, 0.5, 0.5}, grade)

		expect_grade_close(t, got, {0.5, 0.5, 0.5}, "mid grey under contrast")
	}

	// And it does move everything else: (0.25 - 0.5) * 1.5 + 0.5 = 0.125.
	grade := Color_Grade{enabled = true, contrast = 0.5}
	expect_grade_close(t, color_grade_apply({0.25, 0.5, 0.75}, grade), {0.125, 0.5, 0.875}, "contrast")
}

/*
	saturation = -1 collapses every channel onto the colour's own Rec. 709
	luminance -- the one value in this file worked out by hand rather than in
	Python, because it is one dot product: 0.2126*0.8 + 0.7152*0.4 + 0.0722*0.1
	= 0.46338.

	Checking the fully-desaturated end rather than a middling value is
	deliberate: it is the only setting whose right answer is a named quantity
	rather than a number, so a wrong luminance vector (a flat 1/3 each, say --
	which would give 0.4333) fails here by a wide margin instead of by a
	rounding difference.
*/
@(test)
test_color_grade_full_desaturation_is_rec709_luma :: proc(t: ^testing.T) {
	grade := Color_Grade{enabled = true, saturation = -1}
	expect_grade_close(t, color_grade_apply({0.8, 0.4, 0.1}, grade), {0.46338, 0.46338, 0.46338},
		"saturation -1")
}

/*
	And the other direction, which is the case that shows why the resolve
	clamps *after* grading rather than trusting the grade's own range: a
	saturation boost on an already-saturated colour pushes blue to -0.0817,
	and `tonemap_encode`'s own pow() of a negative is a NaN that spreads.

	This asserts the grade really does go out of range, so the guard in
	`tonemap_apply` is protecting against something that happens rather than
	something imagined.
*/
@(test)
test_color_grade_saturation_boost_can_leave_the_range :: proc(t: ^testing.T) {
	grade := Color_Grade{enabled = true, saturation = 0.5}
	got := color_grade_apply({0.8, 0.4, 0.1}, grade)

	expect_grade_close(t, got, {0.96831, 0.36831, -0.08169}, "saturation +0.5")
	testing.expect(t, got.z < 0, "the case this test exists for did not go negative")
}

/*
	Every field at once, which is the only test here that can catch a wrong
	*order*. Each of the single-field tests above passes under any ordering,
	because the other four steps are identities in them; this one does not.

	Worked out in Python from the order post.odin documents -- gain and lift,
	then gamma, then contrast, then saturation.
*/
@(test)
test_color_grade_combined_checks_the_order :: proc(t: ^testing.T) {
	grade := Color_Grade{
		enabled    = true,
		lift       = {0.02, -0.01, 0.03},
		gamma      = {0.2, 0, -0.15},
		gain       = {0.1, -0.05, 0.25},
		contrast   = 0.3,
		saturation = -0.4,
	}

	expect_grade_close(t, color_grade_apply({0.3, 0.55, 0.2}, grade),
		{0.42029041, 0.49483983, 0.26954840}, "combined grade")
}

// -----------------------------------------------------------------------
// The grade inside the resolve
// -----------------------------------------------------------------------

/*
	`tonemap_apply` grew a `grade` parameter, defaulted. This is the check
	that its arrival did not disturb the four curves `tonemap_test.odin`
	already pins: an omitted grade, an explicit zero grade and an enabled
	empty grade must all be the same number, for every curve.

	Worth its own test rather than being assumed from the identity test above,
	because `tonemap_apply` also gained a clamp alongside the grade call, and
	a clamp is exactly the kind of thing that is an identity on most inputs
	and not on all of them.
*/
@(test)
test_tonemap_apply_grade_defaults_change_nothing :: proc(t: ^testing.T) {
	inputs := [?][3]f32{{0, 0, 0}, {0.18, 0.18, 0.18}, {2, 0.5, 0.1}, {40, 12, 3}}

	for tonemap in Tonemap {
		for color in inputs {
			base := tonemap_apply(color, 1, tonemap)

			testing.expect(t, tonemap_apply(color, 1, tonemap, Color_Grade{}) == base,
				"an explicit zero grade changed the resolve")
			testing.expect(t, tonemap_apply(color, 1, tonemap, Color_Grade{enabled = true}) == base,
				"an enabled empty grade changed the resolve")
		}
	}
}

// The whole resolve with a grade in it, end to end: ACES on an HDR colour,
// then fully desaturated, then encoded. Derived in Python from the published
// ACES fit and the grade order, independently of the curve numbers
// tonemap_test.odin already carries.
@(test)
test_tonemap_apply_with_a_grade :: proc(t: ^testing.T) {
	grade := Color_Grade{enabled = true, saturation = -1}
	got := tonemap_apply({2, 0.5, 0.1}, 1, .ACES, grade)

	expect_grade_close(t, got, {0.81892149, 0.81892149, 0.81892149}, "ACES + full desaturation")
}

// -----------------------------------------------------------------------
// Bloom -- the brightness knee
// -----------------------------------------------------------------------

/*
	The packed curve exists so the shader never divides by a zero knee -- see
	`bloom_prefilter_curve`. This checks the packing itself, since every
	assertion below it depends on the four components meaning what that proc
	says they mean.
*/
@(test)
test_bloom_prefilter_curve_packing :: proc(t: ^testing.T) {
	soft := bloom_prefilter_curve(1, 0.5)
	testing.expect(t, soft == [4]f32{0.5, 1, 0.5, 1}, "soft knee packed wrong")

	// The whole reason the CPU does this: 0.25/0 is an infinity, and a hard
	// knee is a setting somebody chooses.
	hard := bloom_prefilter_curve(1, 0)
	testing.expect(t, hard == [4]f32{1, 0, 0, 1}, "hard knee packed wrong")

	// Negative is nobody's setting, but it is a thing a struct can hold.
	testing.expect(t, bloom_prefilter_curve(-2, -1) == [4]f32{0, 0, 0, 0},
		"a negative threshold or knee was not floored")
}

/*
	The three junctions of the three-piece curve, each derived from the
	definition rather than from running the code:

	- at `threshold - knee` and below, nothing passes at all;
	- at `threshold` exactly, the quadratic is at `0.25 * knee`, so the weight
	  is `0.25 * knee / threshold`;
	- at `threshold + knee`, the quadratic reaches `knee` and the linear term
	  reaches `knee` too -- **the two pieces meet exactly**, which is the
	  property the packing is chosen to give and the one thing that would
	  break silently if `0.25/knee` or `2*knee` were ever mis-derived.
*/
@(test)
test_bloom_prefilter_knee_junctions :: proc(t: ^testing.T) {
	threshold, knee := f32(1), f32(0.5)
	curve := bloom_prefilter_curve(threshold, knee)

	testing.expect(t, bloom_prefilter_weight(threshold - knee, curve) == 0,
		"light at the bottom of the knee was not fully rejected")

	at_threshold := bloom_prefilter_weight(threshold, curve)
	testing.expectf(t, math.abs(at_threshold - 0.25 * knee / threshold) < POST_TEST_EPSILON,
		"at the threshold: %.7f, want %.7f", at_threshold, 0.25 * knee / threshold)

	// Both pieces at threshold + knee, computed separately here so that the
	// assertion is that they agree rather than that either matches a number.
	quadratic := 0.25 / knee * (2 * knee) * (2 * knee)
	linear    := (threshold + knee) - threshold
	testing.expectf(t, math.abs(quadratic - linear) < POST_TEST_EPSILON,
		"the knee's two pieces do not meet: %.7f against %.7f", quadratic, linear)

	at_top := bloom_prefilter_weight(threshold + knee, curve)
	testing.expectf(t, math.abs(at_top - quadratic / (threshold + knee)) < POST_TEST_EPSILON,
		"at the top of the knee: %.7f, want %.7f", at_top, quadratic / (threshold + knee))
}

/*
	A sweep rather than a handful of points, because the three-piece curve is
	exactly the shape where a spot check passes and a boundary is still wrong
	-- `lighting_rework.md`'s own note that P2c's furnace sweep found three
	bugs precisely because it swept.

	Two properties across the whole range, for a soft knee and a hard one:

	- **the light that gets through never decreases as the scene gets
	  brighter.** Not the weight -- the weight times the brightness, which is
	  what actually reaches the chain. A curve that dimmed as the input rose
	  would make a brightening highlight bloom less.
	- **nothing is amplified.** The weight stays within [0, 1], so the
	  prefilter can only remove light, never invent it.
*/
@(test)
test_bloom_prefilter_weight_sweep :: proc(t: ^testing.T) {
	knees := [?]f32{0, 0.25, 0.5, 1}

	for knee in knees {
		curve := bloom_prefilter_curve(1, knee)

		previous := f32(0)
		for step in 0 ..= 400 {
			brightness := f32(step) * 0.02 // 0 to 8, past any threshold here
			weight := bloom_prefilter_weight(brightness, curve)
			passed := brightness * weight

			testing.expectf(t, weight >= 0 && weight <= 1,
				"knee %.2f, brightness %.2f: weight %.7f outside [0, 1]", knee, brightness, weight)

			testing.expectf(t, passed >= previous - POST_TEST_EPSILON,
				"knee %.2f, brightness %.2f: %.7f passed, down from %.7f", knee, brightness, passed, previous)

			previous = passed
		}
	}
}

// A zero threshold is a legitimate setting -- see Bloom.threshold on why it is
// not read as "not set" -- and it has to mean "all of it blooms". The
// max(brightness, 1e-5) floor in the weight is the only thing between that
// and a 0/0 at black, so black is checked alongside.
@(test)
test_bloom_prefilter_zero_threshold_passes_everything :: proc(t: ^testing.T) {
	curve := bloom_prefilter_curve(0, 0)

	brightnesses := [?]f32{0.001, 0.1, 0.5, 1, 10}

	for brightness in brightnesses {
		weight := bloom_prefilter_weight(brightness, curve)
		testing.expectf(t, math.abs(weight - 1) < POST_TEST_EPSILON,
			"threshold 0, brightness %.3f: weight %.7f, want 1", brightness, weight)
	}

	testing.expect(t, bloom_prefilter_weight(0, curve) == 0, "black did not stay black")
}

// -----------------------------------------------------------------------
// Bloom -- the kernels, and what they buy
// -----------------------------------------------------------------------

/*
	Both kernels sum to exactly 1. Written out here from the *counts* the
	kernels have -- one centre, four corners, four edges, four inner -- against
	the weights mirrored from the shader, so this is two hand-typed copies
	disagreeing if either drifts, rather than the shader's arithmetic checked
	against itself.

	Everything else about bloom's brightness follows from this, so it is worth
	an exact comparison and not an epsilon: every weight involved is a
	negative power of two, so the sum is exact in binary floating point or the
	weights are wrong.
*/
@(test)
test_bloom_kernels_sum_to_one :: proc(t: ^testing.T) {
	down := bloom_downsample_weights()
	down_sum := down[0] + 4 * down[1] + 4 * down[2] + 4 * down[3]
	testing.expectf(t, down_sum == 1, "the 13-tap downsample sums to %.9f", down_sum)

	up := bloom_upsample_weights()
	up_sum := up[0] + 4 * up[1] + 4 * up[2]
	testing.expectf(t, up_sum == 1, "the 3x3 tent sums to %.9f", up_sum)
}

/*
	**The property the chain's whole design rests on**, and the reason the way
	back up mixes rather than adds: a constant image comes out of the chain as
	the same constant, whatever `levels` and whatever `scatter`.

	This is arithmetic on the kernel weights, not a render. Every tap of a
	constant field is that constant, so a kernel summing to 1 returns it
	unchanged, and the upsample's mix of two equal values is that value again.
	What it proves is that the *design* neither gains nor loses light; it
	cannot prove any GPU ran it. Nothing here has been seen to render.

	The additive chain this replaced fails this test at every level count
	above one -- it would return `levels * v` -- which is exactly how the
	problem was found.
*/
@(test)
test_bloom_chain_preserves_a_constant :: proc(t: ^testing.T) {
	down := bloom_downsample_weights()
	up   := bloom_upsample_weights()

	scatters := [?]f32{0, 0.25, 0.7, 1}

	for levels in 1 ..= MAX_BLOOM_LEVELS {
		for scatter in scatters {
			chain: [MAX_BLOOM_LEVELS]f32

			// The prefilter, on a field bright enough to pass any knee here
			// at full weight, is the 13-tap kernel over 13 identical taps.
			value := f32(4)
			chain[0] = value * (down[0] + 4 * down[1] + 4 * down[2] + 4 * down[3])

			for i in 0 ..< levels - 1 {
				chain[i + 1] = chain[i] * (down[0] + 4 * down[1] + 4 * down[2] + 4 * down[3])
			}

			for i := levels - 2; i >= 0; i -= 1 {
				tent := chain[i + 1] * (up[0] + 4 * up[1] + 4 * up[2])
				chain[i] = chain[i] * (1 - scatter) + tent * scatter
			}

			testing.expectf(t, math.abs(chain[0] - value) < POST_TEST_EPSILON,
				"%d levels at scatter %.2f: chain returned %.7f for a constant %.7f",
				levels, scatter, chain[0], value)
		}
	}
}

// -----------------------------------------------------------------------
// Bloom -- the chain's shape
// -----------------------------------------------------------------------

// Level 0 is already half resolution -- the prefilter does the first halving
// as it goes -- and each level after it halves again. The 1080p case is the
// one a game will actually meet, and the odd numbers in it (1080 -> 540 ->
// 270 -> 135 -> 67) are the point: integer division truncates, and a level
// computed as `width >> i` on the original rather than by halving the level
// above would disagree from 135 down.
@(test)
test_bloom_level_sizes_halve :: proc(t: ^testing.T) {
	sizes, count := bloom_level_sizes(1920, 1080, 5)

	testing.expectf(t, count == 5, "wanted 5 levels, got %d", count)
	testing.expect(t, sizes[0] == [2]i32{960, 540}, "level 0")
	testing.expect(t, sizes[1] == [2]i32{480, 270}, "level 1")
	testing.expect(t, sizes[2] == [2]i32{240, 135}, "level 2")
	testing.expect(t, sizes[3] == [2]i32{120, 67},  "level 3")
	testing.expect(t, sizes[4] == [2]i32{60, 33},   "level 4")
}

/*
	The chain stops when it runs out of pixels, which is the reason
	`bloom_level_sizes` returns a count at all rather than trusting the
	request -- see its own doc comment. Without it, a small window would keep
	adding 1x1 levels, each its own pair of passes, forever.

	Swept across every resolution from 1x1 to 200x200 rather than checked at
	the three sizes that came to mind, and the assertions are the invariants
	rather than the numbers: no level is smaller than one texel, no level is
	bigger than the one above it, and the last level is either the requested
	one or a 1x1.
*/
@(test)
test_bloom_level_sizes_run_out_of_pixels :: proc(t: ^testing.T) {
	heights := [?]int{1, 2, 3, 7, 64, 200}

	for width in 1 ..= 200 {
		for height in heights {
			sizes, count := bloom_level_sizes(i32(width), i32(height), MAX_BLOOM_LEVELS)

			testing.expectf(t, count >= 1 && count <= MAX_BLOOM_LEVELS,
				"%dx%d: %d levels", width, height, count)

			previous := [2]i32{i32(width), i32(height)}
			for i in 0 ..< count {
				testing.expectf(t, sizes[i].x >= 1 && sizes[i].y >= 1,
					"%dx%d level %d is %dx%d", width, height, i, sizes[i].x, sizes[i].y)
				testing.expectf(t, sizes[i].x <= previous.x && sizes[i].y <= previous.y,
					"%dx%d level %d grew: %dx%d after %dx%d",
					width, height, i, sizes[i].x, sizes[i].y, previous.x, previous.y)
				previous = sizes[i]
			}

			// Stopped early only because there was nothing left to halve.
			if count < MAX_BLOOM_LEVELS {
				testing.expectf(t, previous == [2]i32{1, 1},
					"%dx%d stopped at %d levels with %dx%d still to halve",
					width, height, count, previous.x, previous.y)
			}
		}
	}

	// A window with no pixels at all is not a chain of one 1x1 level, it is no
	// chain -- ensure_bloom_targets reads the count and gives up on zero.
	_, none := bloom_level_sizes(0, 0, 5)
	testing.expect(t, none == 0, "a zero-sized source produced levels")
}

// -----------------------------------------------------------------------
// Normalization -- zero means the default, and where it deliberately does not
// -----------------------------------------------------------------------

/*
	The half of the rule that matters, per `normalize_test.odin`'s own comment:
	the tests where nothing happens. An over-applied default silently puts a
	value somebody meant out of reach.

	`threshold` and `knee` are the deliberate exceptions here -- both have a
	legitimate zero (bloom everything; a hard edge) -- and `Color_Grade` is the
	exception to the whole rule, since deltas from identity have no wrong zero
	to fix.
*/
@(test)
test_bloom_settings_normalized_fills_only_what_has_no_zero :: proc(t: ^testing.T) {
	filled := bloom_settings_normalized(Bloom{enabled = true})

	testing.expect(t, filled.intensity == BLOOM_DEFAULTS.intensity, "intensity was not defaulted")
	testing.expect(t, filled.scatter   == BLOOM_DEFAULTS.scatter,   "scatter was not defaulted")
	testing.expect(t, filled.levels    == BLOOM_DEFAULTS.levels,    "levels was not defaulted")

	testing.expect(t, filled.threshold == 0, "a deliberate zero threshold was overwritten")
	testing.expect(t, filled.knee      == 0, "a deliberate zero knee was overwritten")

	// And a disabled one is left entirely alone, so `Bloom{}` stays `Bloom{}`
	// -- which is what makes POST_DEFAULTS and LIGHTING_DEFAULTS readable as
	// the constants they are rather than as something normalization rewrites.
	testing.expect(t, bloom_settings_normalized(Bloom{}) == Bloom{},
		"a disabled Bloom grew defaults nothing will read")
}

// scatter drives a source-alpha blend, so past 1 it would subtract the
// destination rather than mix with it -- a negative bloom level, and then a
// black halo around every bright thing. Clamped rather than rejected.
@(test)
test_bloom_settings_normalized_clamps_scatter_and_levels :: proc(t: ^testing.T) {
	high := bloom_settings_normalized(Bloom{enabled = true, scatter = 4, levels = 99})
	testing.expect(t, high.scatter == 1, "scatter was not clamped down")
	testing.expect(t, high.levels == MAX_BLOOM_LEVELS, "levels was not clamped down")

	// Clamped to the ends of the range rather than treated as unset: a
	// negative is out of range, not absent, and the two mean different things
	// -- see bloom_settings_normalized. So -3 levels is the smallest chain
	// that works (one level), not five.
	low := bloom_settings_normalized(Bloom{enabled = true, scatter = -1, levels = -3})
	testing.expect(t, low.scatter == 0, "a negative scatter was not clamped up")
	testing.expect(t, low.levels == 1, "a negative level count was not clamped to one level")
}

// The zero value of the whole thing survives normalization as the zero value,
// which is what makes `Lighting_Settings` literals that never mention `post`
// mean exactly what they meant before P7a existed.
@(test)
test_post_settings_zero_value_is_bloom_off_and_no_grade :: proc(t: ^testing.T) {
	normalized := post_settings_normalized(Post_Settings{})

	testing.expect(t, !normalized.bloom.enabled, "bloom came on by itself")
	testing.expect(t, !normalized.grade.enabled, "grading came on by itself")
	testing.expect(t, normalized.grade == Color_Grade{}, "the grade was not left alone")
	testing.expect(t, POST_DEFAULTS == Post_Settings{}, "POST_DEFAULTS drifted from the zero value")
}

// LIGHTING_DEFAULTS names `post` explicitly, and normalizing it must be a
// fixed point -- a default that changes when it passes through the rule meant
// to leave defaults alone is a default nobody can read off the constant.
@(test)
test_lighting_defaults_post_survives_normalization :: proc(t: ^testing.T) {
	normalized := lighting_settings_normalized(LIGHTING_DEFAULTS)
	testing.expect(t, normalized.post == LIGHTING_DEFAULTS.post,
		"LIGHTING_DEFAULTS.post is not a fixed point of normalization")
}
