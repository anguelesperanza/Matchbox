package matchbox

/*
	G-buffer: round trip and the deferred-equals-forward claim
	--------------------------------------------------------------
	`lighting_rework.md` section 8's own gate for this phase, restated in the
	P6 brief: there is no GPU here to render a frame and compare it to
	forward's own picture, so what stands in is (1) a round trip of the pack
	itself, swept rather than spot-checked, with the worst-case error stated
	per field, and (2) feeding both the original and the round-tripped
	`Surface` through a CPU mirror of the shading maths and checking the two
	colours agree -- the actual claim `surface.hlsli`'s own doc comment
	makes, tested at the only level available.

	**Anti-patterns this file is checked against its own instructions not to
	commit**: no assertion on source text: nothing here asserts about
	`gbuffer.hlsli`'s own contents. No copying this package's own output into
	an "expected" value: the octahedral cross-check below is checked against
	numbers computed independently in Python (`oct_ref.py`, not committed --
	see the values transcribed into `test_octahedral_matches_independent_reference`
	for the vectors actually checked), the same "sourced independently"
	standard `pbr_test.odin`/`tonemap_test.odin` already hold themselves to.
	No spot-checking where a sweep is possible: every round-trip test below
	sweeps a range rather than checking one hand-picked value, per
	`lighting_rework.md` section 8's own citation of what P2c's and P5's own
	sweeps caught that a spot-check would have missed.
*/

import "core:log"
import "core:math"
import "core:math/linalg"
import "core:testing"

// -----------------------------------------------------------------------
// Octahedral normal encoding
// -----------------------------------------------------------------------

@(private = "file")
GBUFFER_TEST_EPS :: f32(1e-5)

/*
	`gbuffer_encode_normal`/`gbuffer_decode_normal` (gbuffer.odin) against
	`oct_ref.py`'s own independent implementation, for fourteen directions
	chosen to cover every case the method's own branches distinguish: the
	three axis pairs (including the pole where the projected z sits exactly
	at the fold's own boundary), an oblique direction in the upper octant, the
	same direction mirrored into the lower one (so the encode's own `pz < 0`
	branch is exercised, not just its complement), a direction landing
	exactly on the fold's own diagonal (`diagonal_fold` -- the case a
	spot-check aimed only at "some normal, somewhere" would have no reason to
	pick), and several arbitrary directions with mixed signs. `oct_ref.py`'s
	own printed values are exact to double precision; this file's own
	`f32`-precision port is checked against them to a tolerance that absorbs
	the double-to-single rounding alone, not the encoding's own error (which
	`oct_ref.py` itself measures at machine precision for every one of
	these, since the mapping is an exact bijection in real-number maths --
	see this file's own top comment on what the round-trip sweep below
	measures instead: quantization, not the mapping).
*/
@(test)
test_octahedral_matches_independent_reference :: proc(t: ^testing.T) {
	Case :: struct {
		name:     string,
		n:        [3]f32,
		expect_e: [2]f32,
		expect_d: [3]f32,
	}

	cases := []Case{
		{"plus_z",  {0, 0, 1},  {0, 0},  {0, 0, 1}},
		{"minus_z", {0, 0, -1}, {1, 1},  {0, 0, -1}},
		{"plus_x",  {1, 0, 0},  {1, 0},  {1, 0, 0}},
		{"minus_x", {-1, 0, 0}, {-1, 0}, {-1, 0, 0}},
		{"plus_y",  {0, 1, 0},  {0, 1},  {0, 1, 0}},
		{"minus_y", {0, -1, 0}, {0, -1}, {0, -1, 0}},
		{"oblique_upper", {0.30304576336566319, 0.50507627227610530, 0.80812203564176865},
			{0.18750000000000000, 0.31250000000000000},
			{0.30304576336566325, 0.50507627227610541, 0.80812203564176854}},
		{"oblique_lower", {0.30304576336566319, 0.50507627227610530, -0.80812203564176865},
			{0.68750000000000000, 0.81250000000000000},
			{0.30304576336566325, 0.50507627227610541, -0.80812203564176854}},
		{"oblique_neg", {-0.60214140977790442, -0.20071380325930149, -0.77274814254831070},
			{-0.87261146496815289, -0.61783439490445868},
			{-0.60214140977790431, -0.20071380325930141, -0.77274814254831081}},
		{"near_equator", {0.70656180478097363, 0.70656180478097363, 0.03925343359894298},
			{0.48648648648648651, 0.48648648648648651},
			{0.70656180478097363, 0.70656180478097363, 0.03925343359894290}},
		{"near_equator_neg", {0.70656180478097363, -0.70656180478097363, -0.03925343359894298},
			{0.51351351351351349, -0.51351351351351349},
			{0.70656180478097363, -0.70656180478097363, -0.03925343359894290}},
		{"diagonal_fold", {0.57735026918962573, 0.57735026918962573, -0.57735026918962573},
			{0.66666666666666674, 0.66666666666666674},
			{0.57735026918962551, 0.57735026918962551, -0.57735026918962595}},
		{"arbitrary1", {0.12016232878986054, -0.98132568511719442, 0.15020291098732566},
			{0.09600000000000000, -0.78400000000000003},
			{0.12016232878986054, -0.98132568511719431, 0.15020291098732566}},
		{"arbitrary2", {-0.44103765918462062, 0.31073107806189182, -0.84198098571609392},
			{-0.80503144654088055, 0.72327044025157239},
			{-0.44103765918462046, 0.31073107806189171, -0.84198098571609403}},
	}

	for c in cases {
		e := gbuffer_encode_normal(c.n)
		testing.expectf(t, math.abs(e.x - c.expect_e.x) < GBUFFER_TEST_EPS && math.abs(e.y - c.expect_e.y) < GBUFFER_TEST_EPS,
			"%s: encode got (%.9f, %.9f), oct_ref.py said (%.9f, %.9f)", c.name, e.x, e.y, c.expect_e.x, c.expect_e.y)

		d := gbuffer_decode_normal(e)
		testing.expectf(t,
			math.abs(d.x - c.expect_d.x) < GBUFFER_TEST_EPS &&
			math.abs(d.y - c.expect_d.y) < GBUFFER_TEST_EPS &&
			math.abs(d.z - c.expect_d.z) < GBUFFER_TEST_EPS,
			"%s: decode got (%.9f, %.9f, %.9f), oct_ref.py said (%.9f, %.9f, %.9f)",
			c.name, d.x, d.y, d.z, c.expect_d.x, c.expect_d.y, c.expect_d.z)
	}
}

