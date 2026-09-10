package matchbox

/*
	Reflection probes -- placement, packing, and the blend weight
	--------------------------------------------------------------
	The same honest split `ssao_test.odin` and `volumetric_test.odin` open
	with. Capturing a probe renders the scene six times and baking convolves
	it, and neither is checkable without a GPU. What *is* checkable is the
	bookkeeping around them, and the bookkeeping is where the bugs that produce
	a silently wrong picture live:

	- **The layer arithmetic.** A probe's faces live at
	  `probe * 6 + face`, and its prefiltered levels at
	  `probe * 6 * levels + level * 6 + face`. Two places compute that -- the
	  bake (`reflection.odin`) and the blend (`lighting_core.hlsli`) -- and if
	  they disagree, probe 2 reads probe 1's reflection and nothing errors.
	  `reflection_probe_layer` is that arithmetic named once so a test can
	  reach it.

	- **The blend weight.** The shape of the falloff decides whether a seam
	  between two probes is invisible or a visible ring, and it is a pure
	  function of one distance and two numbers.

	- **The uniform packing.** `Probe_Frag_Data.info.x` is the loop bound the
	  shader stops at. If it ever exceeds what has actually been placed and
	  baked, the blend samples a layer nobody wrote.

	**Nothing here has been seen to render.** Nothing here checks that a probe
	captures the room correctly, that the convolution is right, or that a
	backend will render into a cube face at all -- which is the one
	unverifiable assumption `Reflection_Probes`' own doc comment flags.
*/

import "core:math"
import "core:testing"

REFLECTION_TEST_EPSILON :: f32(1e-6)

// -----------------------------------------------------------------------
// Placement
// -----------------------------------------------------------------------

@(private)
reset_reflection_for_test :: proc() {
	mbi.renderer.lighting.reflection.probes = {}
	mbi.renderer.lighting.reflection.count  = 0
}

/*
	Probes fill slots in order, and the slot is what the caller gets back --
	which matters because that number is the caller's only handle on the probe
	for `begin_probe_capture` and `bake_reflection_probe`. An index that did
	not match the layer the bake writes would put every probe's reflection on
	a neighbour.
*/
@(test)
test_add_reflection_probe_fills_slots_in_order :: proc(t: ^testing.T) {
	reset_reflection_for_test()
	defer reset_reflection_for_test()

	for i in 0 ..< MAX_REFLECTION_PROBES {
		index := add_reflection_probe({f32(i), 0, 0}, 5)
		testing.expectf(t, index == i, "the %d'th probe got slot %d", i, index)
	}

	testing.expect(t, get_reflection_probe_count() == MAX_REFLECTION_PROBES, "the count did not follow")

	// Full is reported rather than wrapping onto slot 0, which would silently
	// overwrite a probe the game still thinks it has.
	testing.expect(t, add_reflection_probe({9, 9, 9}, 5) == -1,
		"a probe past MAX_REFLECTION_PROBES was accepted")
	testing.expect(t, get_reflection_probe_count() == MAX_REFLECTION_PROBES, "a rejected probe still moved the count")
}

// A negative radius is nobody's setting but is a thing a float can hold, and a
// falloff outside [0, 1] would put the fade's inner edge outside its outer one
// -- so both are clamped at the door rather than defended against in the
// shader, which would pay for it per fragment.
@(test)
test_add_reflection_probe_clamps :: proc(t: ^testing.T) {
	reset_reflection_for_test()
	defer reset_reflection_for_test()

	index := add_reflection_probe({0, 0, 0}, -3, 4)
	probe := mbi.renderer.lighting.reflection.probes[index]

	testing.expect(t, probe.radius == 0, "a negative radius was not clamped")
	testing.expect(t, probe.falloff == 1, "a falloff past 1 was not clamped")

	index2 := add_reflection_probe({0, 0, 0}, 5, -1)
	testing.expect(t, mbi.renderer.lighting.reflection.probes[index2].falloff == 0,
		"a negative falloff was not clamped")
}

// Clearing forgets every probe but keeps the textures -- a level change
// re-places probes into the identical arrays, and the arrays are sized by
// MAX_REFLECTION_PROBES rather than by the count, so there is nothing to
// resize and nothing to release.
@(test)
test_clear_reflection_probes_keeps_the_arrays :: proc(t: ^testing.T) {
	reset_reflection_for_test()
	defer reset_reflection_for_test()

	add_reflection_probe({1, 2, 3}, 4)
	add_reflection_probe({5, 6, 7}, 8)

	irradiance := mbi.renderer.lighting.reflection.irradiance

	clear_reflection_probes()

	testing.expect(t, get_reflection_probe_count() == 0, "clearing did not empty the set")
	testing.expect(t, mbi.renderer.lighting.reflection.irradiance == irradiance,
		"clearing released the shared arrays")
}

