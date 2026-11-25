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
	testing.expect_value(t, front.direction[0], [4]f32{0, 2, 0, 0})
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

// The block is laid out as mbsc's HLSL declares it: ambient, three arrays of 64 rows, the count, padding to a full row
@(test)
the_lights_block_matches_the_hlsl_layout :: proc(t:^testing.T) {
	testing.expect_value(t, offset_of(Lights_Block, count), 16 + 3 * MAX_PC_LIGHTS * 16)
	testing.expect_value(t, size_of(Lights_Block) % 16, 0)
}