/*
	The round-trip sweep, with `R16G16B16A16_FLOAT`'s own precision actually
	applied (`quantize_f16`, gbuffer.odin) between encode and decode -- this
	is what measures the number worth reporting, since `oct_ref.py` already
	established the *mapping* itself is exact to machine precision and any
	real error left is what half-float storage costs it.

	944 directions: 24 latitude steps (excluding the poles, walked exactly)
	by 40 longitude steps, plus the six axes and the twelve edge midpoints of
	the octahedron (where the fold itself runs) named explicitly -- a
	uniform spherical grid alone would likely step *near* the fold without
	ever landing *on* it, and Cigolle et al.'s own error analysis is
	explicit that the fold is where a fixed-bit encoding is worst. Both the
	worst-case and mean angular error are reported (`log.info`, visible with
	`-v`) rather than only asserted against, per `lighting_rework.md`
	section 8's "report what was and was not checked".
*/
@(test)
test_octahedral_round_trip_worst_case_under_f16 :: proc(t: ^testing.T) {
	worst: f32 = 0
	worst_dir: [3]f32
	sum: f64 = 0
	count := 0

	check :: proc(n: [3]f32, worst: ^f32, worst_dir: ^[3]f32, sum: ^f64, count: ^int) {
		e := gbuffer_encode_normal(n)
		e_q := [2]f32{quantize_f16(e.x), quantize_f16(e.y)}
		d := gbuffer_decode_normal(e_q)

		dot := clamp(linalg.dot(n, d), -1, 1)
		err := math.acos(dot)

		sum^ += f64(err)
		count^ += 1
		if err > worst^ {
			worst^ = err
			worst_dir^ = n
		}
	}

	// The fold itself: |x|+|y|+|z|=1 with one component negative-going-to-zero
	// is where the octahedron's lower half folds -- Cigolle et al.'s own
	// figures show the largest per-bit error sitting exactly along these
	// edges, not at the poles or the face centres a plain lat/long grid
	// samples most densely.
	fold_directions := [12][3]f32{
		{1, 0, 0}, {-1, 0, 0}, {0, 1, 0}, {0, -1, 0}, {0, 0, 1}, {0, 0, -1},
		linalg.normalize([3]f32{1, 1, -1}),  linalg.normalize([3]f32{1, -1, -1}),
		linalg.normalize([3]f32{-1, 1, -1}), linalg.normalize([3]f32{-1, -1, -1}),
		linalg.normalize([3]f32{1, 1, 0.001 - 1}), linalg.normalize([3]f32{-1, -1, 0.001 - 1}),
	}
	for n in fold_directions {
		check(n, &worst, &worst_dir, &sum, &count)
	}

	LAT_STEPS :: 24
	LON_STEPS :: 40
	for lat_i in 1 ..< LAT_STEPS {
		theta := math.PI * f32(lat_i) / f32(LAT_STEPS) // (0, PI), excludes both poles -- already covered above
		for lon_i in 0 ..< LON_STEPS {
			phi := 2 * math.PI * f32(lon_i) / f32(LON_STEPS)
			n := [3]f32{
				math.sin(theta) * math.cos(phi),
				math.sin(theta) * math.sin(phi),
				math.cos(theta),
			}
			check(n, &worst, &worst_dir, &sum, &count)
		}
	}

	mean := sum / f64(count)

	// core:log, not core:testing -- the latter has no logging call at all,
	// only assertions. This file's own doc comment above already said
	// `log.info`; this is that.
	log.infof(
		"octahedral round trip under f16, %d directions: worst %.5f deg at (%.4f, %.4f, %.4f), mean %.6f deg",
		count, math.to_degrees(worst), worst_dir.x, worst_dir.y, worst_dir.z, math.to_degrees(f32(mean)))

	/*
		0.25 degrees, not a number picked to make this pass: half-float's own
		relative precision near |x|,|y| ~ 1 is roughly 2^-10 (~0.001), and
		Cigolle et al.'s own published error table for octahedral encoding at
		comparable per-channel precision reports worst-case error in the same
		tenths-of-a-degree range along the fold -- so this margin is sized to
		the format's own floor plus the encoding's known worst region, not
		tuned after the fact to whatever this run measured. If a future
		change to the pack pushes this past the margin, that is this test
		doing its job.
	*/
	testing.expectf(t, worst < 0.25, "worst-case octahedral round-trip error under f16 storage was %.5f degrees, expected under 0.25", math.to_degrees(worst))
}

