package matchbox

/*
	Game shaders on the 3DS: the parts that are plain logic
	=======================================================
	Reads the `.3ds.refl` file mbsc writes (`mbsc shader.mbs -target:3ds --emit-reflection`) and packs a game's
	`set_shader_value` into the vertex-shader registers a shader's uniforms live in. Neither touches citro3d, so both
	are shared and tested on PC (shader_pica_test.odin); render_3ds_freestanding_arm32.odin finds each uniform's register
	by name with `shaderInstanceGetUniformLocation` and uploads what is packed here.

	The format is in docs/shader_pica.md, "Reflection". One thing differs from PC's reflection: the file lists only the
	uniforms the vertex program reads, so a game uniform used by the fragment stage alone is not in it (the fragment
	stage has no uniforms but a TexEnv constant, which the first pass does not take from a uniform).

	A line it does not understand is an error, never skipped, as with the .tev reader.
*/

import "core:strconv"
import "core:strings"

Pica_Attribute :: struct {
	name:  string,
	type:  string, // as the file spells it: "[3]f32"
	index: int, // the vertex input register, v<index>
}

Pica_Uniform :: struct {
	name:      string, // the name in the .shbin
	type:      string, // "f32", "[4]f32", "matrix[4,4]f32"
	registers: int, // how many float4 registers it takes: one a scalar or vector, one a matrix row
	is_bool:   bool, // a `bool` line: set with the boolean uniform call, not the float one
}

// What the 3DS reads out of a `.3ds.refl`. The strings point into the text it was read from, so that must outlive it
Pica_Reflection :: struct {
	attributes: [dynamic]Pica_Attribute,
	uniforms:   [dynamic]Pica_Uniform,
}

destroy_pica_reflection :: proc(reflection: ^Pica_Reflection) {
	delete(reflection.attributes)
	delete(reflection.uniforms)
	reflection^ = {}
}

/*Reads a `.3ds.refl`. On failure `message` names the line and what was wrong with it*/
parse_pica_reflection :: proc(text: string) -> (reflection: Pica_Reflection, ok: bool, message: string) {
	text := text
	line_number := 0
	saw_header := false
	saw_target := false
	defer if ok == false do destroy_pica_reflection(&reflection)

	for line in strings.split_lines_iterator(&text) {
		line_number += 1
		line := strings.trim_space(line)
		if line == "" do continue

		words_buffer: [8]string
		words := split_words(line, words_buffer[:])

		switch words[0] {
		case "mbs-reflection":
			if len(words) != 2 || words[1] != "1" do return reflection, false, tev_error(line_number, "only version 1 of the reflection format is known")
			saw_header = true

		case "target":
			if len(words) != 2 || words[1] != "3ds" do return reflection, false, tev_error(line_number, "the reflection is not for the 3ds")
			saw_target = true

		case "attribute":
			if len(words) != 4 do return reflection, false, tev_error(line_number, "expected: attribute <name> <type> <register>")
			index, index_ok := strconv.parse_int(words[3])
			if index_ok == false do return reflection, false, tev_error(line_number, "expected: attribute <name> <type> <register>")
			append(&reflection.attributes, Pica_Attribute{name = words[1], type = words[2], index = index})

		case "uniform":
			if len(words) != 4 do return reflection, false, tev_error(line_number, "expected: uniform <name> <type> <registers>")
			registers, registers_ok := strconv.parse_int(words[3])
			if registers_ok == false || registers < 1 do return reflection, false, tev_error(line_number, "expected: uniform <name> <type> <registers>")
			append(&reflection.uniforms, Pica_Uniform{name = words[1], type = words[2], registers = registers})

		case "bool":
			if len(words) != 2 do return reflection, false, tev_error(line_number, "expected: bool <name>")
			append(&reflection.uniforms, Pica_Uniform{name = words[1], type = "bool", is_bool = true})

		case:
			return reflection, false, tev_error(line_number, "a line the reader does not know")
		}
	}
	if saw_header == false || saw_target == false do return reflection, false, "the reflection has no `mbs-reflection` or `target` line"
	return reflection, true, ""
}

/*Whether the shader reads a normal: its mesh must be a Lit_Vertex one (attribute 3), whether or not it uses the lighting unit*/
pica_reads_normal :: proc(reflection: ^Pica_Reflection) -> bool {
	for attribute in reflection.attributes {
		if attribute.name == "normal" do return true
	}
	return false
}

/*
	Whether a uniform is one the engine sets. mbsc names an engine field `<block>_<field>`, and these are the blocks, so
	anything else is the game's. (A game uniform that starts with one of them would be taken for the engine's; the
	shader language reserves those blocks for the engine.)
*/
is_engine_uniform :: proc(name: string) -> bool {
	prefixes := [?]string{"frame_", "render_", "lights_", "skin_"}
	for prefix in prefixes {
		if strings.has_prefix(name, prefix) do return true
	}
	return false
}

// ---- which shader draws a mesh ----------------------------------------------------------------------------------

// What a loaded game shader can draw. One copy of the rule, for PC (shader_windows.odin) and the 3DS
Shader_Facts :: struct {
	has_plain:    bool, // name: Vertex and Lit_Vertex meshes
	has_skinned:  bool, // name_skinned: Skinned_Vertex meshes
	reads_normal: bool, // the plain one needs a Lit_Vertex mesh; a plain Vertex one has no normal to give it
}

