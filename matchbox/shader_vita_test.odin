#+build windows

package matchbox

import "core:testing"

// What mbsc wrote for games/shaders/shield (`-target:vita --emit-reflection`), kept as it came out: three game vec4s
SHIELD_VITA_REFLECTION :: `mbs-reflection 1
target vita

attribute position [3]f32
attribute texcoord [2]f32
attribute color [4]f32
attribute normal [3]f32

uniform frame_view_projection matrix[4,4]f32 0
uniform frame_time f32 0
uniform frame_view matrix[4,4]f32 0
uniform render_model matrix[4,4]f32 0
uniform render_tint [4]f32 0
uniform render_uv_rectangle [4]f32 0
uniform render_alpha_cutoff f32 0
uniform render_shininess f32 0
uniform render_specular_strength f32 0
uniform hit_a [4]f32 0
uniform hit_b [4]f32 0
uniform hit_c [4]f32 0
`

// games/shaders/crt, as it came out: no normal, a texture, scalars and a vec2 for the game
CRT_VITA_REFLECTION :: `mbs-reflection 1
target vita

attribute position [3]f32
attribute texcoord [2]f32
attribute color [4]f32

uniform frame_view_projection matrix[4,4]f32 0
uniform frame_time f32 0
uniform frame_view matrix[4,4]f32 0
uniform render_model matrix[4,4]f32 0
uniform render_tint [4]f32 0
uniform render_uv_rectangle [4]f32 0
uniform render_alpha_cutoff f32 0
uniform render_shininess f32 0
uniform render_specular_strength f32 0
uniform curvature f32 0
uniform aberration f32 0
uniform scanlines f32 0
uniform mask f32 0
uniform vignette f32 0
uniform line_count f32 0
uniform resolution [2]f32 0

texture tex 0
`

// games/shaders/snow, as it came out: lights_* are engine arrays (count 8) and must not become game uniforms
SNOW_VITA_REFLECTION :: `mbs-reflection 1
target vita

attribute position [3]f32
attribute texcoord [2]f32
attribute color [4]f32
attribute normal [3]f32

uniform frame_view_projection matrix[4,4]f32 0
uniform frame_time f32 0
uniform frame_view matrix[4,4]f32 0
uniform render_model matrix[4,4]f32 0
uniform render_tint [4]f32 0
uniform render_uv_rectangle [4]f32 0
uniform render_alpha_cutoff f32 0
uniform render_shininess f32 0
uniform render_specular_strength f32 0
uniform snow_amount f32 0
uniform snow_depth f32 0
uniform lights_ambient [4]f32 0
uniform lights_direction [4]f32 8
uniform lights_diffuse [4]f32 8
uniform lights_specular [4]f32 8
uniform lights_position [4]f32 8
uniform lights_cone [4]f32 8
`

// MADE UP, not mbsc output: none of the 13 test shaders has a game array or matrix, so this follows docs/shader_cg.md
// ("count is the length for an array") to reach them: a float array, a vec4 array, a mat4 and a mat3
ARRAYS_VITA_REFLECTION :: `mbs-reflection 1
target vita

attribute position [3]f32

uniform render_tint [4]f32 0
uniform weights f32 3
uniform palette [4]f32 2
uniform tilt matrix[4,4]f32 0
uniform basis matrix[3,3]f32 0
uniform offset [3]f32 0
`

make_game :: proc(text: string) -> (reflection: Vita_Reflection, game: Vita_Game_Uniforms) {
	ok: bool
	reflection, ok, _ = parse_vita_reflection(text)
	assert(ok)
	game = create_vita_game_uniforms(&reflection)
	return
}

find_entry :: proc(game: ^Vita_Game_Uniforms, name: string) -> Vita_Game_Entry {
	for entry in game.entries {
		if entry.name == name do return entry
	}
	panic("no such entry")
}

@(test)
reads_the_attributes_uniforms_and_textures_of_a_real_reflection :: proc(t: ^testing.T) {
	reflection, ok, message := parse_vita_reflection(CRT_VITA_REFLECTION)
	defer destroy_vita_reflection(&reflection)
	testing.expect(t, ok, message)
	testing.expect_value(t, len(reflection.attributes), 3)
	testing.expect_value(t, len(reflection.uniforms), 16)
	testing.expect_value(t, len(reflection.textures), 1)
	testing.expect_value(t, reflection.uniforms[0].name, "frame_view_projection")
	testing.expect_value(t, reflection.uniforms[0].type, "matrix[4,4]f32")
	testing.expect_value(t, reflection.uniforms[15].name, "resolution")
	testing.expect_value(t, reflection.uniforms[15].type, "[2]f32")
	slot, found := get_vita_texture_slot(&reflection, "tex")
	testing.expect(t, found)
	testing.expect_value(t, slot, 0)
	_, missing := get_vita_texture_slot(&reflection, "nothing")
	testing.expect(t, missing == false)
	testing.expect(t, vita_reads_normal(&reflection) == false)
}