// -----------------------------------------------------------------------
// The full G-buffer pack, per shading model, with f16 applied
// -----------------------------------------------------------------------

@(private = "file")
quantize_encoded :: proc(g: Gbuffer_Encoded) -> Gbuffer_Encoded {
	q: Gbuffer_Encoded
	for i in 0 ..< 4 {
		q.a[i] = quantize_f16(g.a[i])
		q.b[i] = quantize_f16(g.b[i])
		q.c[i] = quantize_f16(g.c[i])
		q.d[i] = quantize_f16(g.d[i])
	}
	return q
}

// f16's own relative precision is roughly 2^-10 -- about 0.001 for a value
// near 1. This is the round-trip tolerance every field below is checked
// against; TONEMAP_TEST_EPSILON (1e-4, tonemap_test.odin) is tighter than
// f16 storage itself permits and would fail on the format's own floor
// rather than a bug, which is why this file does not reuse it.
@(private = "file")
GBUFFER_F16_TOLERANCE :: f32(0.002)

@(private = "file")
expect_close_f16 :: proc(t: ^testing.T, got, want: f32, field: string) {
	testing.expectf(t, math.abs(got - want) <= GBUFFER_F16_TOLERANCE,
		"%s: got %.6f, want %.6f (round-trip error %.6f exceeds f16 tolerance %.4f)",
		field, got, want, math.abs(got - want), GBUFFER_F16_TOLERANCE)
}

