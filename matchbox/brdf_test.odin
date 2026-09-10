package matchbox

/*
	Blinn-Phong: the fused loop vs the split contract -- the arithmetic
	----------------------------------------------------------------------
	`lighting_rework.md` section 8 asks for a statement-by-statement
	comparison showing P2b's split (`sample_light` + `brdf_light_blinn_phong`
	+ `brdf_resolve_blinn_phong`, all in `shaders/`) is the same expression as
	P0's fused loop (`brdf_eval_blinn_phong`, now deleted), re-associated
	rather than rewritten -- and that the one deliberate exception, coloured
	specular, is exactly that and nothing more.

	Everything real lives in HLSL, so there is nothing here to import from
	the shader and check against -- these two mirrors are written
	independently, by hand, straight from the two versions of the shader
	source (P0's `blinn_phong.hlsli`, now in git history, and today's), the
	same "checked against an independent implementation" shape the skinning
	palettes and skybox sampling already used. `expect_close3`
	(`tonemap_test.odin`) is reused rather than redeclared -- it is already
	package-private and generic over `[3]f32`, and a second copy would be
	the exact duplication CLAUDE.md's naming section warns a rework should
	not leave behind.

	**What is deliberately left out.** `shadow_visibility` reads a real GPU
	shadow map, which does not exist on the CPU side to mirror, so every
	light below is unshadowed (`shadow = 1`) in both versions -- shadow only
	ever multiplies `radiance` in the real shader (`sample_light`'s own doc
	comment, `lighting_core.hlsli`), so setting it to 1 on both sides changes
	nothing about whether the two re-associate the same way. Directional and
	spot lights are omitted the same way: their own distinction from a point
	light is resolved entirely inside `sample_light`'s direction/attenuation
	branch, which point lights already exercise, and duplicating all three
	kinds here would test HLSL's own `if`/`else` shape rather than the
	re-association this file exists to check.
*/

import "core:math"
import "core:math/linalg"
import "core:testing"

// A minimal point light -- position and colour, the two things
// `brdf_test_fused`/`brdf_test_split` below need. Not `Light` itself: that
// struct carries kind/cone/enabled fields no test below reads, and pulling
// it in would make these mirrors look like they exercise `light_uniform`'s
// packing, which is `light_test.odin`'s job, not this one's.
@(private = "file")
Test_Point_Light :: struct {
	position: [3]f32,
	color:    [3]f32,
}

// The distance falloff curve, identical in both mirrors below and in the
// real shader (`sample_light`, `lighting_core.hlsli`) -- PsxGame's own
// curve, copied rather than reinvented, same as it always has been.
@(private = "file")
brdf_test_attenuation :: proc(surface_pos, light_pos: [3]f32) -> f32 {
	d := linalg.length(light_pos - surface_pos)
	return 1.0 / (1.0 + 0.09 * d + 0.032 * d * d)
}

// HLSL's `reflect(i, n)`: Odin's `core:math/linalg` has no equivalent, so
// this is the textbook definition `i - 2 * dot(n, i) * n`, the same formula
// every reference on the reflection vector gives.
@(private = "file")
brdf_test_reflect :: proc(i, n: [3]f32) -> [3]f32 {
	return i - 2 * linalg.dot(n, i) * n
}

/*
	P0's own `brdf_eval_blinn_phong`, before this phase: one loop, two
	running sums, specular accumulated *uncoloured* (`spec * attenuation`,
	`shadow` fixed at 1 -- see this file's own top comment). Returned as
	three separate values rather than just the final colour so the tests
	below can check the diffuse and specular sums independently before
	checking the combine that uses them.
*/
@(private = "file")
brdf_test_fused :: proc(
	base_color, ambient, normal, view, surface_pos: [3]f32,
	lights: []Test_Point_Light,
	specular_power: f32,
) -> (diffuse_sum, specular_sum, color: [3]f32) {
	for light in lights {
		to_light := linalg.normalize(light.position - surface_pos)
		atten    := brdf_test_attenuation(surface_pos, light.position)
		ndl      := max(linalg.dot(normal, to_light), 0)

		diffuse_sum += light.color * ndl * atten

		if ndl > 0 {
			r    := brdf_test_reflect(-to_light, normal)
			spec := math.pow(max(f32(0), linalg.dot(view, r)), specular_power)
			specular_sum += spec * atten // uncoloured -- P0's own shape
		}
	}

	color = base_color * (1 + specular_sum) * diffuse_sum + base_color * (ambient / 10)
	return
}

