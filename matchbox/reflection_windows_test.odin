#+build windows

package matchbox

import "core:slice"
import "core:testing"

// The reflection file is read as text and the game's values are written into a plain byte slice, so none of this
// needs a window or a GPU.

// The mesh shader's own reflection file, and one from tools/mbsc made with every kind of game uniform
MESH_REFLECTION :: #load("shaders/mesh.pc.refl", string)
UNIFORMS_REFLECTION :: #load("../tools/mbsc/testdata/uniforms_pc.refl", string)

read_f32 :: proc(block:[]byte, offset:int) -> f32 {
	return (cast(^f32)&block[offset])^
}

read_u32 :: proc(block:[]byte, offset:int) -> u32 {
	return (cast(^u32)&block[offset])^
}

@(test)
the_mesh_reflection_matches_the_engines_structs :: proc(t:^testing.T) {
	reflection, ok, message := parse_reflection(MESH_REFLECTION)
	defer destroy_reflection(&reflection)
	testing.expectf(t, ok, "%s", message)

	testing.expect_value(t, check_engine_blocks(&reflection), "")
	testing.expect_value(t, reflection.blocks[.FRAME], Reflected_Block{present = true, register = 0, size = size_of(Frame_Constants)})
	testing.expect_value(t, reflection.blocks[.RENDER], Reflected_Block{present = true, register = 1, size = size_of(Render_Constants)})
	testing.expect_value(t, reflection.blocks[.GAME].present, false)
	testing.expect_value(t, len(reflection.textures), 1)
	testing.expect_value(t, reflection.textures[0], Reflected_Texture{name = "tex", slot = 0})
	testing.expect_value(t, reflection.sampler, 0)
	testing.expect(t, reflection.has_sampler)
}

@(test)
every_attribute_the_mesh_shader_reads_is_in_a_vertex :: proc(t:^testing.T) {
	reflection, ok, message := parse_reflection(MESH_REFLECTION)
	defer destroy_reflection(&reflection)
	testing.expectf(t, ok, "%s", message)

	testing.expect_value(t, len(reflection.attributes), 3)
	for attribute in reflection.attributes {
		_, problem := find_vertex_attribute(attribute, false)
		testing.expect_value(t, problem, "")
	}
	// the offsets are the ones of Vertex, not numbers written down twice
	position, _ := find_vertex_attribute(reflection.attributes[0], false)
	uv, _ := find_vertex_attribute(reflection.attributes[1], false)
	color, _ := find_vertex_attribute(reflection.attributes[2], false)
	testing.expect_value(t, position.offset, u32(offset_of(Vertex, position)))
	testing.expect_value(t, uv.offset, u32(offset_of(Vertex, uv)))
	testing.expect_value(t, color.offset, u32(offset_of(Vertex, color)))
}

@(test)
an_attribute_the_vertices_lack_is_named_in_the_message :: proc(t:^testing.T) {
	// a plain Vertex has no normal: a shader drawing those meshes that read one would read into the next vertex
	_, message := find_vertex_attribute({name = "normal", type = "[3]f32"}, false)
	testing.expect(t, len(message) > 0)
	_, message = find_vertex_attribute({name = "texcoord", type = "[3]f32"}, false)
	testing.expect(t, len(message) > 0)
	_, message = find_vertex_attribute({name = "tangent", type = "[4]f32"}, true)
	testing.expect(t, len(message) > 0)
}

