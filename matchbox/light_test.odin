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
	u := light_uniform(light)

	testing.expect(t, u.target.w == 2, "a spotlight must pack as kind 2")
	testing.expect(t, u.cone.x == 25, "cone.x should be the outer angle")
	testing.expect(t, u.cone.y == 15, "cone.y should be the inner angle")

	testing.expect(t, u.target.x == 0 && u.target.y == -1 && u.target.z == 0,
		"target should carry the spotlight's direction, not its position")
}

@(test)
test_directional_and_point_still_pack_as_before :: proc(t: ^testing.T) {
	d := light_uniform(create_directional_light({1, 0, 0}))
	testing.expect(t, d.target.w == 0, "a directional light must still pack as kind 0")

	p := light_uniform(create_point_light({0, 0, 0}))
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
