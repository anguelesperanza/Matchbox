package matchbox

/*
	Light packing -- the arithmetic
	--------------------------------
	`light_uniform` is the one place a `Light` becomes the bytes the shader
	actually reads, and `set_lights` is the one place that decides which
	lights actually reach the GPU list and which of those become shadow
	casters. Both are pure CPU-side logic -- no GPU is needed, since
	`upload_light_buffer` (light.odin) no-ops without a device -- and their
	failures are quiet in the same way the shadow matrix's alignment gap was:
	a wrong number here is wrong lighting, not a crash.
*/

import "core:testing"

@(test)
test_spot_light_uniform_packing :: proc(t: ^testing.T) {
	light := create_spot_light({1, 2, 3}, {0, -1, 0}, WHITE, 15, 25)
	u := light_uniform(light, SHADOW_DEFAULTS.bias)

	testing.expect(t, u.target.w == 2, "a spotlight must pack as kind 2")
	testing.expect(t, u.cone.x == 25, "cone.x should be the outer angle")
	testing.expect(t, u.cone.y == 15, "cone.y should be the inner angle")

	testing.expect(t, u.target.x == 0 && u.target.y == -1 && u.target.z == 0,
		"target should carry the spotlight's direction, not its position")
}

@(test)
test_directional_and_point_still_pack_as_before :: proc(t: ^testing.T) {
	d := light_uniform(create_directional_light({1, 0, 0}), SHADOW_DEFAULTS.bias)
	testing.expect(t, d.target.w == 0, "a directional light must still pack as kind 0")

	p := light_uniform(create_point_light({0, 0, 0}), SHADOW_DEFAULTS.bias)
	testing.expect(t, p.target.w == 1, "a point light must still pack as kind 1")
}

/*
	A disabled light is dropped rather than uploaded -- `set_lights` no
	longer packs a fixed MAX_LIGHTS array where a disabled slot could sit as
	sixty-four zeroed bytes; unbounded means every uploaded element is real.
	See light.odin's own top comment for why an unbounded list replaced the
	old cap.
*/
@(test)
test_disabled_light_is_dropped_from_upload :: proc(t: ^testing.T) {
	defer set_lights({})

	on  := create_point_light({0, 0, 0})
	off := create_point_light({1, 1, 1})
	off.enabled = false

	set_lights({off, on})

	testing.expect(t, len(mbi.renderer.lighting.light_data) == 1,
		"a disabled light should not be uploaded")
	testing.expect(t, mbi.renderer.lighting.light_data[0].position.x == 0,
		"the surviving light should be the one that was enabled")
}

// The actual path begin_shadow_pass reads from, not just light_uniform in
// isolation -- a spotlight marked casts_shadow has to make it all the way
// through set_lights to mbi.renderer.lighting.shadow.caster_indices the same
// way a directional light's own already does.
@(test)
test_spot_light_can_become_shadow_caster :: proc(t: ^testing.T) {
	defer set_lights({})

	spot := create_spot_light({0, 5, 0}, {0, -1, 0}, casts_shadow = true)
	set_lights({spot})

	testing.expect(t, mbi.renderer.lighting.shadow.caster_indices[0] == 0,
		"a spotlight marked casts_shadow should become a shadow caster")
}

// Two lights marked casts_shadow both become casters, one per slot, in the
// order set_lights was given them -- not just the first, which the single-
// caster system this replaced would have stopped at.
@(test)
test_two_lights_can_both_become_casters :: proc(t: ^testing.T) {
	defer set_lights({})

	a := create_directional_light({0, -1, 0}, casts_shadow = true)
	b := create_spot_light({0, 5, 0}, {0, -1, 0}, casts_shadow = true)
	set_lights({a, b})

	testing.expect(t, mbi.renderer.lighting.shadow.caster_indices[0] == 0, "the first casts_shadow light should be slot 0's caster")
	testing.expect(t, mbi.renderer.lighting.shadow.caster_indices[1] == 1, "the second casts_shadow light should be slot 1's caster")
}