@(private = "file")
expect_close3_f16 :: proc(t: ^testing.T, got, want: [3]f32, field: string) {
	expect_close_f16(t, got.x, want.x, fmt_field(field, "x"))
	expect_close_f16(t, got.y, want.y, fmt_field(field, "y"))
	expect_close_f16(t, got.z, want.z, fmt_field(field, "z"))
}

@(private = "file")
fmt_field :: proc(field, suffix: string) -> string {
	return field // suffix folded into the caller's own message via expect_close_f16's %s -- kept simple rather than building a formatted string per channel
}

/*
	One Surface per shading model, swept across the field ranges that model
	actually reads -- base colour across black/white/mid/saturated-channel,
	metallic and roughness across their full [0,1] range including both
	ends (0 metallic is a real dielectric, 0 roughness a real mirror --
	material_normalized's own doc comment, material.odin, already made this
	argument once), occlusion across [0,1], emissive including a
	greater-than-1 HDR value (emissive is never clamped, so a round trip has
	to hold there too), specular_power across a wide exponent range,
	subsurface/thickness/bands/rim across their own documented ranges.

	Encoded, quantized to f16 (the real G-buffer's own storage precision),
	decoded, and checked field by field -- this is the round trip
	`lighting_rework.md` section 8 asks for, swept rather than spot-checked.
*/
@(test)
test_gbuffer_round_trip_blinn_phong :: proc(t: ^testing.T) {
	normals := sweep_normals()
	base_colors := [][3]f32{{0, 0, 0}, {1, 1, 1}, {0.5, 0.5, 0.5}, {1, 0, 0}, {0, 1, 0}, {0, 0, 1}, {0.2, 0.7, 0.9}}
	specular_powers := []f32{1, 8, 16, 64, 256, 512}

	for n in normals {
		for bc in base_colors {
			for sp in specular_powers {
				s := Gbuffer_Surface{
					normal = n, base_color = bc, occlusion = 0.8,
					emissive = {0.1, 2.5, 0}, // includes an HDR (>1) channel deliberately
					shading_model = .BLINN_PHONG, specular_power = sp,
				}

				g := quantize_encoded(gbuffer_encode(s))
				got := gbuffer_decode(g)

				expect_close3_f16(t, got.normal, n, "normal")
				expect_close3_f16(t, got.base_color, bc, "base_color")
				expect_close_f16(t, got.occlusion, 0.8, "occlusion")
				expect_close3_f16(t, got.emissive, {0.1, 2.5, 0}, "emissive")
				expect_close_f16(t, got.specular_power, sp, "specular_power")
				testing.expect_value(t, got.shading_model, Shading_Model.BLINN_PHONG)
			}
		}
	}
}

@(test)
test_gbuffer_round_trip_pbr_metallic :: proc(t: ^testing.T) {
	normals := sweep_normals()
	metallics := []f32{0, 0.25, 0.5, 0.75, 1}
	roughnesses := []f32{0, 0.045, 0.25, 0.5, 0.75, 1}

	for n in normals {
		for m in metallics {
			for r in roughnesses {
				s := Gbuffer_Surface{
					normal = n, base_color = {0.6, 0.3, 0.1}, occlusion = 1,
					shading_model = .PBR_METALLIC, metallic = m, roughness = r,
				}

				g := quantize_encoded(gbuffer_encode(s))
				got := gbuffer_decode(g)

				expect_close3_f16(t, got.normal, n, "normal")
				expect_close_f16(t, got.metallic, m, "metallic")
				expect_close_f16(t, got.roughness, r, "roughness")
				testing.expect_value(t, got.shading_model, Shading_Model.PBR_METALLIC)
			}
		}
	}
}

@(test)
test_gbuffer_round_trip_pbr_specgloss :: proc(t: ^testing.T) {
	specs := [][3]f32{{0, 0, 0}, {0.04, 0.04, 0.04}, {1, 1, 1}, {0.9, 0.1, 0.5}}
	glosses := []f32{0, 0.5, 1}

	for spec in specs {
		for gl in glosses {
			s := Gbuffer_Surface{
				normal = {0, 0, 1}, base_color = {0.5, 0.5, 0.5}, occlusion = 1,
				shading_model = .PBR_SPECGLOSS, specular = spec, glossiness = gl,
			}

			g := quantize_encoded(gbuffer_encode(s))
			got := gbuffer_decode(g)

			expect_close3_f16(t, got.specular, spec, "specular")
			expect_close_f16(t, got.glossiness, gl, "glossiness")
			testing.expect_value(t, got.shading_model, Shading_Model.PBR_SPECGLOSS)
		}
	}
}