@(test)
a_reflection_with_a_normal_reads_one_and_arrays_keep_their_count :: proc(t: ^testing.T) {
	reflection, ok, message := parse_vita_reflection(SNOW_VITA_REFLECTION)
	defer destroy_vita_reflection(&reflection)
	testing.expect(t, ok, message)
	testing.expect(t, vita_reads_normal(&reflection))
	testing.expect_value(t, reflection.uniforms[len(reflection.uniforms) - 1].name, "lights_cone")
	testing.expect_value(t, reflection.uniforms[len(reflection.uniforms) - 1].count, 8)
}

@(test)
a_vita_reflection_it_cannot_read_is_an_error_with_a_line :: proc(t: ^testing.T) {
	bad := []string {
		"target vita\n",                                                       // no header
		"mbs-reflection 1\n",                                                  // no target
		"mbs-reflection 2\ntarget vita\n",                                     // a version it does not know
		"mbs-reflection 1\ntarget 3ds\n",                                      // another target's
		"mbs-reflection 1\ntarget vita\nuniform x f32\n",                      // a word short
		"mbs-reflection 1\ntarget vita\nuniform x f32 many\n",                 // a count that is not a number
		"mbs-reflection 1\ntarget vita\nuniform x f32 -1\n",                   // a negative count
		"mbs-reflection 1\ntarget vita\nuniform x bool 0\n",                   // a type it does not know
		"mbs-reflection 1\ntarget vita\nuniform x matrix[5,5]f32 0\n",         // a matrix Cg has no uniform for
		"mbs-reflection 1\ntarget vita\nattribute a\n",                        // a word short
		"mbs-reflection 1\ntarget vita\ntexture tex\n",                        // a word short
		"mbs-reflection 1\ntarget vita\ntexture tex first\n",                  // a slot that is not a number
		"mbs-reflection 1\ntarget vita\nsampler s 0\n",                        // a line it does not know: never skipped
	}
	for text, index in bad {
		reflection, ok, message := parse_vita_reflection(text)
		testing.expectf(t, ok == false, "case %d was accepted", index)
		testing.expectf(t, message != "", "case %d gave no message", index)
		destroy_vita_reflection(&reflection)
	}
}

@(test)
game_uniforms_are_everything_but_the_engines :: proc(t: ^testing.T) {
	reflection, game := make_game(SHIELD_VITA_REFLECTION)
	defer destroy_vita_reflection(&reflection)
	defer destroy_vita_game_uniforms(&game)
	// render_shininess and the other render_ names are the engine's, and so is every frame_ one
	testing.expect_value(t, len(game.entries), 3)
	testing.expect_value(t, game.entries[0].name, "hit_a")
	testing.expect_value(t, game.entries[2].offset, 8)
	testing.expect_value(t, len(game.values), 12)

	snow_reflection, snow := make_game(SNOW_VITA_REFLECTION)
	defer destroy_vita_reflection(&snow_reflection)
	defer destroy_vita_game_uniforms(&snow)
	testing.expect_value(t, len(snow.entries), 2) // snow_amount and snow_depth; lights_* are the engine's
	testing.expect_value(t, len(snow.values), 2)
}

@(test)
packs_scalars_vectors_and_plain_literals_at_their_offsets :: proc(t: ^testing.T) {
	reflection, game := make_game(CRT_VITA_REFLECTION)
	defer destroy_vita_reflection(&reflection)
	defer destroy_vita_game_uniforms(&game)
	game.dirty = false

	ok, message := set_vita_game_value(&game, "curvature", 0.25) // an f64 literal
	testing.expect(t, ok, message)
	testing.expect(t, game.dirty)
	ok, message = set_vita_game_value(&game, "line_count", 240) // an int literal
	testing.expect(t, ok, message)
	ok, message = set_vita_game_value(&game, "vignette", f32(0.5))
	testing.expect(t, ok, message)
	ok, message = set_vita_game_value(&game, "resolution", [2]f32{320, 240})
	testing.expect(t, ok, message)

	curvature := find_entry(&game, "curvature")
	testing.expect_value(t, game.values[curvature.offset], 0.25)
	testing.expect_value(t, game.values[find_entry(&game, "line_count").offset], 240)
	testing.expect_value(t, game.values[find_entry(&game, "vignette").offset], 0.5)
	resolution := find_entry(&game, "resolution")
	testing.expect_value(t, resolution.floats, 2)
	testing.expect_value(t, game.values[resolution.offset], 320)
	testing.expect_value(t, game.values[resolution.offset + 1], 240)
	// Six f32s, then the vec2: offsets are packed with no padding
	testing.expect_value(t, resolution.offset, 6)
	testing.expect_value(t, len(game.values), 8)
}