// A third casts_shadow light beyond MAX_SHADOW_CASTERS degrades silently,
// the same way an unsupported point-light shadow already does, rather than
// bumping one of the first two out.
@(test)
test_third_shadow_casting_light_is_not_selected :: proc(t: ^testing.T) {
	defer set_lights({})

	a := create_directional_light({0, -1, 0}, casts_shadow = true)
	b := create_spot_light({0, 5, 0}, {0, -1, 0}, casts_shadow = true)
	c := create_directional_light({1, -1, 0}, casts_shadow = true)
	set_lights({a, b, c})

	testing.expect(t, mbi.renderer.lighting.shadow.caster_indices[0] == 0, "the first casts_shadow light should still be slot 0's caster")
	testing.expect(t, mbi.renderer.lighting.shadow.caster_indices[1] == 1, "the second casts_shadow light should still be slot 1's caster")
}

/*
	A disabled light in front of a casts_shadow one shifts where the survivor
	lands in the uploaded list -- caster_indices must follow that shift
	rather than naming a position in the original slice, since that is the
	index shadow_visibility (lighting_core.hlsli) actually looks up in the
	StructuredBuffer.
*/
@(test)
test_caster_index_follows_disabled_lights_being_dropped :: proc(t: ^testing.T) {
	defer set_lights({})

	off := create_point_light({0, 0, 0})
	off.enabled = false
	caster := create_directional_light({0, -1, 0}, casts_shadow = true)

	set_lights({off, caster})

	testing.expect(t, len(mbi.renderer.lighting.light_data) == 1,
		"only the enabled light should have been uploaded")
	testing.expect(t, mbi.renderer.lighting.shadow.caster_indices[0] == 0,
		"the caster's index should follow the dropped light shifting it to slot 0")
}

/*
	`pick_shadow_casters` on its own, with no GPU list involved. The lights, and
	what each should get:

		0 point, casts        the cube slot
		1 directional, casts  slot 0
		2 area rect, casts    nothing: area lights are never routed
		3 spot, casts         slot 1
		4 directional, casts  nothing: both slots taken
		5 point, casts        nothing: the one cube slot taken
		6 spot, does not ask  nothing
*/
@(test)
test_pick_shadow_casters_routes_by_kind_first_come :: proc(t: ^testing.T) {
	lights := []Light{
		create_point_light({0, 1, 0}, casts_shadow = true),
		create_directional_light({0, -1, 0}, casts_shadow = true),
		create_area_rect_light({0, 3, 0}, {0, -1, 0}, {1, 0, 0}, 1, 1),
		create_spot_light({0, 5, 0}, {0, -1, 0}, casts_shadow = true),
		create_directional_light({1, -1, 0}, casts_shadow = true),
		create_point_light({2, 1, 0}, casts_shadow = true),
		create_spot_light({0, 5, 2}, {0, -1, 0}),
	}
	lights[2].casts_shadow = true

	casters := pick_shadow_casters(lights)

	testing.expect_value(t, casters.slots, [MAX_SHADOW_CASTERS]int{1, 3})
	testing.expect_value(t, casters.cube, [MAX_POINT_SHADOW_CASTERS]int{0})

	want := [7]bool{true, true, false, true, false, false, false}
	for w, i in want {
		testing.expectf(t, is_shadow_caster(casters, i) == w, "light %d: is_shadow_caster should be %v", i, w)
	}
}

// A disabled light takes no slot, and a free slot's -1 is not a light.
@(test)
test_pick_shadow_casters_skips_disabled_lights :: proc(t: ^testing.T) {
	off := create_directional_light({0, -1, 0}, casts_shadow = true)
	off.enabled = false
	on := create_spot_light({0, 5, 0}, {0, -1, 0}, casts_shadow = true)

	casters := pick_shadow_casters({off, on})

	testing.expect_value(t, casters.slots, [MAX_SHADOW_CASTERS]int{1, -1})
	testing.expect_value(t, casters.cube, [MAX_POINT_SHADOW_CASTERS]int{-1})
	testing.expect(t, !is_shadow_caster(casters, 0), "the disabled light should not be a caster")
	testing.expect(t, !is_shadow_caster(casters, -1), "-1 marks a free slot, not a light")
}
