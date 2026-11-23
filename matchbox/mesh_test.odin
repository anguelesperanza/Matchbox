#+build windows

package matchbox

import "core:testing"

@(test)
mesh_cube_colored_false_is_white_so_a_texture_shows_as_it_is :: proc(t:^testing.T) {
	// colored = false used to be worked out and then ignored, so a textured cube came out
	// tinted by the six face colours
	vertices, indices := mesh_cube(colored = false)
	defer delete(vertices)
	defer delete(indices)
	for vertex in vertices {
		testing.expect_value(t, vertex.color, [4]f32{1, 1, 1, 1})
	}
}

@(test)
mesh_cube_colored_gives_each_face_its_own_colour :: proc(t:^testing.T) {
	vertices, indices := mesh_cube()
	defer delete(vertices)
	defer delete(indices)
	// Four corners a face, all the face's colour; the first two faces differ
	for face in 0 ..< 6 {
		for corner in 1 ..< 4 {
			testing.expect_value(t, vertices[face * 4 + corner].color, vertices[face * 4].color)
		}
	}
	testing.expect(t, vertices[0].color != vertices[4].color)
	testing.expect(t, vertices[0].color != [4]f32{1, 1, 1, 1})
}