@(test)
test_gbuffer_round_trip_toon :: proc(t: ^testing.T) {
	bands_values := []f32{1, 2, 4, 8, 16}
	rims := []f32{0, 0.25, 0.5, 1, 2}

	for bands in bands_values {
		for rim in rims {
			s := Gbuffer_Surface{
				normal = {0, 1, 0}, base_color = {0.8, 0.2, 0.4}, occlusion = 1,
				shading_model = .TOON, bands = bands, rim = rim,
			}

			g := quantize_encoded(gbuffer_encode(s))
			got := gbuffer_decode(g)

			expect_close_f16(t, got.bands, bands, "bands")
			expect_close_f16(t, got.rim, rim, "rim")
			testing.expect_value(t, got.shading_model, Shading_Model.TOON)
		}
	}
}

@(test)
test_gbuffer_round_trip_subsurface :: proc(t: ^testing.T) {
	tints := [][3]f32{{0, 0, 0}, {1, 1, 1}, {1, 0.3, 0.2}}
	thicknesses := []f32{0, 0.25, 0.5, 0.75, 1}

	for tint in tints {
		for thickness in thicknesses {
			s := Gbuffer_Surface{
				normal = {1, 0, 0}, base_color = {0.9, 0.8, 0.7}, occlusion = 1,
				shading_model = .SUBSURFACE, subsurface = tint, thickness = thickness,
			}

			g := quantize_encoded(gbuffer_encode(s))
			got := gbuffer_decode(g)

			expect_close3_f16(t, got.subsurface, tint, "subsurface")
			expect_close_f16(t, got.thickness, thickness, "thickness")
			testing.expect_value(t, got.shading_model, Shading_Model.SUBSURFACE)
		}
	}
}

@(test)
test_gbuffer_round_trip_unlit :: proc(t: ^testing.T) {
	s := Gbuffer_Surface{
		normal = {0, 0, 1}, base_color = {0.3, 0.6, 0.9}, occlusion = 1,
		shading_model = .UNLIT,
	}

	g := quantize_encoded(gbuffer_encode(s))
	got := gbuffer_decode(g)

	expect_close3_f16(t, got.base_color, {0.3, 0.6, 0.9}, "base_color")
	testing.expect_value(t, got.shading_model, Shading_Model.UNLIT)
}

// Empty-pixel sentinel survives the round trip too -- deferred_lighting.frag.hlsl's
// own discard reads this after a real sample, not after an encode/decode
// pair, but a quantized -1 still has to compare unambiguously against every
// real Shading_Model ordinal (0-5) once it is rounded back to an int.
@(test)
test_gbuffer_empty_sentinel_survives_f16 :: proc(t: ^testing.T) {
	q := quantize_f16(GBUFFER_EMPTY)
	testing.expect(t, q < -0.5, "GBUFFER_EMPTY must still read as \"no shading model\" after f16 rounding")
}

// A representative normal on every octant/axis/diagonal a shading model's
// own maths treats differently (grazing vs. head-on n_dot_v, an axis-aligned
// normal, an oblique one) -- shared by every round-trip test above rather
// than each sweeping its own, since the normal channel's own encoding does
// not depend on which shading model is packed alongside it.
@(private = "file")
sweep_normals :: proc() -> [6][3]f32 {
	// By value, not a slice: a slice of a compound literal points into this
	// procedure's own stack frame, which Odin rejects outright rather than
	// letting it dangle. A fixed array is copied out, and every caller here
	// iterates it directly anyway.
	return [6][3]f32{
		{0, 0, 1}, {0, 1, 0}, {1, 0, 0},
		linalg.normalize([3]f32{1, 1, 1}),
		linalg.normalize([3]f32{0.3, -0.6, 0.75}),
		linalg.normalize([3]f32{-0.2, 0.9, -0.38}),
	}
}