// The lit shader's reflection agrees with the engine: the lights block where mbsc put it and as big as Lights_Block,
// and the normal found in a Lit_Vertex at the offset Lit_Vertex has, not one written down twice
@(test)
the_lit_mesh_reflection_matches_the_engines_structs :: proc(t:^testing.T) {
	reflection, ok, message := parse_reflection(#load("shaders/mesh_lit.pc.refl", string))
	defer destroy_reflection(&reflection)
	testing.expectf(t, ok, "%s", message)

	testing.expect_value(t, check_engine_blocks(&reflection), "")
	testing.expect_value(t, reflection.blocks[.LIGHTS], Reflected_Block{present = true, register = 3, size = size_of(Lights_Block)})
	testing.expect_value(t, reflection.blocks[.FRAME].size, size_of(Frame_Constants))
	testing.expect_value(t, len(reflection.attributes), 4)
	for attribute in reflection.attributes {
		_, problem := find_vertex_attribute(attribute, true)
		testing.expect_value(t, problem, "")
	}
	normal, _ := find_vertex_attribute(reflection.attributes[3], true)
	testing.expect_value(t, normal.offset, u32(offset_of(Lit_Vertex, normal)))
}

@(test)
a_shader_built_for_other_structs_is_refused :: proc(t:^testing.T) {
	reflection, ok, _ := parse_reflection("mbs-reflection 1\ntarget pc\n\nblock frame 0 64\nvalue frame view_projection matrix[4,4]f32 0 64 0 0\n")
	defer destroy_reflection(&reflection)
	testing.expect(t, ok)
	testing.expect(t, len(check_engine_blocks(&reflection)) > 0)

	reflection2, ok2, _ := parse_reflection("mbs-reflection 1\ntarget pc\n\nblock frame 0 80\nvalue frame time f32 60 4 0 0\n")
	defer destroy_reflection(&reflection2)
	testing.expect(t, ok2)
	testing.expect(t, len(check_engine_blocks(&reflection2)) > 0)
}

@(test)
a_bad_reflection_file_says_which_line :: proc(t:^testing.T) {
	_, ok, message := parse_reflection("mbs-reflection 9\n")
	testing.expect(t, ok == false)
	testing.expect(t, len(message) > 0)

	_, ok, message = parse_reflection("mbs-reflection 1\nblock frame zero 80\n")
	testing.expect(t, ok == false)
	testing.expect(t, len(message) > 0)

	_, ok, message = parse_reflection("")
	testing.expect(t, ok == false)
}

@(test)
game_values_land_where_the_reflection_says :: proc(t:^testing.T) {
	reflection, ok, message := parse_reflection(UNIFORMS_REFLECTION)
	defer destroy_reflection(&reflection)
	testing.expectf(t, ok, "%s", message)
	testing.expect_value(t, check_engine_blocks(&reflection), "")

	block := make([]byte, reflection.blocks[.GAME].size)
	defer delete(block)

	set :: proc(t:^testing.T, reflection:^Shader_Reflection, block:[]byte, name:string, value:any) {
		ok, message := write_shader_value(reflection, block, name, value)
		testing.expectf(t, ok, "%s: %s", name, message)
	}

	// scalars, with a plain literal for each
	set(t, &reflection, block, "flash", 0.5)
	set(t, &reflection, block, "count", 7)
	set(t, &reflection, block, "enabled", true)
	testing.expect_value(t, read_f32(block, 0), 0.5)
	testing.expect_value(t, read_u32(block, 64), 7)
	testing.expect_value(t, read_u32(block, 68), 1)

	// a vector sits in the 12 bytes after `flash`, and `amount` is the next register
	set(t, &reflection, block, "offset", [3]f32{1, 2, 3})
	set(t, &reflection, block, "amount", f32(9))
	testing.expect_value(t, read_f32(block, 4), 1)
	testing.expect_value(t, read_f32(block, 12), 3)
	testing.expect_value(t, read_f32(block, 16), 9)

	// a matrix goes in by columns, 16 bytes apart: m[row, column] is at column * 16 + row * 4
	rotation := matrix[3, 3]f32{
		1, 2, 3,
		4, 5, 6,
		7, 8, 9,
	}
	set(t, &reflection, block, "rotation", rotation)
	testing.expect_value(t, read_f32(block, 96), 1) // [0, 0]
	testing.expect_value(t, read_f32(block, 100), 4) // [1, 0]
	testing.expect_value(t, read_f32(block, 112), 2) // [0, 1]
	testing.expect_value(t, read_f32(block, 96 + 32 + 8), 9) // [2, 2]

	// arrays: numbers sit 16 bytes apart, and every element must be there
	set(t, &reflection, block, "weights", []f32{1, 2, 3, 4, 5})
	for index in 0..<5 {
		testing.expect_value(t, read_f32(block, 288 + index * 16), f32(index + 1))
	}
	set(t, &reflection, block, "palette", [4][4]f32{{1, 1, 1, 1}, {2, 2, 2, 2}, {3, 3, 3, 3}, {4, 4, 4, 4}})
	testing.expect_value(t, read_f32(block, 416 + 2 * 16 + 4), 3)

	// fields of structs, and of the elements of an array of structs
	set(t, &reflection, block, "key_light.strength", 0.75)
	set(t, &reflection, block, "lights[1].strength", 2.5)
	set(t, &reflection, block, "lights[1].color", [3]f32{0.1, 0.2, 0.3})
	testing.expect_value(t, read_f32(block, 620), 0.75)
	testing.expect_value(t, read_f32(block, 748), 2.5)
	testing.expect_value(t, read_f32(block, 752 + 8), 0.3)
}

@(test)
a_wrong_value_is_refused_with_a_reason :: proc(t:^testing.T) {
	reflection, parsed, _ := parse_reflection(UNIFORMS_REFLECTION)
	defer destroy_reflection(&reflection)
	testing.expect(t, parsed)
	block := make([]byte, reflection.blocks[.GAME].size)
	defer delete(block)
	before := slice.clone(block)
	defer delete(before)

	ok, message := write_shader_value(&reflection, block, "no_such_uniform", 1.0)
	testing.expect(t, ok == false)
	testing.expect(t, len(message) > 0)

	// a [2]f32 isn't a [3]f32, and a bool isn't an f32
	ok, message = write_shader_value(&reflection, block, "offset", [2]f32{1, 2})
	testing.expect(t, ok == false)
	ok, message = write_shader_value(&reflection, block, "flash", true)
	testing.expect(t, ok == false)

	// an array needs all its elements
	ok, message = write_shader_value(&reflection, block, "weights", []f32{1, 2, 3})
	testing.expect(t, ok == false)
	ok, message = write_shader_value(&reflection, block, "weights", 1.0)
	testing.expect(t, ok == false)

	// a refused value changes nothing
	testing.expect(t, slice.equal(block, before))
}