// The mirror of `Light_Sample` (`brdf/contract.hlsli`) and `Radiance`
// (same file) -- only the fields the two procs below actually read.
@(private = "file")
Test_Light_Sample :: struct {
	direction: [3]f32,
	radiance:  [3]f32,
	n_dot_l:   f32,
}

@(private = "file")
Test_Radiance :: struct {
	diffuse:  [3]f32,
	specular: [3]f32,
}

// Mirrors `sample_light` (`lighting_core.hlsli`), point-light branch only --
// see this file's own top comment for why. `shadow` is folded in as a fixed
// 1, the same simplification `radiance` documents at the real function.
@(private = "file")
brdf_test_sample_light :: proc(light: Test_Point_Light, surface_pos, normal: [3]f32) -> Test_Light_Sample {
	direction := linalg.normalize(light.position - surface_pos)
	atten     := brdf_test_attenuation(surface_pos, light.position)

	return Test_Light_Sample{
		direction = direction,
		radiance  = light.color * atten,
		n_dot_l   = max(linalg.dot(normal, direction), 0),
	}
}

// Mirrors `brdf_light_blinn_phong` (`shaders/brdf/blinn_phong.hlsli`).
// `r.specular` is `sample.radiance * spec` -- coloured, the one line this
// phase actually changed; see that function's own doc comment for why.
@(private = "file")
brdf_test_light_blinn_phong :: proc(view, normal: [3]f32, sample: Test_Light_Sample, specular_power: f32) -> Test_Radiance {
	r: Test_Radiance
	r.diffuse = sample.radiance * sample.n_dot_l

	if sample.n_dot_l > 0 {
		refl := brdf_test_reflect(-sample.direction, normal)
		spec := math.pow(max(f32(0), linalg.dot(view, refl)), specular_power)
		r.specular = sample.radiance * spec
	}

	return r
}

// Mirrors `brdf_resolve_blinn_phong` -- unchanged from P0's own final
// combine, statement for statement.
@(private = "file")
brdf_test_resolve_blinn_phong :: proc(base_color, ambient: [3]f32, total: Test_Radiance) -> [3]f32 {
	return base_color * (1 + total.specular) * total.diffuse + base_color * (ambient / 10)
}

// Mirrors `shade_lights` (`lighting_core.hlsli`) dispatching to the two
// procs above every iteration, the same shape the real loop dispatches to
// `brdf_light`/`brdf_resolve`.
@(private = "file")
brdf_test_split :: proc(
	base_color, ambient, normal, view, surface_pos: [3]f32,
	lights: []Test_Point_Light,
	specular_power: f32,
) -> (total: Test_Radiance, color: [3]f32) {
	for light in lights {
		sample := brdf_test_sample_light(light, surface_pos, normal)
		r      := brdf_test_light_blinn_phong(view, normal, sample, specular_power)

		total.diffuse  += r.diffuse
		total.specular += r.specular
	}

	color = brdf_test_resolve_blinn_phong(base_color, ambient, total)
	return
}

// The scene every test below shares: two point lights (so the diffuse and
// specular sums are actually sums, not one term each -- the case that would
// have hidden a mis-association), a tilted normal and view so `ndl` and the
// specular term are neither 0 nor 1 for either light.
@(private = "file")
brdf_test_scene :: proc(colors: [2][3]f32) -> (lights: [2]Test_Point_Light, normal, view, surface_pos, base_color, ambient: [3]f32) {
	lights = {
		{position = {2, 3, 1}, color = colors[0]},
		{position = {-1, 2, 4}, color = colors[1]},
	}
	normal      = linalg.normalize([3]f32{0.2, 1, 0.1})
	view        = linalg.normalize([3]f32{0, 1, 1})
	surface_pos = {0, 0, 0}
	base_color  = {1, 1, 1}
	ambient     = {0.3, 0.3, 0.5}
	return
}

