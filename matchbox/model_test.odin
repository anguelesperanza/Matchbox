#+build windows

package matchbox

import "core:math"
import "core:math/linalg"
import "core:testing"

/*
	Every triangle of a convex shape centred on the origin faces away from the centre, and the
	signed volume of the whole is the shape's volume. A triangle wound the wrong way would show
	as a negative contribution: culled on every target, a hole in the model. Each corner's
	normal is unit length and on the side the triangle faces, so the lit side is the outside
*/
@(private = "file")
expect_wound_outward :: proc(t:^testing.T, name:string, vertices:[]Lit_Vertex, indices:[]u16, expected_volume, tolerance:f32) {
	volume:f32
	for i := 0; i < len(indices); i += 3 {
		a := vertices[indices[i]].position
		b := vertices[indices[i + 1]].position
		c := vertices[indices[i + 2]].position
		normal := linalg.cross(b - a, c - a)
		volume += linalg.dot(a, linalg.cross(b, c)) / 6
		if linalg.length(normal) < 1e-6 do continue // a sphere's pole: no area, no direction
		centre := (a + b + c) / 3
		testing.expectf(t, linalg.dot(normal, centre) > 0, "%s: triangle %v faces inward", name, i / 3)
		for corner in 0 ..< 3 {
			vertex_normal := vertices[indices[i + corner]].normal
			testing.expectf(t, abs(linalg.length(vertex_normal) - 1) < 1e-5, "%s: a normal of length %v", name, linalg.length(vertex_normal))
			testing.expectf(t, linalg.dot(vertex_normal, normal) > 0, "%s: triangle %v has a normal pointing in", name, i / 3)
		}
	}
	testing.expectf(t, abs(volume - expected_volume) < tolerance, "%s: volume %v, expected about %v", name, volume, expected_volume)
}

@(test)
generated_shapes_are_wound_counter_clockwise_from_outside :: proc(t:^testing.T) {
	cube_vertices, cube_indices := mesh_cube(2, colored = false, allocator = context.temp_allocator)
	expect_wound_outward(t, "cube", cube_vertices, cube_indices, 8, 1e-4)

	// A 16 x 24 sphere is a little smaller than the round one
	sphere_vertices, sphere_indices := mesh_sphere(1, 16, 24, context.temp_allocator)
	expect_wound_outward(t, "sphere", sphere_vertices, sphere_indices, 4.0 / 3.0 * math.PI, 0.15)

	// A 24-sided prism holds 12 * sin(15 degrees) / pi of the round cylinder's volume
	cylinder_vertices, cylinder_indices := mesh_cylinder(0.5, 1, 24, context.temp_allocator)
	round:f32 = math.PI * 0.25
	expect_wound_outward(t, "cylinder", cylinder_vertices, cylinder_indices, round * 12 * math.sin(f32(math.PI) / 12) / math.PI, 1e-3)
	free_all(context.temp_allocator)
}

@(test)
the_plane_faces_up :: proc(t:^testing.T) {
	vertices, indices := mesh_plane(4, context.temp_allocator)
	for i := 0; i < len(indices); i += 3 {
		a := vertices[indices[i]].position
		b := vertices[indices[i + 1]].position
		c := vertices[indices[i + 2]].position
		testing.expect(t, linalg.cross(b - a, c - a).y > 0)
	}
	for vertex in vertices do testing.expect_value(t, vertex.normal, [3]f32{0, 1, 0})
	minimum, maximum := calculate_vertex_bounds(vertices)
	testing.expect_value(t, minimum, [3]f32{-2, 0, -2})
	testing.expect_value(t, maximum, [3]f32{2, 0, 2})
	free_all(context.temp_allocator)
}

@(test)
a_pivoted_transform_puts_the_pivot_on_the_position :: proc(t:^testing.T) {
	pivot := [3]f32{0.2, 1.4, -0.3}
	transform := create_transform({5, -2, 7}, calculate_rotation_axis_angle({0, 1, 0}, 1.1), 2)
	moved := calculate_transform_matrix(calculate_transform_pivoted(transform, pivot)) * [4]f32{pivot.x, pivot.y, pivot.z, 1}
	testing.expectf(t, linalg.length(moved.xyz - transform.position) < 1e-5, "the pivot went to %v, not %v", moved.xyz, transform.position)
}

@(test)
the_identity_transform_changes_nothing :: proc(t:^testing.T) {
	testing.expect_value(t, calculate_transform_matrix(create_transform()), linalg.MATRIX4F32_IDENTITY)
}

/*
	The glTF mapping at the values its comment promises: Blender's default material reads as
	the engine's default strength, a fully rough surface has no highlight, a mirror is kept to
	max_shininess, and metal shines twice as hard as plastic
*/
@(test)
a_gltf_roughness_becomes_a_highlight :: proc(t:^testing.T) {
	blender := calculate_material_from_roughness(0.5, 0)
	testing.expect_value(t, blender.shininess, 30)
	testing.expect_value(t, blender.specular_strength, mbi.model_settings.default_material.specular_strength)

	testing.expect_value(t, calculate_material_from_roughness(1, 1), Material{shininess = 1, specular_strength = 0})
	testing.expect_value(t, calculate_material_from_roughness(0, 0), Material{shininess = mbi.model_settings.max_shininess, specular_strength = 1})
	testing.expect_value(t, calculate_material_from_roughness(0.5, 1).specular_strength, 1)
	testing.expect_value(t, calculate_material_from_roughness(0.75, 0).specular_strength, 0.25)
	testing.expect_value(t, calculate_material_from_roughness(0.75, 1).specular_strength, 0.5)
}