Shader_Variant :: enum {
	NONE, // the built-in draws it
	PLAIN,
	SKINNED,
}

/*
	Which of a game shader's variants draws a mesh, if any. A skinned mesh needs a `_skinned` variant, and one without it
	is drawn by the built-in: drawing it with the plain shader would leave it in its bind pose. A shader that reads the
	normal draws only lit meshes, so a sprite or a shape falls back to the built-in
*/
choose_shader_variant :: proc(facts: Shader_Facts, mesh_skinned, mesh_lit: bool) -> Shader_Variant {
	if mesh_skinned do return .SKINNED if facts.has_skinned else .NONE
	if facts.has_plain == false do return .NONE
	if facts.reads_normal && mesh_lit == false do return .NONE
	return .PLAIN
}

// ---- game uniforms ----------------------------------------------------------------------------------------------

// One game uniform: where its registers sit in `Pica_Game_Uniforms.registers`, and the register the .shbin gave it
Pica_Game_Entry :: struct {
	name:      string,
	type:      string,
	first:     int, // index into registers (or into flags, for a bool)
	registers: int,
	is_bool:   bool,
	location:  i32, // the .shbin's register for it, found by the 3DS loader; -1 until then
}

/*
	A shader's game uniforms as the CPU holds them: one float4 per register, in the order the file lists them. They are
	uploaded whole every time the shader is bound, because citro3d keeps one array of registers for every program, so
	another shader's values would otherwise be what this one reads
*/
Pica_Game_Uniforms :: struct {
	entries:   [dynamic]Pica_Game_Entry,
	registers: [dynamic][4]f32,
	flags:     [dynamic]bool,
	dirty:     bool,
}

/*Makes the holder for a shader's game uniforms: every uniform in the reflection that is not the engine's, set to zero*/
create_pica_game_uniforms :: proc(reflection: ^Pica_Reflection) -> (game: Pica_Game_Uniforms) {
	for uniform in reflection.uniforms {
		if is_engine_uniform(uniform.name) do continue
		entry := Pica_Game_Entry {
			name      = uniform.name,
			type      = uniform.type,
			registers = uniform.registers,
			is_bool   = uniform.is_bool,
			location  = -1,
		}
		if uniform.is_bool {
			entry.first = len(game.flags)
			append(&game.flags, false)
		} else {
			entry.first = len(game.registers)
			for _ in 0 ..< uniform.registers do append(&game.registers, [4]f32{})
		}
		append(&game.entries, entry)
	}
	game.dirty = true
	return
}

destroy_pica_game_uniforms :: proc(game: ^Pica_Game_Uniforms) {
	delete(game.entries)
	delete(game.registers)
	delete(game.flags)
	game^ = {}
}

/*
	Sets a game uniform by name. `value` has the uniform's type; a plain 0.5 or 3 also works for an f32. Scalars and
	vectors go in the first components of a register with the rest zero, and a matrix goes in one register per row, the
	way the engine's own matrices do. `message` says what is wrong when `ok` is false.
	Arrays and structs are not here yet: mbsc lists each element or field as a uniform of its own, under a name of its own
*/
set_pica_game_value :: proc(game: ^Pica_Game_Uniforms, name: string, value: any) -> (ok: bool, message: string) {
	for &entry in game.entries {
		if entry.name != name do continue

		if entry.is_bool {
			flag, is_flag := value.(bool)
			if is_flag == false do return false, concat_message({"`", name, "` is a bool in the shader"})
			game.flags[entry.first] = flag
			game.dirty = true
			return true, ""
		}

		rows := game.registers[entry.first:entry.first + entry.registers]
		if pack_pica_value(rows, entry.type, value) == false {
			return false, concat_message({"`", name, "` is a ", entry.type, " in the shader; got a different type"})
		}
		game.dirty = true
		return true, ""
	}
	return false, concat_message({"the shader has no uniform called `", name, "`"})
}

@(private = "file")
concat_message :: proc(parts: []string) -> string {
	// The temp allocator: the message is read once, by whoever reports it
	return strings.concatenate(parts, context.temp_allocator)
}

// Fills `rows` from a value of the type the reflection names, or says it is not that type and leaves them as they were.
// Each case writes whole registers, the unused components as zero, so nothing of an earlier value is left
@(private = "file")
pack_pica_value :: proc(rows: [][4]f32, type: string, value: any) -> bool {
	switch type {
	case "f32":
		number, ok := value_as_f32(value)
		if ok == false do return false
		rows[0].x = number
		return true
	case "[2]f32":
		v, ok := value.([2]f32)
		if ok == false do return false
		rows[0] = {v.x, v.y, 0, 0}
		return true
	case "[3]f32":
		v, ok := value.([3]f32)
		if ok == false do return false
		rows[0] = {v.x, v.y, v.z, 0}
		return true
	case "[4]f32":
		v, ok := value.([4]f32)
		if ok == false do return false
		rows[0] = v
		return true
	case "matrix[4,4]f32":
		m, ok := value.(matrix[4, 4]f32)
		if ok == false do return false
		for row in 0 ..< 4 do rows[row] = {m[row, 0], m[row, 1], m[row, 2], m[row, 3]}
		return true
	case "matrix[3,3]f32":
		m, ok := value.(matrix[3, 3]f32)
		if ok == false do return false
		for row in 0 ..< 3 do rows[row] = {m[row, 0], m[row, 1], m[row, 2], 0}
		return true
	}
	return false
}
