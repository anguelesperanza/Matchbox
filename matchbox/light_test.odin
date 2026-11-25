#+build windows

package matchbox

import "core:testing"

/*
	A light's direction reaches the shaders reversed and in eye space, with the camera's position
	left out. The expected values are worked by hand from where each camera stands, not from the
	view matrix, so they check calculate_lights_block rather than repeat it.
*/
@(test)
lights_reach_the_block_towards_the_light_in_eye_space :: proc(t:^testing.T) {
	lighting:Lighting_State
	lighting.settings = {enabled = true, ambient = {0.1, 0.2, 0.3, 1}}
	lighting.lights[0] = create_directional_light({0, -2, 0}) // straight down, not unit length
	lighting.lights[1] = create_directional_light({0, 0, 1}, {1, 0, 0, 1})
	lighting.light_count = 2

	// Looking down -Z from z = 5: eye space is world space moved, so only the reversal shows,
	// and the 5 units of translation must not leak into a direction
	front := calculate_lights_block(lighting, calculate_camera_view_matrix({position = {0, 0, 5}, target = {0, 0, 0}, up = {0, 1, 0}}))
	testing.expect_value(t, front.ambient, [4]f32{0.1, 0.2, 0.3, 1})
	testing.expect_value(t, front.count, 2)
	testing.expect_value(t, front.direction[0], [4]f32{0, 1, 0, 0}) // unit length: the engine normalizes so the shaders needn't
	testing.expect_value(t, front.direction[1], [4]f32{0, 0, -1, 0})
	testing.expect_value(t, front.diffuse[1], [4]f32{1, 0, 0, 1})
	testing.expect_value(t, front.specular[1], [4]f32{1, 0, 0, 1})

	// Standing at x = 5 looking at the origin: the eye's right is world -Z. The second light shines
	// along +Z, so it is towards world -Z, on the eye's right
	side := calculate_lights_block(lighting, calculate_camera_view_matrix({position = {5, 0, 0}, target = {0, 0, 0}, up = {0, 1, 0}}))
	want := [4]f32{1, 0, 0, 0}
	for lane in 0 ..< 4 {
		testing.expectf(t, abs(side.direction[1][lane] - want[lane]) < 1e-6, "eye direction %v, want %v", side.direction[1], want)
	}

	// Unused slots stay zero colour and zero direction, which the shaders read as no light
	for slot in 2 ..< MAX_PC_LIGHTS {
		testing.expect_value(t, side.direction[slot], [4]f32{})
		testing.expect_value(t, side.diffuse[slot], [4]f32{})
		testing.expect_value(t, side.specular[slot], [4]f32{})
	}
}

// Before a game calls set_lighting, lighting is off: models draw unlit, as they did before L4.
// This is the Windows build, so the limit is PC's
@(test)
lighting_starts_off :: proc(t:^testing.T) {
	testing.expect(t, !mbi.lighting.settings.enabled)
	testing.expect_value(t, get_max_lights(), MAX_PC_LIGHTS)
	testing.expect_value(t, MAX_LIGHTS, 8)
}

// The block is laid out as mbsc's HLSL declares it: ambient, five arrays of 64 rows, the count, padding to a full row
@(test)
the_lights_block_matches_the_hlsl_layout :: proc(t:^testing.T) {
	testing.expect_value(t, offset_of(Lights_Block, count), 16 + 5 * MAX_PC_LIGHTS * 16)
	testing.expect_value(t, size_of(Lights_Block) % 16, 0)
}

// A point light's place reaches the block in eye space with w = its kind, and a spot adds its axis and its cone's cosines; worked by hand from a camera at (0, 0, 5)
@(test)
point_and_spot_lights_reach_the_block_in_eye_space :: proc(t:^testing.T) {
	lighting:Lighting_State
	lighting.lights[0] = create_point_light({1, 2, 3})
	lighting.lights[1] = create_spot_light({0, 4, 0}, {0, -1, 0}, {0, 1, 0, 1}, 60, 90)
	lighting.light_count = 2
	// looking down -Z from z = 5: eye space is world space moved 5 units towards -Z, so the origin is at z = -5
	block := calculate_lights_block(lighting, calculate_camera_view_matrix({position = {0, 0, 5}, target = {0, 0, 0}, up = {0, 1, 0}}))
	testing.expect_value(t, block.position[0], [4]f32{1, 2, -2, 1})
	testing.expect_value(t, block.direction[0], [4]f32{})
	testing.expect_value(t, block.position[1], [4]f32{0, 4, -5, 2})
	testing.expect_value(t, block.direction[1], [4]f32{0, 1, 0, 0}) // back along the axis, like a sun's
	testing.expectf(t, abs(block.cone[1][0]) < 1e-6 && abs(block.cone[1][1] - 0.5) < 1e-6, "cone %v, want (cos 90, cos 60) = (0, 0.5)", block.cone[1])
	testing.expect_value(t, block.diffuse[1], [4]f32{0, 1, 0, 1})
	testing.expect_value(t, block.position[2], [4]f32{}) // an empty slot is kind 0 with nothing in it
}

// A material without a choice follows the scene, which starts per pixel; a material's own choice wins
@(test)
a_materials_lighting_mode_wins_over_the_scenes :: proc(t:^testing.T) {
	testing.expect_value(t, mbi.lighting.settings.mode, Lighting_Mode.PER_PIXEL)
	testing.expect_value(t, get_lighting_mode(Material{shininess = 16}), Lighting_Mode.PER_PIXEL)
	testing.expect_value(t, get_lighting_mode(Material{shininess = 16, lighting = .PER_VERTEX}), Lighting_Mode.PER_VERTEX)
	testing.expect_value(t, mbi.model_settings.default_material.lighting, nil)
}

// The Vita's per-pixel shader runs a loop per kind, so its block is put in the order suns, bulbs, spots (the game's order inside each kind)
@(test)
the_vita_block_sorts_lights_by_kind :: proc(t:^testing.T) {
	lighting:Lighting_State
	lighting.lights[0] = create_spot_light({0, 4, 0}, {0, -1, 0}, {0, 0, 1, 1})
	lighting.lights[1] = create_point_light({1, 0, 0}, {1, 0, 0, 1})
	lighting.lights[2] = create_directional_light({0, -1, 0}, {0, 1, 0, 1})
	lighting.lights[3] = create_point_light({2, 0, 0}, {1, 1, 0, 1})
	lighting.light_count = 4
	block := calculate_lights_block(lighting, calculate_camera_view_matrix({position = {0, 0, 5}, target = {0, 0, 0}, up = {0, 1, 0}}))
	sort_lights_block_by_kind(&block)
	testing.expect_value(t, block.sun_count, 1)
	testing.expect_value(t, block.point_count, 2)
	testing.expect_value(t, block.count, 4)
	kinds := [4]f32{block.position[0].w, block.position[1].w, block.position[2].w, block.position[3].w}
	testing.expect_value(t, kinds, [4]f32{0, 1, 1, 2})
	testing.expect_value(t, block.diffuse[0], [4]f32{0, 1, 0, 1}) // the sun
	testing.expect_value(t, block.diffuse[1], [4]f32{1, 0, 0, 1}) // the bulbs, in the game's order
	testing.expect_value(t, block.diffuse[2], [4]f32{1, 1, 0, 1})
	testing.expect_value(t, block.diffuse[3], [4]f32{0, 0, 1, 1}) // the spot, its cone with it
	testing.expect(t, block.cone[3][2] > 0)
	testing.expect_value(t, block.cone[0], [4]f32{})
}
