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
	// then the four scene rows, in mbsc's LIGHT_SCENE_NAMES order, the last thing in the block
	testing.expect_value(t, offset_of(Lights_Block, ground), 16 + 5 * MAX_PC_LIGHTS * 16 + 16)
	testing.expect_value(t, offset_of(Lights_Block, shadow_parameters) + 16, size_of(Lights_Block))
}

// The scene's settings reach the block as the shader reads them: a zero Lighting_Settings means "as before", and each setting is worked by hand
@(test)
scene_settings_reach_the_block :: proc(t:^testing.T) {
	view := calculate_camera_view_matrix({position = {0, 0, 5}, target = {0, 0, 0}, up = {0, 1, 0}})

	plain := calculate_lights_block({settings = {enabled = true}}, view)
	testing.expect_value(t, plain.up.w, 0) // no hemisphere
	testing.expect_value(t, plain.fog_color.w, 0) // no fog
	testing.expect_value(t, plain.fog_range.z, 1) // an exposure of 0 is read as 1
	testing.expect_value(t, plain.fog_range.w, 0) // no tonemap

	lighting := Lighting_State{settings = {
		enabled = true,
		hemisphere = true,
		ambient_ground = {0.1, 0.2, 0.3, 1},
		fog = {enabled = true, color = {0.5, 0.6, 0.7, 1}, start = 10, end = 50},
		exposure = 2,
		tonemap = .AGX,
	}}
	block := calculate_lights_block(lighting, view)
	testing.expect_value(t, block.ground, [4]f32{0.1, 0.2, 0.3, 1})
	testing.expect_value(t, block.up, [4]f32{0, 1, 0, 1}) // looking along -Z, the world's up is the eye's up
	testing.expect_value(t, block.fog_color, [4]f32{0.5, 0.6, 0.7, 1})
	testing.expect_value(t, block.fog_range, [4]f32{10, 1.0 / 40.0, 2, 3})

	// Turned to look along +X, the world's up is still the eye's up, and a sideways look does not move it
	sideways := calculate_lights_block(lighting, calculate_camera_view_matrix({position = {5, 0, 0}, target = {0, 0, 0}, up = {0, 1, 0}}))
	testing.expect_value(t, sideways.up, [4]f32{0, 1, 0, 1})

	// Looking straight down, up in the world is toward the camera's back: -Z of the eye
	down := calculate_lights_block(lighting, calculate_camera_view_matrix({position = {0, 5, 0}, target = {0, 0, 0}, up = {0, 0, -1}}))
	testing.expect(t, abs(down.up.z - 1) < 1e-5 && abs(down.up.y) < 1e-5, "looking down, the world's up points back at the eye")
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

// An area light reaches the block as PC's shader reads it: the centre with its kind, the facing (not reversed) with the half height, the right vector with the half width
@(test)
area_lights_reach_the_block_facing_outwards :: proc(t:^testing.T) {
	lighting:Lighting_State
	lighting.lights[0] = create_area_rect_light({1, 2, 3}, {0, -1, 0}, {1, 0, 0}, 4, 2) // half sizes 2 and 1
	lighting.lights[1] = create_area_disk_light({0, 0, 0}, {0, 0, -1}, 1.5)
	lighting.light_count = 2
	block := calculate_lights_block(lighting, calculate_camera_view_matrix({position = {0, 0, 5}, target = {0, 0, 0}, up = {0, 1, 0}}))

	// the camera looks along -Z from z = 5, so eye space is world space moved 5 toward -Z
	testing.expect_value(t, block.position[0], [4]f32{1, 2, -2, 3})
	testing.expect_value(t, block.direction[0], [4]f32{0, -1, 0, 1})
	testing.expect_value(t, block.cone[0], [4]f32{1, 0, 0, 2})
	testing.expect_value(t, block.position[1], [4]f32{0, 0, -5, 4})
	testing.expect_value(t, block.direction[1].xyz, [3]f32{0, 0, -1})
	testing.expect_value(t, block.direction[1].w, 0)
	testing.expect_value(t, block.cone[1].w, 1.5)
	// the disk's right is at right angles to its facing, and unit length
	right := block.cone[1].xyz
	testing.expect(t, abs(right.x * right.x + right.y * right.y + right.z * right.z - 1) < 1e-5 && abs(right.z) < 1e-5, "a disk's right vector is a unit vector across its face")
}