@(test)
test_split_diffuse_sum_matches_fused_loop_exactly :: proc(t: ^testing.T) {
	// White lights: the one change this phase makes is to specular, so
	// diffuse must match to the bit regardless of colour.
	lights, normal, view, surface_pos, base_color, ambient := brdf_test_scene({{1, 1, 1}, {0.2, 0.6, 0.9}})

	diffuse_sum, _, _ := brdf_test_fused(base_color, ambient, normal, view, surface_pos, lights[:], 16)
	total, _ := brdf_test_split(base_color, ambient, normal, view, surface_pos, lights[:], 16)

	expect_close3(t, total.diffuse, diffuse_sum,
		"the diffuse channel must re-associate exactly -- nothing about this phase changes diffuse")
}

@(test)
test_white_light_specular_sum_matches_fused_loop_exactly :: proc(t: ^testing.T) {
	// Both lights white: multiplying a colour of (1,1,1) into specular does
	// nothing, so the new, coloured accumulator must match P0's old
	// uncoloured one exactly -- this is the case that shows the change is
	// invisible for the common (white-light) scene.
	lights, normal, view, surface_pos, base_color, ambient := brdf_test_scene({{1, 1, 1}, {1, 1, 1}})

	_, specular_sum, _ := brdf_test_fused(base_color, ambient, normal, view, surface_pos, lights[:], 16)
	total, _ := brdf_test_split(base_color, ambient, normal, view, surface_pos, lights[:], 16)

	expect_close3(t, total.specular, specular_sum,
		"a white light's specular must be unaffected by folding colour into radiance")
}

@(test)
test_white_light_full_combine_matches_fused_loop_exactly :: proc(t: ^testing.T) {
	// The integration check: with both sums equal (the two tests above),
	// the non-linear combine in brdf_resolve_blinn_phong reproduces the
	// same cross terms brdf_eval_blinn_phong's single loop did, since it is
	// the identical expression applied to the identical sums.
	lights, normal, view, surface_pos, base_color, ambient := brdf_test_scene({{1, 1, 1}, {0.6, 0.6, 0.6}})

	_, _, fused_color := brdf_test_fused(base_color, ambient, normal, view, surface_pos, lights[:], 16)
	_, split_color := brdf_test_split(base_color, ambient, normal, view, surface_pos, lights[:], 16)

	expect_close3(t, split_color, fused_color,
		"the split contract must produce the same final colour as the fused loop for white lights")
}

/*
	The deliberate change, isolated. A pure red light's specular highlight
	must now carry only its own red channel -- P0's own uncoloured version
	put the identical value in all three channels regardless of the light's
	colour, which is the "awkward line" `lighting_rework.md` section 2.1
	flags and `brdf_light_blinn_phong`'s own doc comment explains.
*/
@(test)
test_coloured_light_specular_is_tinted_where_fused_loop_was_not :: proc(t: ^testing.T) {
	lights, normal, view, surface_pos, base_color, ambient := brdf_test_scene({{1, 0, 0}, {1, 0, 0}}) // pure red, both lights

	_, specular_sum_old, _ := brdf_test_fused(base_color, ambient, normal, view, surface_pos, lights[:], 16)
	total, _ := brdf_test_split(base_color, ambient, normal, view, surface_pos, lights[:], 16)

	testing.expect(t, specular_sum_old.g == specular_sum_old.r && specular_sum_old.b == specular_sum_old.r,
		"P0's own specular carried no colour -- every channel should be the identical scalar")

	testing.expectf(t, math.abs(total.specular.r - specular_sum_old.r) < TONEMAP_TEST_EPSILON,
		"a pure-red light's own red channel is unaffected by coloured specular: red * red is still red")
	testing.expect(t, total.specular.g == 0 && total.specular.b == 0,
		"a pure-red light's specular highlight must carry no green or blue -- that is the whole change")
}

// -----------------------------------------------------------------------
// What every model must do with ambient light
// -----------------------------------------------------------------------

/*
	The diffuse-ambient term of each shading model's own resolve, mirrored
	from its own file under `shaders/brdf`. (Not written as a glob: Odin block
	comments nest, so a star-slash inside one closes it early -- the trap
	`lighting_rework_handover.md` records from P6.)

	Only that term, not the whole resolve: the rest of each resolve is already
	covered (Blinn-Phong above, the per-light PBR halves in `pbr_test.odin`),
	and the ambient term is the one no mirror reached -- which is exactly why
	the bug below lived in it.

	`UNLIT` has no entry because it reads no scene lighting at all; that is
	itself a property, and the test asserts it.
*/
@(private)
brdf_test_ambient_diffuse :: proc(
	model:      Shading_Model,
	base_color: [3]f32,
	ambient:    [3]f32,
	metallic:   f32,
) -> [3]f32 {
	switch model {
	case .BLINN_PHONG: return base_color * (ambient / 10)
	case .PBR_METALLIC: return base_color * ambient * (1 - metallic)
	case .PBR_SPECGLOSS: return base_color * ambient
	case .TOON: return base_color * ambient
	case .SUBSURFACE: return base_color * ambient
	case .UNLIT: return {0, 0, 0}
	}

	return {0, 0, 0}
}

