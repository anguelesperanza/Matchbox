package matchbox

/*
	Volumetric light -- the phase function and the absorption
	----------------------------------------------------------
	`lighting_rework.md` section 8 again, and the same honest limit
	`ssao_test.odin` opens with: the march itself is in the shader and needs a
	depth buffer only a GPU produces. What is testable is the two pieces of
	physics the march is built out of, and both are pure functions here.

	They are worth testing for a reason beyond diligence. Henyey-Greenstein's
	`1/(4*pi)` and Beer-Lambert's sign are the two constants that decide what
	`Volumetric.density` *means*: get either wrong and the effect still looks
	like something -- a haze that responds to the settings -- while every
	number in the doc comments describes a different effect from the one
	running. That is the class of bug nothing but arithmetic catches.

	**The phase function is checked by integrating it over the sphere**, which
	is the property that fixes the constant rather than merely being consistent
	with it: a scattering function has to redistribute the light it is given,
	not create or destroy it, so its integral over all directions is exactly 1
	at every anisotropy. The integration below is a plain Riemann sum in
	spherical coordinates, derived here from the definition rather than from
	anything the implementation does.

	**Nothing here has been seen to render.**
*/

import "core:math"
import "core:testing"

// -----------------------------------------------------------------------
// The phase function
// -----------------------------------------------------------------------

/*
	Isotropic scattering spreads a unit of light evenly over a unit sphere,
	whose area is 4*pi -- so the phase function is 1/(4*pi) in every
	direction, and that is a closed-form number rather than a measurement:
	0.0795774715.

	The single most valuable assertion in this file. Every other number the
	volumetric module produces is proportional to this one, so a wrong
	constant here scales the whole effect by a factor no setting names.
*/
@(test)
test_volumetric_phase_isotropic_is_one_over_four_pi :: proc(t: ^testing.T) {
	want := f32(1) / (4 * math.PI)

	for step in 0 ..= 20 {
		cos_theta := f32(step) / 10 - 1 // -1 to 1
		got := volumetric_phase_hg(cos_theta, 0)

		testing.expectf(t, math.abs(got - want) < 1e-6,
			"g = 0 at cos %.2f gave %.9f, want %.9f (1/4pi)", cos_theta, got, want)
	}
}

/*
	**It integrates to 1 over the sphere, at every anisotropy** -- the
	property that makes it a redistribution rather than a gain.

	A Riemann sum over the solid angle, written from the definition: the
	element is `sin(theta) d(theta) d(phi)`, and the function is symmetric
	about the axis so the `phi` integral is just a factor of 2*pi. Swept
	across the whole range `Volumetric.anisotropy` clamps to, because
	normalization is easy to have at g = 0 and lose as g grows -- the lobe
	narrows and a coarse sum starts to miss its peak, which is why the step
	count below is high rather than convenient.
*/
@(test)
test_volumetric_phase_integrates_to_one :: proc(t: ^testing.T) {
	anisotropies := [?]f32{-0.95, -0.6, -0.2, 0, 0.2, 0.6, 0.95}

	steps :: 200000

	for g in anisotropies {
		total := f64(0)

		for i in 0 ..< steps {
			theta := (f64(i) + 0.5) * math.PI / f64(steps)
			d_theta := math.PI / f64(steps)

			phase := f64(volumetric_phase_hg(f32(math.cos(theta)), g))
			total += phase * math.sin(theta) * d_theta
		}

		total *= 2 * math.PI

		testing.expectf(t, math.abs(total - 1) < 1e-3,
			"g = %.2f integrates to %.9f over the sphere, want 1", g, total)
	}
}

/*
	Positive `g` scatters forward, negative scatters back, and "forward" means
	*the way the light is already travelling* -- cos_theta = 1.

	Checked as an ordering rather than against numbers, because the ordering
	is the whole semantic content of the sign: a `g` whose sense was flipped
	would still integrate to 1 and still be 1/(4*pi) at zero, so neither test
	above would notice, while every scene using it would have its shafts
	brightest in exactly the wrong half of the screen.
*/
@(test)
test_volumetric_phase_sign_of_anisotropy :: proc(t: ^testing.T) {
	forward  := volumetric_phase_hg(1, 0.6)
	sideways := volumetric_phase_hg(0, 0.6)
	backward := volumetric_phase_hg(-1, 0.6)

	testing.expectf(t, forward > sideways && sideways > backward,
		"g = +0.6 should peak forward: forward %.6f, sideways %.6f, backward %.6f",
		forward, sideways, backward)

	testing.expect(t, volumetric_phase_hg(-1, -0.6) > volumetric_phase_hg(1, -0.6),
		"g = -0.6 should peak backward")

	// And it is symmetric under flipping both, which is what makes -g the
	// mirror of +g rather than an unrelated curve.
	testing.expect(t, math.abs(volumetric_phase_hg(0.4, 0.6) - volumetric_phase_hg(-0.4, -0.6)) < 1e-6,
		"the phase function is not symmetric under flipping both cos and g")
}

// Never negative and never infinite, anywhere in the range the settings can
// reach -- a negative phase would subtract light from the scene, and an
// infinity would leave a NaN in the HDR target that survives the tonemap and
// spreads through bloom.
@(test)
test_volumetric_phase_stays_finite_and_positive :: proc(t: ^testing.T) {
	for gi in 0 ..= 40 {
		g := f32(gi) / 20 - 1 // -1 to 1, past the clamp on purpose

		for ci in 0 ..= 40 {
			cos_theta := f32(ci) / 20 - 1

			v := volumetric_phase_hg(cos_theta, g)
			testing.expectf(t, v >= 0 && !math.is_nan(v) && !math.is_inf(v),
				"g %.2f, cos %.2f gave %v", g, cos_theta, v)
		}
	}
}