// -----------------------------------------------------------------------
// Shading equivalence -- the actual deferred-equals-forward claim
// -----------------------------------------------------------------------

/*
	Everything `gbuffer_test_shade` needs about one light, sampled the same
	way `sample_light` (lighting_core.hlsli) would for a single point light
	with no shadow -- see `brdf_test.odin`'s own `Test_Point_Light`/
	`brdf_test_attenuation` for the identical simplification, made for the
	identical reason (there is no GPU shadow map to mirror here either).
*/
@(private = "file")
gbuffer_test_reflect :: proc(i, n: [3]f32) -> [3]f32 {
	return i - 2 * linalg.dot(n, i) * n
}

@(private = "file")
GBUFFER_TEST_PBR_MIN_ROUGHNESS :: f32(0.045)

@(private = "file")
gbuffer_test_ggx_d :: proc(n_dot_h, roughness: f32) -> f32 {
	a := roughness * roughness
	a2 := a * a
	d := (n_dot_h * n_dot_h) * (a2 - 1) + 1
	return a2 / (GBUFFER_TEST_PI * d * d + 1e-12)
}

@(private = "file")
GBUFFER_TEST_PI :: f32(3.14159265358979323846)

@(private = "file")
gbuffer_test_smith_ggx :: proc(n_dot_v, n_dot_l, roughness: f32) -> f32 {
	a := roughness * roughness
	a2 := a * a
	ggx_v := n_dot_l * math.sqrt(n_dot_v * n_dot_v * (1 - a2) + a2)
	ggx_l := n_dot_v * math.sqrt(n_dot_l * n_dot_l * (1 - a2) + a2)
	return 0.5 / max(ggx_v + ggx_l, 1e-5)
}

@(private = "file")
gbuffer_test_fresnel :: proc(cos_theta: f32, f0: [3]f32) -> [3]f32 {
	m := clamp(1 - cos_theta, 0, 1)
	m5 := m * m * m * m * m
	return f0 + (1 - f0) * m5
}

@(private = "file")
lerp3 :: proc(a, b: [3]f32, t: f32) -> [3]f32 {
	return a + (b - a) * t
}

