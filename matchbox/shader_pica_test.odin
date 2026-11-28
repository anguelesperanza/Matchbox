#+build windows

package matchbox

import "core:testing"

// What mbsc wrote for games/shaders/shield (`-target:3ds --emit-reflection`), kept as it came out: three game vec4s among the engine's
SHIELD_REFLECTION :: `mbs-reflection 1
target 3ds

attribute position [3]f32 0
attribute texcoord [2]f32 1
attribute color [4]f32 2
attribute normal [3]f32 3

uniform render_model matrix[4,4]f32 4
uniform hit_a [4]f32 1
uniform hit_b [4]f32 1
uniform hit_c [4]f32 1
uniform frame_view_projection matrix[4,4]f32 4
uniform frame_view matrix[4,4]f32 4
uniform render_tint [4]f32 1
`

// Made up, to reach the cases the 13 test shaders do not: a scalar, a vec2, a matrix and a bool
MIXED_REFLECTION :: `mbs-reflection 1
target 3ds

attribute position [3]f32 0

uniform progress f32 1
uniform scroll [2]f32 1
uniform tilt matrix[4,4]f32 4
uniform render_tint [4]f32 1
bool enabled
`

@(test)
reads_the_attributes_and_uniforms_of_a_real_reflection :: proc(t: ^testing.T) {
	reflection, ok, message := parse_pica_reflection(SHIELD_REFLECTION)
	defer destroy_pica_reflection(&reflection)
	testing.expect(t, ok, message)
	testing.expect_value(t, len(reflection.attributes), 4)
	testing.expect_value(t, len(reflection.uniforms), 7)
	testing.expect_value(t, reflection.attributes[3].name, "normal")
	testing.expect_value(t, reflection.attributes[3].index, 3)
	testing.expect_value(t, reflection.uniforms[0].name, "render_model")
	testing.expect_value(t, reflection.uniforms[0].registers, 4)
	testing.expect(t, pica_reads_normal(&reflection))
}

@(test)
a_reflection_without_a_normal_does_not_read_one :: proc(t: ^testing.T) {
	reflection, ok, message := parse_pica_reflection(MIXED_REFLECTION)
	defer destroy_pica_reflection(&reflection)
	testing.expect(t, ok, message)
	testing.expect(t, pica_reads_normal(&reflection) == false)
}

@(test)
a_reflection_it_cannot_read_is_an_error_with_a_line :: proc(t: ^testing.T) {
	bad := []string {
		"target 3ds\n",                                                  // no header
		"mbs-reflection 1\n",                                            // no target
		"mbs-reflection 2\ntarget 3ds\n",                                // a version it does not know
		"mbs-reflection 1\ntarget pc\n",                                 // another target's
		"mbs-reflection 1\ntarget 3ds\nuniform x f32\n",                 // a word short
		"mbs-reflection 1\ntarget 3ds\nuniform x f32 zero\n",            // a register count that is not a number
		"mbs-reflection 1\ntarget 3ds\nuniform x f32 0\n",               // takes no register
		"mbs-reflection 1\ntarget 3ds\nattribute a [3]f32\n",            // a word short
		"mbs-reflection 1\ntarget 3ds\nsampler s 0\n",                   // a line it does not know: never skipped
	}
	for text, index in bad {
		reflection, ok, message := parse_pica_reflection(text)
		testing.expectf(t, ok == false, "case %d was accepted", index)
		testing.expectf(t, message != "", "case %d gave no message", index)
		destroy_pica_reflection(&reflection)
	}
}

@(test)
the_engines_uniforms_are_told_from_the_games :: proc(t: ^testing.T) {
	testing.expect(t, is_engine_uniform("render_model"))
	testing.expect(t, is_engine_uniform("frame_time"))
	testing.expect(t, is_engine_uniform("lights_ambient"))
	testing.expect(t, is_engine_uniform("skin_row0"))
	testing.expect(t, is_engine_uniform("hit_a") == false)
	testing.expect(t, is_engine_uniform("progress") == false)
}

@(test)
a_games_uniforms_get_registers_and_the_engines_do_not :: proc(t: ^testing.T) {
	reflection, _, _ := parse_pica_reflection(SHIELD_REFLECTION)
	defer destroy_pica_reflection(&reflection)
	game := create_pica_game_uniforms(&reflection)
	defer destroy_pica_game_uniforms(&game)

	testing.expect_value(t, len(game.entries), 3)
	testing.expect_value(t, len(game.registers), 3)
	testing.expect_value(t, game.entries[0].name, "hit_a")
	testing.expect_value(t, game.entries[1].first, 1)
	testing.expect_value(t, game.entries[2].first, 2)
	testing.expect_value(t, game.entries[0].location, -1)
}