// -----------------------------------------------------------------------
// The layer arithmetic
// -----------------------------------------------------------------------

/*
	**The one number two files have to agree on.** The bake writes probe `p`'s
	prefiltered level `l` face `f` at `p * 6 * levels + l * 6 + f`, and
	`reflection_probe_specular` (lighting_core.hlsli) reads it back with the
	identical expression written out separately. They cannot be shared -- one
	is Odin and one is HLSL -- so what can be done is to name the arithmetic
	once here and check it against a table derived from the layout rather than
	from either copy.

	Every expected value below is the layout stated in prose, evaluated by
	hand: probe 0 occupies layers 0 through `6 * levels - 1`, probe 1 starts
	where probe 0 ends, level `l` within a probe starts at `l * 6`, and face
	`f` is the offset inside that.
*/
@(test)
test_reflection_probe_layer_arithmetic :: proc(t: ^testing.T) {
	levels := 5

	// Probe 0, level 0: the six faces, from the very start of the array.
	for face in 0 ..< 6 {
		testing.expectf(t, reflection_probe_layer(0, 0, face, levels) == face,
			"probe 0 level 0 face %d", face)
	}

	// Probe 0, level 1: one whole face-set further in.
	testing.expect(t, reflection_probe_layer(0, 1, 0, levels) == 6, "probe 0 level 1 face 0")
	testing.expect(t, reflection_probe_layer(0, 4, 5, levels) == 29, "probe 0's last level, last face")

	// Probe 1 starts exactly where probe 0's last level ended -- 6 * 5 = 30.
	testing.expect(t, reflection_probe_layer(1, 0, 0, levels) == 30, "probe 1 level 0 face 0")
	testing.expect(t, reflection_probe_layer(3, 4, 5, levels) == 119, "the very last layer of four probes")

	// And the irradiance array, which has no level term at all.
	testing.expect(t, reflection_probe_irradiance_layer(0, 0) == 0, "probe 0's first irradiance face")
	testing.expect(t, reflection_probe_irradiance_layer(2, 3) == 15, "probe 2's fourth irradiance face")
}

/*
	Every layer a full set of probes can ask for fits inside the array that was
	allocated for it, and no two ask for the same one -- which is the property
	that actually matters and the one a hand-checked table cannot show.

	Swept over every probe, level and face, collecting each layer into a set.
	A collision here means two probes share a face and one silently reflects
	the other; an overflow means a bake writes past the end of the texture.
*/
@(test)
test_reflection_probe_layers_are_unique_and_in_range :: proc(t: ^testing.T) {
	for levels in 1 ..= 8 {
		seen := make(map[int]bool, context.temp_allocator)
		defer delete(seen)

		capacity := MAX_REFLECTION_PROBES * 6 * levels

		for probe in 0 ..< MAX_REFLECTION_PROBES {
			for level in 0 ..< levels {
				for face in 0 ..< 6 {
					layer := reflection_probe_layer(probe, level, face, levels)

					testing.expectf(t, layer >= 0 && layer < capacity,
						"%d levels: probe %d level %d face %d lands on layer %d, outside 0..<%d",
						levels, probe, level, face, layer, capacity)

					testing.expectf(t, !(layer in seen),
						"%d levels: layer %d is claimed twice", levels, layer)
					seen[layer] = true
				}
			}
		}

		testing.expectf(t, len(seen) == capacity,
			"%d levels: %d layers used of %d allocated", levels, len(seen), capacity)
	}
}

// -----------------------------------------------------------------------
// The blend weight
// -----------------------------------------------------------------------

/*
	The falloff's three regions, each checked at its own boundary: full
	influence out to `radius * (1 - falloff)`, nothing at or past `radius`, and
	a smooth ramp between.

	The midpoint of the ramp is 0.5 exactly, which is smoothstep's own
	symmetry rather than a number read off the implementation -- and it is the
	assertion that would catch a ramp running the wrong way round, which is
	otherwise invisible: a probe whose influence *grew* with distance would
	still be 1 at the centre and 0 at the edge under a linear check of only
	those two points.
*/
@(test)
test_reflection_probe_weight_regions :: proc(t: ^testing.T) {
	radius  := f32(10)
	falloff := f32(0.4)
	inner   := radius * (1 - falloff) // 6

	testing.expect(t, reflection_probe_weight_at(0, radius, falloff) == 1, "the centre is not fully inside")
	testing.expect(t, reflection_probe_weight_at(inner, radius, falloff) == 1, "the plateau does not reach its own edge")
	testing.expect(t, reflection_probe_weight_at(radius, radius, falloff) == 0, "the radius is not the end of it")
	testing.expect(t, reflection_probe_weight_at(radius * 2, radius, falloff) == 0, "influence reaches past the radius")

	mid := reflection_probe_weight_at((inner + radius) * 0.5, radius, falloff)
	testing.expectf(t, math.abs(mid - 0.5) < 1e-5,
		"the middle of the fade is %.7f, want 0.5", mid)
}

