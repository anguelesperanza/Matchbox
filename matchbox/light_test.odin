package matchbox

/*
	Light packing -- the arithmetic
	--------------------------------
	`light_uniform` is the one place a `Light` becomes the bytes the shader
	actually reads, and its failures are quiet in the same way the shadow
	matrix's alignment gap was: a wrong number here is wrong lighting, not a
	crash. No GPU is needed -- it is a pure conversion.
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
