package matchbox

/*
	sRGB decode -- the transfer function this phase relies on the hardware for
	----------------------------------------------------------------------
	Uploading a colour texture as `R8G8B8A8_UNORM_SRGB` (`Texture_Encoding.SRGB`,
	upload.odin) asks the GPU to decode gamma to linear on every sample, in
	hardware, before any shader this package ships ever sees the value -- that
	is the whole point of choosing the format instead of a `pow` in
	`mesh.frag.hlsl`. Which also means there is nothing in this package that
	*performs* the decode, and so nothing to call and check the way
	`tonemap_apply` (tonemap.odin) is checked against its own independent
	numbers. There is no GPU capture tooling in this environment
	(`lighting_rework.md` section 8), so the actual hardware decode cannot be
	run and read back from a test.

	What can be checked, and is checked below, is that this phase's
	understanding of what `R8G8B8A8_UNORM_SRGB` does is the standard sRGB
	transfer function (IEC 61966-2-1) and not, say, a flat gamma 2.2 --
	which is what `tonemap_encode` (tonemap.odin) uses on the *encode* side,
	deliberately, as a simplification it documents. Decode and encode are not
	required to agree: the hardware's decode on the way in is exact, and this
	package's encode on the way out is a chosen approximation. Conflating the
	two would be the wrong lesson to take from this file.

	`reference_srgb_decode` is the piecewise formula transcribed from the
	specification, not from any other file in this package, and every
	expected value below was worked out independently (in Python, printed to
	full precision, the same shape `tonemap_test.odin` already uses) rather
	than by running this function and copying its answer -- copying it would
	only prove the transcription is self-consistent, not that it matches the
	standard.
*/

import "core:math"
import "core:testing"

// The sRGB electro-optical transfer function: an encoded byte in [0, 255] to
// the linear value the hardware decodes it to. Not called by any drawing
// code in this package -- see this file's own top comment for why there is
// nothing here to call.
@(private)
reference_srgb_decode :: proc(byte_value: u8) -> f32 {
	c := f32(byte_value) / 255.0

	// The linear segment near black, where the power curve's derivative
	// would otherwise blow up -- the reason sRGB is piecewise rather than a
	// pure gamma curve in the first place.
	if c <= 0.04045 {
		return c / 12.92
	}

	return math.pow((c + 0.055) / 1.055, 2.4)
}

SRGB_TEST_EPSILON :: f32(1e-5)

@(private)
expect_srgb_decode :: proc(t: ^testing.T, byte_value: u8, want: f32) {
	got := reference_srgb_decode(byte_value)
	testing.expectf(t, math.abs(got - want) < SRGB_TEST_EPSILON,
		"srgb decode of %v: got %.9f, want %.9f", byte_value, got, want)
}

// The two fixed points every transfer function shares -- black and white map
// to themselves under any gamma curve, so agreeing here proves nothing about
// which curve is in use. Included anyway because a decode that gets these
// wrong is broken in a more basic way than the curve's shape.
@(test)
test_srgb_decode_endpoints :: proc(t: ^testing.T) {
	expect_srgb_decode(t, 0, 0.0)
	expect_srgb_decode(t, 255, 1.0)
}

// The values that actually distinguish sRGB's real piecewise curve from a
// flat gamma 2.2 or 2.4 -- worked out independently in Python:
//
//   def srgb_decode(b):
//       c = b / 255.0
//       return c / 12.92 if c <= 0.04045 else ((c + 0.055) / 1.055) ** 2.4
//
//   >>> [srgb_decode(b) for b in (1, 10, 64, 118, 128, 180, 188, 200)]
//   [0.0003035269835488375, 0.003035269835488375, 0.05126945837404324,
//    0.18116424424986022, 0.21586050011389926, 0.45641102318040466,
//    0.5028864580325687, 0.5775804404296506]
@(test)
test_srgb_decode_linear_segment :: proc(t: ^testing.T) {
	// Below the 0.04045 threshold in normalized terms (byte 10 -> c =
	// 0.0392), so this exercises the c / 12.92 branch rather than the power
	// curve -- the two disagree by nearly 2x at this end, so a decode that
	// used the power formula everywhere would fail this one specifically.
	expect_srgb_decode(t, 1,  0.0003035269835488375)
	expect_srgb_decode(t, 10, 0.003035269835488375)
}

@(test)
test_srgb_decode_power_segment :: proc(t: ^testing.T) {
	expect_srgb_decode(t, 64,  0.05126945837404324)
	expect_srgb_decode(t, 118, 0.18116424424986022)
	expect_srgb_decode(t, 180, 0.45641102318040466)
	expect_srgb_decode(t, 200, 0.5775804404296506)
}

// The value worth naming on its own: byte 188 is the nearest 8-bit encoding
// of linear 0.5 under real sRGB (188/255 decodes to ~0.503, closer than 187's
// ~0.498) -- the standard's answer to "what encoded grey looks like 50%
// bright", and a different constant (flat 2.2 puts it at byte 186) from what
// a gamma-2.2 approximation would call the same question.
@(test)
test_srgb_decode_mid_grey :: proc(t: ^testing.T) {
	expect_srgb_decode(t, 188, 0.5028864580325687)
}

/*
	A flat gamma 2.2 -- what `tonemap_encode` uses on the *encode* side, and
	explicitly not what the hardware sRGB decode is -- disagrees with the
	real curve at every byte value, worked out independently alongside the
	values above:

		>>> c = 128 / 255.0
		>>> ((c + 0.055) / 1.055) ** 2.4   # real sRGB decode
		0.21586050011389926
		>>> c ** 2.2                       # flat gamma 2.2
		0.2195197180748679

	The gap is small in absolute terms (peaks under 0.01 across the whole
	byte range, checked separately) -- sRGB and 2.2 are close curves by
	design, which is exactly why a shader that only ever gets it slightly
	wrong is such an easy mistake to ship unnoticed. 0.001 is well above this
	file's own float epsilon and well below the ~0.0037 gap at byte 128, so
	this fails on a curve collapsed to flat 2.2 without also firing on
	floating-point noise.
*/
@(test)
test_srgb_decode_disagrees_with_flat_gamma_2_2 :: proc(t: ^testing.T) {
	byte_value := u8(128)
	srgb  := reference_srgb_decode(byte_value)
	gamma := math.pow(f32(byte_value) / 255.0, 2.2)

	testing.expectf(t, math.abs(srgb - gamma) > 0.001,
		"sRGB decode (%.6f) and flat gamma 2.2 (%.6f) should visibly disagree at byte 128", srgb, gamma)
}
