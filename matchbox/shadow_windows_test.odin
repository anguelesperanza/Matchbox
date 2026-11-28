#+build windows

package matchbox

import "core:math/linalg"
import "core:testing"

// The matrix in the block takes an eye-space point to the caster's clip space: the middle of what a sun looks at lands in the middle of the map,
// half way through its depth (a box 2 * radius deep, centred on `center`), and a point `radius` off to the side lands on the map's edge.
@(test)
the_shadow_matrix_puts_the_centre_of_the_box_in_the_middle_of_the_map :: proc(t:^testing.T) {
	lighting:Lighting_State
	sun := create_directional_light({0, -1, 0})
	sun.casts_shadow = true
	lighting.lights[0] = create_point_light({0, 5, 0}) // not a caster, and first: the caster is the sun that asks, not the first light
	lighting.lights[1] = sun
	lighting.light_count = 2
	lighting.settings.shadow = {center = {1, 2, 3}, radius = 10}

	testing.expect_value(t, calculate_shadow_caster(lighting), 1)

	// A camera 5 units back along +Z looking down -Z: its view moves the world 5 units further from it
	view := linalg.matrix4_translate_f32({0, 0, -5})
	block := calculate_lights_block(lighting, view)
	testing.expect_value(t, block.shadow_parameters[0], 1)

	lookup :: proc(block:Lights_Block, eye_point:[3]f32) -> [4]f32 {
		p := [4]f32{eye_point.x, eye_point.y, eye_point.z, 1}
		return {linalg.dot(block.shadow_x, p), linalg.dot(block.shadow_y, p), linalg.dot(block.shadow_z, p), linalg.dot(block.shadow_w, p)}
	}
	middle := lookup(block, {1, 2, 3 - 5})
	close :: proc(a, b:f32) -> bool { return abs(a - b) < 1e-4 }
	testing.expectf(t, close(middle.x / middle.w, 0) && close(middle.y / middle.w, 0) && close(middle.z / middle.w, 0.5), "middle: %v", middle)

	// 5 units to the world's +X of it: a quarter of the way along the 20 wide box (a down-looking sun keeps +X to its right)
	side := lookup(block, {1 + 5, 2, 3 - 5})
	testing.expectf(t, close(abs(side.x / side.w), 0.5), "side: %v", side)
	// Deeper than the box: past the far plane
	deep := lookup(block, {1, 2 - 11, 3 - 5})
	testing.expectf(t, deep.z / deep.w > 1, "deep: %v", deep)

	// No caster: the slot is -1, which the shader reads as "no shadow here"
	lighting.lights[1].casts_shadow = false
	testing.expect_value(t, calculate_lights_block(lighting, view).shadow_parameters[0], -1)
}