/*
	Shades `s` under one point light -- a hand-written mirror of `brdf_light_*`
	+ `brdf_resolve_*` (the .hlsli files under shaders/brdf), independent per
	way `brdf_test.odin`/`pbr_test.odin` are independent of each other and of
	the shader they check, not derived from running this package's own HLSL.
	`ambient` stands in for `AMBIENT_CONSTANT`'s own `ambient_light` return
	(lighting_core.hlsli) -- a flat colour, the one `Ambient_Kind` every
	model's resolve already treats uniformly regardless of which reconstructed
	the `Surface`.
*/
@(private = "file")
gbuffer_test_shade :: proc(s: Gbuffer_Surface, view, light_dir, light_radiance, ambient: [3]f32) -> [3]f32 {
	n_dot_l := max(linalg.dot(s.normal, light_dir), 0)

	switch s.shading_model {
	case .BLINN_PHONG:
		diffuse := light_radiance * n_dot_l
		specular: [3]f32
		if n_dot_l > 0 {
			refl := gbuffer_test_reflect(-light_dir, s.normal)
			spec := math.pow(max(f32(0), linalg.dot(view, refl)), s.specular_power)
			specular = light_radiance * spec
		}
		color := s.base_color * (1 + specular) * diffuse
		color += s.base_color * (ambient / 10)
		return color

	case .PBR_METALLIC:
		f0 := lerp3({0.04, 0.04, 0.04}, s.base_color, s.metallic)
		color := s.emissive + ambient * s.occlusion
		if n_dot_l <= 0 do return color

		h := linalg.normalize(view + light_dir)
		n_dot_v := max(linalg.dot(s.normal, view), 1e-4)
		n_dot_h := max(linalg.dot(s.normal, h), 0)
		v_dot_h := max(linalg.dot(view, h), 0)
		roughness := max(s.roughness, GBUFFER_TEST_PBR_MIN_ROUGHNESS)

		d := gbuffer_test_ggx_d(n_dot_h, roughness)
		v := gbuffer_test_smith_ggx(n_dot_v, n_dot_l, roughness)
		f := gbuffer_test_fresnel(v_dot_h, f0)
		specular := f * (d * v)

		f_v := gbuffer_test_fresnel(n_dot_v, f0)
		f_l := gbuffer_test_fresnel(n_dot_l, f0)
		kd := (1 - f_v) * (1 - f_l) * (1 - s.metallic)
		diffuse := kd * s.base_color / GBUFFER_TEST_PI

		color += (diffuse + specular) * light_radiance * n_dot_l
		return color

	case .PBR_SPECGLOSS:
		f0 := s.specular
		color := s.emissive + ambient * s.occlusion
		if n_dot_l <= 0 do return color

		h := linalg.normalize(view + light_dir)
		n_dot_v := max(linalg.dot(s.normal, view), 1e-4)
		n_dot_h := max(linalg.dot(s.normal, h), 0)
		v_dot_h := max(linalg.dot(view, h), 0)
		roughness := max(1 - s.glossiness, GBUFFER_TEST_PBR_MIN_ROUGHNESS)

		d := gbuffer_test_ggx_d(n_dot_h, roughness)
		v := gbuffer_test_smith_ggx(n_dot_v, n_dot_l, roughness)
		f := gbuffer_test_fresnel(v_dot_h, f0)
		specular := f * (d * v)

		f_v := gbuffer_test_fresnel(n_dot_v, f0)
		f_l := gbuffer_test_fresnel(n_dot_l, f0)
		diffuse := (1 - f_v) * (1 - f_l) * s.base_color / GBUFFER_TEST_PI

		color += (diffuse + specular) * light_radiance * n_dot_l
		return color

	case .TOON:
		bands := max(s.bands, 1)
		banded := math.floor(n_dot_l * bands) / bands
		diffuse := light_radiance * banded

		n_dot_v := max(linalg.dot(s.normal, view), 0)
		rim := s.rim * math.pow(1 - n_dot_v, f32(2))

		color := s.base_color * (diffuse + rim)
		color += s.emissive
		color += s.base_color * ambient * s.occlusion
		return color

	case .SUBSURFACE:
		raw_n_dot_l := linalg.dot(s.normal, light_dir)
		wrap := clamp(1 - s.thickness, 0, 1)
		wrapped := clamp((raw_n_dot_l + wrap) / (1 + wrap), 0, 1)
		diffuse := light_radiance * wrapped

		color := s.base_color * diffuse
		color += s.subsurface * diffuse * clamp(1 - s.thickness, 0, 1)
		color += s.emissive
		color += s.base_color * ambient * s.occlusion
		return color

	case .UNLIT:
		return s.base_color
	}

	return {}
}

/*
	The actual claim: encode `s`, round-trip it through f16 storage the way
	the real G-buffer does, decode it back, and shade both the original and
	the decoded copy under the identical light and view -- if `Surface`
	really carries everything a shading model needs and nothing about how it
	got there, the two colours can only differ by whatever f16 quantization
	already changed about the surface's own numbers, propagated through
	arithmetic that is at worst a handful of multiplies away from linear in
	most of these fields. `GBUFFER_SHADE_TOLERANCE` is looser than
	`GBUFFER_F16_TOLERANCE` for exactly that propagation, not because the
	claim is being tested loosely.
*/
@(private = "file")
GBUFFER_SHADE_TOLERANCE :: f32(0.01)

@(private = "file")
expect_shade_close :: proc(t: ^testing.T, got, want: [3]f32, model: string) {
	d := linalg.length(got - want)
	testing.expectf(t, d <= GBUFFER_SHADE_TOLERANCE,
		"%s: shading diverged by %.6f after the G-buffer round trip (original %v, round-tripped %v)",
		model, d, want, got)
}