/*
	**Ambient light is irradiance arriving, so what a surface does with it has
	to depend on what the surface is made of.** Two consequences, and each is
	a property no shading model may break:

	  - a **black** surface reflects none of it, so ambient cannot make one
	    glow;
	  - doubling the albedo doubles the response, since the term is a plain
	    product.

	**This test exists because `pbr_metallic` and `pbr_specgloss` broke both.**
	Their resolves added `ambient_light(surface)` straight into the output
	rather than multiplying it by `base_color`, so every surface in a scene
	got the raw ambient colour laid over it whatever it was made of. With
	`Ambient_Kind.HEMISPHERE` and a pale blue sky, every material washed toward
	pale blue and a black surface came out pale blue -- which is the version of
	it that cannot be argued with, and the one asserted first below.

	It survived two phases because of a gap in what was mirrored, not a gap in
	rigour: `pbr_test.odin` sweeps a white furnace through
	`brdf_light_pbr_metallic`, which is the per-light half and was right, and
	the resolve half had no CPU mirror at all. Three of the five models did it
	correctly; the two with no mirror were the two that did not. **Where there
	is no mirror there is no check**, which is worth more than the bug.
*/
@(test)
test_ambient_is_modulated_by_albedo :: proc(t: ^testing.T) {
	ambient := [3]f32{0.35, 0.45, 0.62}

	for model in Shading_Model {
		// A black surface reflects nothing, ambient included.
		black := brdf_test_ambient_diffuse(model, {0, 0, 0}, ambient, 0)

		testing.expectf(t, black == [3]f32{0, 0, 0},
			"%v: a black surface emits %v of ambient light -- ambient is being added rather than reflected",
			model, black)

		if model == .UNLIT do continue

		// And the response is proportional to the albedo, which is what makes
		// it a reflection rather than an offset.
		half   := brdf_test_ambient_diffuse(model, {0.4, 0.4, 0.4}, ambient, 0)
		double := brdf_test_ambient_diffuse(model, {0.8, 0.8, 0.8}, ambient, 0)

		for i in 0 ..< 3 {
			testing.expectf(t, abs(double[i] - 2 * half[i]) < 1e-6,
				"%v: doubling the albedo took the ambient response from %.6f to %.6f, not to %.6f",
				model, half[i], double[i], 2 * half[i])
		}
	}
}

/*
	A metal has no diffuse response to ambient either, for the same reason it
	has none to a light: metalness is exactly the statement that light does not
	scatter back out from underneath the surface. Its ambient arrives through
	`pbr_environment_specular` instead, which is weighted by `f0` and was
	always correct.

	`PBR_METALLIC` is the only model with a metalness to check -- spec-gloss
	carries its specular colour in its own field rather than deriving it from
	one, which is the whole difference between the two parameterizations.
*/
@(test)
test_ambient_diffuse_vanishes_on_a_metal :: proc(t: ^testing.T) {
	ambient := [3]f32{0.35, 0.45, 0.62}
	base    := [3]f32{0.9, 0.8, 0.5}

	full := brdf_test_ambient_diffuse(.PBR_METALLIC, base, ambient, 1)
	testing.expectf(t, full == [3]f32{0, 0, 0},
		"a full metal has a diffuse ambient response of %v, which it should not have at all", full)

	// And it fades linearly on the way there, rather than switching at some
	// threshold -- glTF's metalness is a blend, not a flag.
	dielectric := brdf_test_ambient_diffuse(.PBR_METALLIC, base, ambient, 0)
	half       := brdf_test_ambient_diffuse(.PBR_METALLIC, base, ambient, 0.5)

	for i in 0 ..< 3 {
		testing.expectf(t, abs(half[i] - dielectric[i] * 0.5) < 1e-6,
			"metalness 0.5 gave %.6f, want half of the dielectric's %.6f", half[i], dielectric[i])
	}
}
