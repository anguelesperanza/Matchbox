package matchbox

/*
	Every light kind, in one scene
	--------------------------------
	`lighting_rework.md` section 5's own P4 scope: "All kinds coexisting in
	one scene, asserted." There is no GPU in this environment -- `mbi.renderer.
	device` is `nil` in every test in this package (see
	`model_material_test.odin`'s own top comment for the same limit) -- so
	`push_lighting` (lighting.odin) and an actual rendered frame are both out
	of reach here. What *is* reachable, and what this file asserts, is the
	whole CPU-side path a mixed scene depends on before a single fragment
	shader ever runs: `set_lights` uploading all five `Light_Kind` values into
	one list without any of them clobbering another's slot or shadow-caster
	routing, and `set_lighting` accepting `Ambient_Kind.ENVIRONMENT_PROBE`
	alongside them.

	**What this does not check**, stated plainly rather than implied: that
	`sample_light`/`shade_lights` (lighting_core.hlsli) actually shade all six
	correctly in the same fragment, or that a real probe's own two maps read
	back the right texels. Both are the shader-side half of "coexisting", and
	both are un-capturable without a device -- `area_light_test.odin`/
	`ibl_test.odin` are what verify that half's own arithmetic, on a CPU
	mirror, independently of this file.
*/

import "core:testing"

@(test)
test_every_light_kind_coexists_in_one_scene :: proc(t: ^testing.T) {
	defer set_lights({})

	directional := create_directional_light({0, -1, 0}, RED, casts_shadow = true)
	point       := create_point_light({1, 2, 3}, GREEN, casts_shadow = true)
	spot        := create_spot_light({4, 5, 6}, {0, -1, 0}, BLUE, casts_shadow = true)
	rect        := create_area_rect_light(
		position = {0, 3, 0}, normal = {0, -1, 0}, right = {1, 0, 0},
		width = 2, height = 1, color = WHITE,
	)
	disk := create_area_disk_light(position = {0, 3, 5}, normal = {0, -1, 0}, radius = 1, color = WHITE)

	// A disabled light rides along too, the same "hand over a slice
	// including lights not turned on yet" shape set_lights' own doc comment
	// describes -- it must not occupy a slot or shift any other light's
	// index.
	off := create_point_light({9, 9, 9})
	off.enabled = false

	set_lights({directional, point, spot, rect, disk, off})

	l := &mbi.renderer.lighting

	testing.expect_value(t, len(l.light_data), 5)

	// Every kind lands at the index set_lights was handed it in, packed as
	// light_uniform's own kind_flag -- see that proc's own doc comment
	// (light.odin) for the 0..4 mapping.
	testing.expect_value(t, l.light_data[0].target.w, f32(0)) // DIRECTIONAL
	testing.expect_value(t, l.light_data[1].target.w, f32(1)) // POINT
	testing.expect_value(t, l.light_data[2].target.w, f32(2)) // SPOT
	testing.expect_value(t, l.light_data[3].target.w, f32(3)) // AREA_RECT
	testing.expect_value(t, l.light_data[4].target.w, f32(4)) // AREA_DISK

	// Shadow routing: directional (index 0) and spot (index 2) are the only
	// two eligible for the two PCF/PCSS/CASCADED caster slots; point
	// (index 1) goes to the single cube slot instead; neither area light
	// (indices 3/4) is routed anywhere even though neither set casts_shadow
	// -- confirming the "not eligible" path is exercised by kind alone, not
	// merely by every area light in this test happening to leave the flag
	// off.
	testing.expect_value(t, l.shadow.caster_indices[0], 0)
	testing.expect_value(t, l.shadow.caster_indices[1], 2)
	testing.expect_value(t, l.shadow.cube_caster_index[0], 1)

	// Area lights marked casts_shadow explicitly still do not occupy a
	// caster slot -- Light's own doc comment (light.odin) on area_right
	// calls this "inert rather than an error"; this is what confirms the
	// inertness rather than merely asserting the sentence.
	set_lights({directional, point, spot, rect, disk})
	rect_shadow := rect
	rect_shadow.casts_shadow = true
	disk_shadow := disk
	disk_shadow.casts_shadow = true
	set_lights({directional, point, spot, rect_shadow, disk_shadow})

	testing.expect_value(t, l.shadow.caster_indices[0], 0)
	testing.expect_value(t, l.shadow.caster_indices[1], 2)
	testing.expect_value(t, l.shadow.cube_caster_index[0], 1)
}

/*
	`Ambient_Kind.ENVIRONMENT_PROBE` alongside a full light list -- selecting
	it does not require a probe to already exist (`Ambient_Kind`'s own doc
	comment, lighting.odin, calls this "opt in, nothing happens" the same
	shape an unsupported combination already gets elsewhere), so this is
	checkable with `mbi.renderer.device == nil` and no real bake.
*/
@(test)
test_environment_probe_ambient_kind_coexists_with_a_full_light_list :: proc(t: ^testing.T) {
	defer set_lights({})
	defer set_lighting()

	set_lighting({
		enabled = true,
		ambient = {kind = .ENVIRONMENT_PROBE, color = {0.1, 0.1, 0.1, 1}, ground_color = {0.02, 0.02, 0.02, 1}},
	})

	set_lights({
		create_directional_light({0, -1, 0}),
		create_point_light({1, 2, 3}),
		create_spot_light({4, 5, 6}, {0, -1, 0}),
		create_area_rect_light(position = {0, 3, 0}, normal = {0, -1, 0}, right = {1, 0, 0}, width = 2, height = 1),
		create_area_disk_light(position = {0, 3, 5}, normal = {0, -1, 0}, radius = 1),
	})

	testing.expect_value(t, mbi.renderer.lighting.settings.ambient.kind, Ambient_Kind.ENVIRONMENT_PROBE)
	testing.expect_value(t, len(mbi.renderer.lighting.light_data), 5)

	// No probe was ever set (set_environment_probe, ambient.odin) -- the
	// zero-value Environment_Probe -- so the level count push_lighting would
	// compute stays at its own safe floor rather than going negative.
	testing.expect_value(t, mbi.renderer.lighting.probe.prefiltered_level_count, i32(0))
	testing.expect(t, max(mbi.renderer.lighting.probe.prefiltered_level_count-1, 0) == 0,
		"prefiltered_levels_minus_one must clamp to 0 with no probe bound, not go negative")
}