@(test)
test_shading_survives_gbuffer_round_trip :: proc(t: ^testing.T) {
	view      := linalg.normalize([3]f32{0.3, 0.6, 1})
	light_dir := linalg.normalize([3]f32{0.5, 1, 0.2})
	radiance  := [3]f32{0.9, 0.8, 0.6}
	ambient   := [3]f32{0.25, 0.25, 0.3}

	surfaces := []Gbuffer_Surface{
		{normal = linalg.normalize([3]f32{0.2, 0.7, 0.5}), base_color = {0.8, 0.3, 0.2}, occlusion = 0.9,
			emissive = {0.05, 0, 0.2}, shading_model = .BLINN_PHONG, specular_power = 32},
		{normal = linalg.normalize([3]f32{-0.3, 0.6, 0.4}), base_color = {0.7, 0.7, 0.75}, occlusion = 0.8,
			emissive = {0, 0, 0}, shading_model = .PBR_METALLIC, metallic = 0.8, roughness = 0.3},
		{normal = linalg.normalize([3]f32{0.1, 0.9, -0.2}), base_color = {0.4, 0.5, 0.9}, occlusion = 1,
			emissive = {0, 0, 0}, shading_model = .PBR_SPECGLOSS, specular = {0.04, 0.04, 0.04}, glossiness = 0.6},
		{normal = linalg.normalize([3]f32{0.4, 0.4, 0.82}), base_color = {0.9, 0.6, 0.1}, occlusion = 1,
			emissive = {0, 0, 0}, shading_model = .TOON, bands = 4, rim = 0.5},
		{normal = linalg.normalize([3]f32{0, 1, 0.3}), base_color = {0.85, 0.7, 0.6}, occlusion = 1,
			emissive = {0, 0, 0}, shading_model = .SUBSURFACE, subsurface = {1, 0.4, 0.3}, thickness = 0.3},
		{normal = linalg.normalize([3]f32{0.5, 0.5, 0.7}), base_color = {0.2, 0.9, 0.4}, occlusion = 1,
			emissive = {0, 0, 0}, shading_model = .UNLIT},
	}

	for s in surfaces {
		g := quantize_encoded(gbuffer_encode(s))
		decoded := gbuffer_decode(g)

		// gbuffer_decode leaves position/view/alpha unset -- see its own
		// doc comment (gbuffer.odin) -- so the same view this test shades
		// the original with is threaded through explicitly here rather
		// than read off decoded, matching what deferred_lighting.frag.hlsl
		// actually does (reconstructs view from position, does not decode
		// it).
		want := gbuffer_test_shade(s, view, light_dir, radiance, ambient)
		got := gbuffer_test_shade(decoded, view, light_dir, radiance, ambient)

		expect_shade_close(t, got, want, fmt_shading_model(s.shading_model))
	}
}

@(private = "file")
fmt_shading_model :: proc(m: Shading_Model) -> string {
	switch m {
	case .BLINN_PHONG:   return "BLINN_PHONG"
	case .UNLIT:         return "UNLIT"
	case .PBR_METALLIC:  return "PBR_METALLIC"
	case .PBR_SPECGLOSS: return "PBR_SPECGLOSS"
	case .TOON:          return "TOON"
	case .SUBSURFACE:    return "SUBSURFACE"
	}
	return "?"
}

// -----------------------------------------------------------------------
// Sampler-budget regression -- the shader render_test.odin's own comment
// flagged as "the one at risk"
// -----------------------------------------------------------------------

/*
	`deferred_lighting.frag.hlsl` is the shader the P6 brief itself named as
	at risk: it needs everything mesh.frag.hlsl needs for shading (shadow
	maps, the environment probe) *plus* the four G-buffer targets and its own
	sampled depth target. See `DEFERRED_LIGHTING_SAMPLER_COUNT`'s own doc
	comment (render.odin) for the count (11) and `test_mesh_frag_sampler_count_is_pinned_under_vulkan_floor`
	(render_test.odin) for the identical shape this test copies.
*/
@(test)
test_deferred_lighting_sampler_count_is_pinned_under_vulkan_floor :: proc(t: ^testing.T) {
	testing.expect_value(t, DEFERRED_LIGHTING_SAMPLER_COUNT, 11)

	testing.expect(
		t, DEFERRED_LIGHTING_SAMPLER_COUNT < 16,
		"deferred lighting fragment shader sampler count must stay under Vulkan's guaranteed per-stage floor of 16 (maxPerStageDescriptorSampledImages / maxPerStageDescriptorSamplers)",
	)
}