@(test)
packs_arrays_matrices_and_vectors_as_odin_keeps_them :: proc(t: ^testing.T) {
	reflection, game := make_game(ARRAYS_VITA_REFLECTION)
	defer destroy_vita_reflection(&reflection)
	defer destroy_vita_game_uniforms(&game)
	testing.expect_value(t, find_entry(&game, "weights").floats, 3)
	testing.expect_value(t, find_entry(&game, "palette").floats, 8)
	testing.expect_value(t, find_entry(&game, "tilt").floats, 16)
	testing.expect_value(t, find_entry(&game, "basis").floats, 9)
	testing.expect_value(t, len(game.values), 3 + 8 + 16 + 9 + 3)

	weights := [3]f32{1, 2, 3}
	ok, message := set_vita_game_value(&game, "weights", weights)
	testing.expect(t, ok, message)
	palette := [2][4]f32{{1, 2, 3, 4}, {5, 6, 7, 8}}
	ok, message = set_vita_game_value(&game, "palette", palette[:]) // a slice
	testing.expect(t, ok, message)

	// Matrix memory unchanged: element (row 1, column 0) is the second float, not the fifth
	tilt := matrix[4, 4]f32{
		1, 2, 3, 4,
		5, 6, 7, 8,
		9, 10, 11, 12,
		13, 14, 15, 16,
	}
	ok, message = set_vita_game_value(&game, "tilt", tilt)
	testing.expect(t, ok, message)
	basis := matrix[3, 3]f32{
		1, 2, 3,
		4, 5, 6,
		7, 8, 9,
	}
	ok, message = set_vita_game_value(&game, "basis", basis)
	testing.expect(t, ok, message)

	for i in 0 ..< 3 do testing.expect_value(t, game.values[find_entry(&game, "weights").offset + i], f32(i + 1))
	for i in 0 ..< 8 do testing.expect_value(t, game.values[find_entry(&game, "palette").offset + i], f32(i + 1))

	tilt_floats := ([^]f32)(&tilt)[:16]
	basis_floats := ([^]f32)(&basis)[:9]
	tilt_offset := find_entry(&game, "tilt").offset
	basis_offset := find_entry(&game, "basis").offset
	for i in 0 ..< 16 do testing.expect_value(t, game.values[tilt_offset + i], tilt_floats[i])
	for i in 0 ..< 9 do testing.expect_value(t, game.values[basis_offset + i], basis_floats[i])
	// and by name of the layout, independent of the memory cast: the first four floats are column 0
	testing.expect_value(t, game.values[tilt_offset + 1], 5) // tilt[1,0]
	testing.expect_value(t, game.values[tilt_offset + 4], 2) // tilt[0,1]
	testing.expect_value(t, game.values[basis_offset + 3], 2) // basis[0,1]

	ok, message = set_vita_game_value(&game, "offset", [3]f32{7, 8, 9})
	testing.expect(t, ok, message)
	testing.expect_value(t, game.values[find_entry(&game, "offset").offset + 2], 9)
}

@(test)
a_refused_value_changes_nothing :: proc(t: ^testing.T) {
	reflection, game := make_game(ARRAYS_VITA_REFLECTION)
	defer destroy_vita_reflection(&reflection)
	defer destroy_vita_game_uniforms(&game)

	good := [2][4]f32{{1, 2, 3, 4}, {5, 6, 7, 8}}
	ok, _ := set_vita_game_value(&game, "palette", good[:])
	testing.expect(t, ok)
	ok, _ = set_vita_game_value(&game, "weights", [3]f32{1, 2, 3})
	testing.expect(t, ok)
	ok, _ = set_vita_game_value(&game, "offset", [3]f32{4, 5, 6})
	testing.expect(t, ok)
	before := make([]f32, len(game.values), context.temp_allocator)
	copy(before, game.values[:])
	game.dirty = false

	check :: proc(t: ^testing.T, game: ^Vita_Game_Uniforms, name: string, value: any, what: string) {
		ok, message := set_vita_game_value(game, name, value)
		testing.expectf(t, ok == false, "%s was accepted", what)
		testing.expectf(t, message != "", "%s gave no message", what)
	}
	check(t, &game, "nothing", 1.0, "a name the shader lacks")
	check(t, &game, "offset", [2]f32{1, 2}, "a vec2 for a vec3")
	check(t, &game, "offset", 1.0, "a number for a vec3")
	check(t, &game, "offset", "red", "a string for a vec3")
	check(t, &game, "tilt", matrix[3, 3]f32{}, "a mat3 for a mat4")
	check(t, &game, "basis", [9]f32{}, "an array for a mat3")
	check(t, &game, "weights", [2]f32{1, 2}, "a short array")
	check(t, &game, "weights", 1.0, "a number for an array")
	check(t, &game, "weights", [3]string{"a", "b", "c"}, "strings for an array")
	one := [1][4]f32{{9, 9, 9, 9}}
	check(t, &game, "palette", one[:], "a slice one element short")
	check(t, &game, "palette", [2][3]f32{}, "an array of vec3 for vec4s")
	// The bad element comes second: the first one was already packed when it is found, and must not have landed
	mixed := [2]any{[4]f32{9, 9, 9, 9}, [3]f32{9, 9, 9}}
	check(t, &game, "palette", mixed, "an array whose second element is a vec3")

	testing.expect(t, game.dirty == false)
	for value, index in game.values do testing.expectf(t, value == before[index], "float %d changed", index)
}