// -----------------------------------------------------------------------
// Absorption
// -----------------------------------------------------------------------

/*
	Beer-Lambert. Nothing is absorbed at zero distance, everything is absorbed
	eventually, and the fall is exponential rather than linear -- checked at
	the one point where the exponential is a named number: at
	`density * distance = 1` exactly, 1/e of the light survives.

	The multiplicative property is the one that actually pins the *shape*:
	crossing two units of air is the same as crossing one unit twice. A linear
	falloff would pass the endpoints and fail this.
*/
@(test)
test_volumetric_transmittance_is_beer_lambert :: proc(t: ^testing.T) {
	testing.expect(t, volumetric_transmittance(0.5, 0) == 1, "distance zero absorbed something")
	testing.expect(t, volumetric_transmittance(0, 100) == 1, "zero density absorbed something")

	one_e := volumetric_transmittance(0.25, 4) // density * distance = 1
	testing.expectf(t, math.abs(one_e - f32(1) / math.E) < 1e-6,
		"at density*distance = 1, %.9f survives, want 1/e = %.9f", one_e, f32(1) / math.E)

	once  := volumetric_transmittance(0.3, 2)
	twice := volumetric_transmittance(0.3, 4)
	testing.expectf(t, math.abs(once * once - twice) < 1e-6,
		"crossing two units twice (%.9f) is not crossing four units (%.9f)", once * once, twice)

	// Monotone, and never above 1 -- air cannot brighten what passes through
	// it, which is what the *scattering* term is separately for.
	previous := f32(1)
	for i in 0 ..= 200 {
		v := volumetric_transmittance(0.05, f32(i))
		testing.expectf(t, v <= previous + 1e-7 && v >= 0 && v <= 1,
			"transmittance at distance %d is %.9f, previous %.9f", i, v, previous)
		previous = v
	}
}

// -----------------------------------------------------------------------
// Settings
// -----------------------------------------------------------------------

/*
	Zero means the default, with `anisotropy` the deliberate exception -- zero
	is isotropic scattering, which is a real setting and what a thick cloud
	does, so it is taken literally rather than replaced.

	And the clamp that matters: the phase function's denominator goes to zero
	at g = +/-1, so the settings never let it get there. `test_volumetric_
	phase_stays_finite_and_positive` above sweeps past the clamp on purpose to
	prove the shader's own floor would hold anyway, but this is the belt.
*/
@(test)
test_volumetric_settings_normalized :: proc(t: ^testing.T) {
	filled := volumetric_settings_normalized(Volumetric{enabled = true})

	testing.expect(t, filled.density      == VOLUMETRIC_DEFAULTS.density,      "density was not defaulted")
	testing.expect(t, filled.steps        == VOLUMETRIC_DEFAULTS.steps,        "steps was not defaulted")
	testing.expect(t, filled.max_distance == VOLUMETRIC_DEFAULTS.max_distance, "max_distance was not defaulted")
	testing.expect(t, filled.intensity    == VOLUMETRIC_DEFAULTS.intensity,    "intensity was not defaulted")

	testing.expect(t, filled.anisotropy == 0, "a deliberate isotropic setting was overwritten")

	clamped := volumetric_settings_normalized(Volumetric{enabled = true, anisotropy = 1, steps = 100000})
	testing.expect(t, clamped.anisotropy == 0.95, "anisotropy was not clamped off the singularity")
	testing.expect(t, clamped.steps == MAX_VOLUMETRIC_STEPS, "steps was not clamped")

	low := volumetric_settings_normalized(Volumetric{enabled = true, anisotropy = -3})
	testing.expect(t, low.anisotropy == -0.95, "a negative anisotropy was not clamped off the singularity")

	testing.expect(t, volumetric_settings_normalized(Volumetric{}) == Volumetric{},
		"a disabled Volumetric grew defaults nothing will read")
}

// The same agreement ssao_test.odin pins for its own half: whatever decides
// the 3D pass stores its depth has to cover every effect that reads it back.
// Volumetric light is the second, and a pass that discarded its depth with
// this on is a frame of garbage with no error attached.
@(test)
test_scene_depth_is_read_covers_volumetric :: proc(t: ^testing.T) {
	previous := mbi.renderer.lighting.settings
	defer mbi.renderer.lighting.settings = previous

	mbi.renderer.lighting.settings = lighting_settings_normalized(
		Lighting_Settings{enabled = true, exposure = 1, volumetric = VOLUMETRIC_DEFAULTS})

	testing.expect(t, scene_depth_is_read(),
		"volumetric light is on and the 3D pass would still throw its depth away")

	// And it does not drag the depth prepass in with it: volumetric light
	// needs depth *after* shading, not before, so a forward scene has no
	// reason to be deferred for it. Getting this wrong would make every
	// forward frame pay for an extra geometry pass it has no use for.
	testing.expect(t, !pipeline_forward_defers_scene(),
		"volumetric light should not require the depth prepass SSAO needs")
}

// Pinned the same way MESH_FRAG_SAMPLER_COUNT is, and for the same reason:
// the number has to equal what the compiled binary declares, only a comment
// keeps it in step, and Vulkan's guaranteed per-stage floor is 16.
@(test)
test_volumetric_sampler_count_is_pinned_under_vulkan_floor :: proc(t: ^testing.T) {
	testing.expect_value(t, VOLUMETRIC_SAMPLER_COUNT, 8)

	testing.expect(
		t, VOLUMETRIC_SAMPLER_COUNT < 16,
		"volumetric fragment shader sampler count must stay under Vulkan's guaranteed per-stage floor of 16",
	)
}