/*
	Monotone non-increasing across the whole range, at every falloff -- so a
	fragment moving away from a probe never gets *more* of it.

	Swept rather than sampled, because the failure this catches lives at a
	boundary: a ramp joined to its plateau by the wrong expression is
	continuous almost everywhere and steps at exactly one point.
*/
@(test)
test_reflection_probe_weight_never_increases :: proc(t: ^testing.T) {
	falloffs := [?]f32{0, 0.1, 0.25, 0.5, 0.9, 1}

	for falloff in falloffs {
		previous := f32(1)

		for step in 0 ..= 400 {
			distance := f32(step) * 0.05 // 0 to 20, past a radius of 10
			weight := reflection_probe_weight_at(distance, 10, falloff)

			testing.expectf(t, weight >= 0 && weight <= 1,
				"falloff %.2f at %.2f: weight %.7f outside [0, 1]", falloff, distance, weight)
			testing.expectf(t, weight <= previous + REFLECTION_TEST_EPSILON,
				"falloff %.2f: weight rose from %.7f to %.7f at distance %.2f",
				falloff, previous, weight, distance)

			previous = weight
		}
	}
}

// A probe that reaches nowhere influences nothing, and does so without
// dividing by its own zero radius -- which would be a NaN spreading through
// every fragment that sampled it.
@(test)
test_reflection_probe_weight_zero_radius :: proc(t: ^testing.T) {
	distances := [?]f32{0, 0.001, 1, 100}

	for distance in distances {
		w := reflection_probe_weight_at(distance, 0, 0.25)
		testing.expectf(t, w == 0 && !math.is_nan(w), "a zero-radius probe at %.3f gave %v", distance, w)
	}
}

// A hard edge is a real setting -- it is what a game picks when it wants one
// probe to stop exactly where the next begins -- so falloff 0 must be full
// influence right up to the radius rather than an undefined smoothstep
// between two equal edges.
@(test)
test_reflection_probe_weight_hard_edge :: proc(t: ^testing.T) {
	testing.expect(t, reflection_probe_weight_at(9.99, 10, 0) == 1, "a hard-edged probe faded early")
	testing.expect(t, reflection_probe_weight_at(10, 10, 0) == 0, "a hard-edged probe reached past its radius")
}

// -----------------------------------------------------------------------
// The uniform block
// -----------------------------------------------------------------------

/*
	`info.x` is the loop bound the shader stops at, and it must never exceed
	what has actually been *baked* -- a count past that samples a layer nobody
	wrote, which is undefined memory read as light.

	The textures are nil in a test build (nothing here creates a device), which
	is exactly the "placed but never baked" case, so this checks the guard that
	matters: probes placed with no arrays behind them report zero.
*/
@(test)
test_reflection_frag_data_reports_no_probes_before_a_bake :: proc(t: ^testing.T) {
	reset_reflection_for_test()
	defer reset_reflection_for_test()

	add_reflection_probe({1, 0, 0}, 5)
	add_reflection_probe({2, 0, 0}, 5)

	data := reflection_frag_data()

	if mbi.renderer.lighting.reflection.irradiance == nil {
		testing.expect(t, data.info.x == 0,
			"probes were reported to the shader with nothing baked behind them")
	}
}

// The packing itself: position in xyz, radius in w, falloff in the second
// array's x. Written out because the shader reads these by component and a
// transposed pair would put a probe's radius where its z belongs -- which
// reads as a probe in the wrong place rather than as an error.
@(test)
test_reflection_frag_data_packs_by_component :: proc(t: ^testing.T) {
	reset_reflection_for_test()
	defer reset_reflection_for_test()

	// Bypassing the nil-texture guard above by filling the struct directly:
	// what is under test here is the packing, not the guard.
	p := &mbi.renderer.lighting.reflection
	p.probes[0] = Reflection_Probe{position = {1, 2, 3}, radius = 4, falloff = 0.5}
	p.count = 1
	p.settings = ENVIRONMENT_PROBE_DEFAULTS

	data := reflection_pack(p.probes[:], 1, ENVIRONMENT_PROBE_DEFAULTS.prefilter_level_count)

	testing.expect(t, data.probes[0] == [4]f32{1, 2, 3, 4}, "position/radius packed wrong")
	testing.expect(t, data.params[0] == [4]f32{0.5, 0, 0, 0}, "falloff packed wrong")
	testing.expect(t, data.info.x == 1, "the count is wrong")
	testing.expect(t, data.info.y == f32(ENVIRONMENT_PROBE_DEFAULTS.prefilter_level_count - 1),
		"the roughness scale is not levels - 1")
	testing.expect(t, data.info.z == f32(ENVIRONMENT_PROBE_DEFAULTS.prefilter_level_count),
		"the level count the layer arithmetic needs is wrong")
}