@(test)
packs_scalars_vectors_matrices_and_bools :: proc(t: ^testing.T) {
	reflection, _, _ := parse_pica_reflection(MIXED_REFLECTION)
	defer destroy_pica_reflection(&reflection)
	game := create_pica_game_uniforms(&reflection)
	defer destroy_pica_game_uniforms(&game)

	// progress, scroll and a 4-row tilt: 1 + 1 + 4 registers; render_tint is the engine's
	testing.expect_value(t, len(game.registers), 6)

	ok, message := set_pica_game_value(&game, "progress", 0.25) // a plain literal is an f64
	testing.expect(t, ok, message)
	testing.expect_value(t, game.registers[0], [4]f32{0.25, 0, 0, 0})

	ok, message = set_pica_game_value(&game, "scroll", [2]f32{3, 4})
	testing.expect(t, ok, message)
	testing.expect_value(t, game.registers[1], [4]f32{3, 4, 0, 0})

	// Row r of the matrix is register r, as the engine's own matrices are uploaded
	tilt := matrix[4, 4]f32{
		1, 2, 3, 4,
		5, 6, 7, 8,
		9, 10, 11, 12,
		13, 14, 15, 16,
	}
	ok, message = set_pica_game_value(&game, "tilt", tilt)
	testing.expect(t, ok, message)
	testing.expect_value(t, game.registers[2], [4]f32{1, 2, 3, 4})
	testing.expect_value(t, game.registers[5], [4]f32{13, 14, 15, 16})

	ok, message = set_pica_game_value(&game, "enabled", true)
	testing.expect(t, ok, message)
	testing.expect_value(t, game.flags[0], true)
}

@(test)
a_refused_value_leaves_the_old_one_in_place :: proc(t: ^testing.T) {
	reflection, _, _ := parse_pica_reflection(MIXED_REFLECTION)
	defer destroy_pica_reflection(&reflection)
	game := create_pica_game_uniforms(&reflection)
	defer destroy_pica_game_uniforms(&game)

	set_pica_game_value(&game, "scroll", [2]f32{3, 4})
	ok, _ := set_pica_game_value(&game, "scroll", [3]f32{7, 8, 9})
	testing.expect(t, ok == false)
	testing.expect_value(t, game.registers[1], [4]f32{3, 4, 0, 0})
	// and a new one replaces it whole
	set_pica_game_value(&game, "scroll", [2]f32{5, 6})
	testing.expect_value(t, game.registers[1], [4]f32{5, 6, 0, 0})
}

@(test)
a_wrong_name_or_type_is_refused_and_changes_nothing :: proc(t: ^testing.T) {
	reflection, _, _ := parse_pica_reflection(MIXED_REFLECTION)
	defer destroy_pica_reflection(&reflection)
	game := create_pica_game_uniforms(&reflection)
	defer destroy_pica_game_uniforms(&game)
	game.dirty = false

	ok, message := set_pica_game_value(&game, "nothing", 1.0)
	testing.expect(t, ok == false)
	testing.expect(t, message != "")
	// A [3]f32 into a [2]f32, a bool into an f32, and a float into a bool
	ok, _ = set_pica_game_value(&game, "scroll", [3]f32{1, 2, 3})
	testing.expect(t, ok == false)
	ok, _ = set_pica_game_value(&game, "progress", true)
	testing.expect(t, ok == false)
	ok, _ = set_pica_game_value(&game, "enabled", 1.0)
	testing.expect(t, ok == false)
	// The engine's uniforms are not the game's to set
	ok, _ = set_pica_game_value(&game, "render_tint", [4]f32{1, 1, 1, 1})
	testing.expect(t, ok == false)

	testing.expect(t, game.dirty == false)
	testing.expect_value(t, game.registers[0], [4]f32{})
}

@(test)
a_shader_draws_only_the_meshes_it_has_a_variant_for :: proc(t: ^testing.T) {
	plain := Shader_Facts{has_plain = true}
	testing.expect_value(t, choose_shader_variant(plain, false, false), Shader_Variant.PLAIN)
	testing.expect_value(t, choose_shader_variant(plain, false, true), Shader_Variant.PLAIN)
	// A skinned mesh with no _skinned variant is the built-in's, not drawn in its bind pose
	testing.expect_value(t, choose_shader_variant(plain, true, true), Shader_Variant.NONE)

	both := Shader_Facts{has_plain = true, has_skinned = true}
	testing.expect_value(t, choose_shader_variant(both, true, true), Shader_Variant.SKINNED)

	// One that reads the normal cannot draw a mesh that has none
	lit_only := Shader_Facts{has_plain = true, reads_normal = true}
	testing.expect_value(t, choose_shader_variant(lit_only, false, false), Shader_Variant.NONE)
	testing.expect_value(t, choose_shader_variant(lit_only, false, true), Shader_Variant.PLAIN)

	nothing := Shader_Facts{}
	testing.expect_value(t, choose_shader_variant(nothing, false, true), Shader_Variant.NONE)
}
