package matchbox

/*
	Tonemap curves -- the arithmetic
	---------------------------------
	`lighting_rework.md` section 8: a known linear input value should produce
	the expected encoded output for each curve, asserted numerically. There is
	no GPU capture tooling in this environment, so `shaders/tonemap.frag.hlsl`
	itself cannot be rendered and read back -- what is checked here is
	`tonemap_apply` (tonemap.odin), which that shader is written to mirror
	statement for statement (see its own top comment).

	Every expected value below was worked out independently, in Python, from
	the same published formulas (Reinhard's `c / (1 + c)`, Narkowicz's ACES
	fit, Sobotka's AgX inset matrix + log2 encode + polynomial contrast) --
	not by importing or re-deriving from this file -- the same "checked
	against an independent implementation" shape CLAUDE.md asks for and the
	skinning palettes and skybox sampling already used, with Python standing
	in for numpy since none of this needs an array library.

	`NONE` is included deliberately, per section 8: it is the identity plus
	the encode, so comparing its output against REINHARD/ACES/AGX on the same
	input isolates exactly what each curve changes, because all four share
	the same exposure step and the same final gamma.
*/

import "core:math"
import "core:testing"

// Loose enough to absorb the float32-vs-Python-float64 gap through a log2
// and a 6th-order polynomial (AGX's own path) without being loose enough to
// let a wrong curve pass -- the smallest gap between any two curves' outputs
// below is three orders of magnitude larger than this.
TONEMAP_TEST_EPSILON :: f32(1e-4)

@(private)
expect_close3 :: proc(t: ^testing.T, got: [3]f32, want: [3]f32, msg: string) {
	testing.expectf(t, math.abs(got.x - want.x) < TONEMAP_TEST_EPSILON,
		"%s: red %.7f, want %.7f", msg, got.x, want.x)
	testing.expectf(t, math.abs(got.y - want.y) < TONEMAP_TEST_EPSILON,
		"%s: green %.7f, want %.7f", msg, got.y, want.y)
	testing.expectf(t, math.abs(got.z - want.z) < TONEMAP_TEST_EPSILON,
		"%s: blue %.7f, want %.7f", msg, got.z, want.z)
}

// Exposure 1, a colour with one channel over 1 (an HDR value a display
// cannot show directly) and two under it -- the case that actually
// distinguishes a compressing curve (REINHARD/ACES/AGX) from NONE's own
// hard clamp.
@(test)
test_tonemap_none_hdr_input :: proc(t: ^testing.T) {
	got := tonemap_apply({2.0, 0.5, 0.1}, 1.0, .NONE)
	expect_close3(t, got, {1.0, 0.7297400528407231, 0.35111917342151316}, "NONE")
}

@(test)
test_tonemap_reinhard_hdr_input :: proc(t: ^testing.T) {
	got := tonemap_apply({2.0, 0.5, 0.1}, 1.0, .REINHARD)
	expect_close3(t, got, {0.8316843294559617, 0.6069133665239949, 0.3362324990933791}, "REINHARD")
}

@(test)
test_tonemap_aces_hdr_input :: proc(t: ^testing.T) {
	got := tonemap_apply({2.0, 0.5, 0.1}, 1.0, .ACES)
	expect_close3(t, got, {0.9603573483587566, 0.8025151002184169, 0.38978594968059366}, "ACES")
}

@(test)
test_tonemap_agx_hdr_input :: proc(t: ^testing.T) {
	got := tonemap_apply({2.0, 0.5, 0.1}, 1.0, .AGX)
	expect_close3(t, got, {0.9327210090481927, 0.8438179068922669, 0.7468292491105027}, "AGX")
}

// Exposure 2 on a mid-grey (0.5, 0.5, 0.5) -- lands exactly at 1.0 after the
// multiply, which is the one input where every curve below (bar AGX, whose
// matrix step is not colour-neutral) should agree, since c/(1+c) at c=1 is
// 0.5 and the ACES fit at x=1 is close to its own asymptote. Also the case
// that actually exercises `exposure`, separately from the four inputs above
// which all used 1.
@(test)
test_tonemap_none_with_exposure :: proc(t: ^testing.T) {
	got := tonemap_apply({0.5, 0.5, 0.5}, 2.0, .NONE)
	expect_close3(t, got, {1.0, 1.0, 1.0}, "NONE, exposure 2")
}

@(test)
test_tonemap_reinhard_with_exposure :: proc(t: ^testing.T) {
	got := tonemap_apply({0.5, 0.5, 0.5}, 2.0, .REINHARD)
	expect_close3(t, got, {0.7297400528407231, 0.7297400528407231, 0.7297400528407231}, "REINHARD, exposure 2")
}

@(test)
test_tonemap_aces_with_exposure :: proc(t: ^testing.T) {
	got := tonemap_apply({0.5, 0.5, 0.5}, 2.0, .ACES)
	expect_close3(t, got, {0.905492450252642, 0.905492450252642, 0.905492450252642}, "ACES, exposure 2")
}

@(test)
test_tonemap_agx_with_exposure :: proc(t: ^testing.T) {
	got := tonemap_apply({0.5, 0.5, 0.5}, 2.0, .AGX)
	expect_close3(t, got, {0.8967770584528502, 0.8967641993845801, 0.8967634000436447}, "AGX, exposure 2")
}

/*
	The property section 8 actually cares about: NONE and the other three
	curves must differ on an input a curve is meant to compress (something
	over 1 after exposure) -- otherwise "the curve changed" and "the encode
	changed" are not separable claims, which is the whole reason NONE is a
	real curve and not just "tonemap disabled".
*/
@(test)
test_tonemap_curves_actually_differ_on_hdr_input :: proc(t: ^testing.T) {
	none     := tonemap_apply({2.0, 0.5, 0.1}, 1.0, .NONE)
	reinhard := tonemap_apply({2.0, 0.5, 0.1}, 1.0, .REINHARD)
	aces     := tonemap_apply({2.0, 0.5, 0.1}, 1.0, .ACES)
	agx      := tonemap_apply({2.0, 0.5, 0.1}, 1.0, .AGX)

	testing.expect(t, none.x == 1.0, "NONE should hard-clip the over-range channel to 1")
	testing.expect(t, reinhard.x < 1.0, "REINHARD should compress the over-range channel below 1")
	testing.expect(t, aces.x < 1.0, "ACES should compress the over-range channel below 1")
	testing.expect(t, agx.x < 1.0, "AGX should compress the over-range channel below 1")

	testing.expect(t, reinhard.x != aces.x && aces.x != agx.x && reinhard.x != agx.x,
		"the three compressing curves should not coincidentally agree")
}
