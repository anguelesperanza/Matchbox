package matchbox

/*
	Game shaders on the Vita: the parts that are plain logic
	========================================================
	Reads the reflection mbsc writes (`mbsc shader.mbs -target:vita --emit-reflection`, docs/shader_cg.md "Vita
	reflection") and packs a game's `set_shader_value` into the floats a shader's uniforms are made of. Neither touches
	the GPU, so both are shared and tested on PC (shader_vita_test.odin); the Vita renderer finds each uniform's handle by
	name and uploads `Vita_Game_Uniforms.values[entry.offset:][:entry.floats]` with `gfx.set_uniform` on each draw.

	Unlike the 3DS file, this one lists every uniform the Cg program kept, the engine's too, so the renderer can tell which
	engine uniforms a shader reads and skip writing the rest.

	A line it does not understand is an error, never skipped, as with the .tev and 3DS readers.
*/

import "base:runtime"
import "core:reflect"
import "core:strconv"
import "core:strings"

Vita_Attribute :: struct {
	name: string,
	type: string, // as the file spells it: "[3]f32"
}

Vita_Uniform :: struct {
	name:  string, // the Cg global's name
	type:  string, // "f32", "[4]f32", "matrix[4,4]f32": the type of one element
	count: int, // 0 for a single value, else the array's length
}

Vita_Texture :: struct {
	name: string,
	slot: int, // the texture unit the fragment program samples it from
}

// What the Vita reads out of a Vita reflection. The strings point into the text it was read from, so that must outlive it
Vita_Reflection :: struct {
	attributes: [dynamic]Vita_Attribute,
	uniforms:   [dynamic]Vita_Uniform,
	textures:   [dynamic]Vita_Texture,
}

destroy_vita_reflection :: proc(reflection: ^Vita_Reflection) {
	delete(reflection.attributes)
	delete(reflection.uniforms)
	delete(reflection.textures)
	reflection^ = {}
}

Vita_Type_Kind :: enum {
	SCALAR,
	VECTOR,
	MATRIX,
}

// How many floats one element of a uniform's type is made of, and the shape that decides what value fits it
Vita_Type :: struct {
	kind:    Vita_Type_Kind,
	rows:    int,
	columns: int,
	floats:  int,
}

/*Reads a type as the reflection spells it. Only float types exist on the Vita side: Cg has no other uniform the language can declare*/
parse_vita_type :: proc(type: string) -> (shape: Vita_Type, ok: bool) {
	switch type {
	case "f32":    return {kind = .SCALAR, rows = 1, columns = 1, floats = 1}, true
	case "[2]f32": return {kind = .VECTOR, rows = 2, columns = 1, floats = 2}, true
	case "[3]f32": return {kind = .VECTOR, rows = 3, columns = 1, floats = 3}, true
	case "[4]f32": return {kind = .VECTOR, rows = 4, columns = 1, floats = 4}, true
	}
	if strings.has_prefix(type, "matrix[") && strings.has_suffix(type, "]f32") {
		inner := type[len("matrix["):len(type) - len("]f32")]
		comma := strings.index_byte(inner, ',')
		if comma < 0 do return {}, false
		rows, rows_ok := strconv.parse_int(inner[:comma])
		columns, columns_ok := strconv.parse_int(inner[comma + 1:])
		if rows_ok && columns_ok && rows >= 2 && rows <= 4 && columns >= 2 && columns <= 4 {
			return {kind = .MATRIX, rows = rows, columns = columns, floats = rows * columns}, true
		}
	}
	return {}, false
}

/*Reads a Vita reflection. On failure `message` names the line and what was wrong with it*/
parse_vita_reflection :: proc(text: string) -> (reflection: Vita_Reflection, ok: bool, message: string) {
	text := text
	line_number := 0
	saw_header := false
	saw_target := false
	defer if ok == false do destroy_vita_reflection(&reflection)

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
			if len(words) != 2 || words[1] != "vita" do return reflection, false, tev_error(line_number, "the reflection is not for the vita")
			saw_target = true

		case "attribute":
			if len(words) != 3 do return reflection, false, tev_error(line_number, "expected: attribute <name> <type>")
			append(&reflection.attributes, Vita_Attribute{name = words[1], type = words[2]})

		case "uniform":
			if len(words) != 4 do return reflection, false, tev_error(line_number, "expected: uniform <name> <type> <count>")
			count, count_ok := strconv.parse_int(words[3])
			if count_ok == false || count < 0 do return reflection, false, tev_error(line_number, "expected: uniform <name> <type> <count>, with a count of 0 or more")
			_, type_ok := parse_vita_type(words[2])
			if type_ok == false do return reflection, false, tev_error(line_number, "a uniform type the reader does not know")
			append(&reflection.uniforms, Vita_Uniform{name = words[1], type = words[2], count = count})

		case "texture":
			if len(words) != 3 do return reflection, false, tev_error(line_number, "expected: texture <name> <slot>")
			slot, slot_ok := strconv.parse_int(words[2])
			if slot_ok == false || slot < 0 do return reflection, false, tev_error(line_number, "expected: texture <name> <slot>, with a slot of 0 or more")
			append(&reflection.textures, Vita_Texture{name = words[1], slot = slot})

		case:
			return reflection, false, tev_error(line_number, "a line the reader does not know")
		}
	}
	if saw_header == false || saw_target == false do return reflection, false, "the reflection has no `mbs-reflection` or `target` line"
	return reflection, true, ""
}

/*Whether the shader reads a normal: its mesh must be a Lit_Vertex one, whether or not it uses the lights*/
vita_reads_normal :: proc(reflection: ^Vita_Reflection) -> bool {
	for attribute in reflection.attributes {
		if attribute.name == "normal" do return true
	}
	return false
}

/*The texture unit a shader samples a texture from, by the name the shader gave it*/
get_vita_texture_slot :: proc(reflection: ^Vita_Reflection, name: string) -> (slot: int, ok: bool) {
	for texture in reflection.textures {
		if texture.name == name do return texture.slot, true
	}
	return 0, false
}

// ---- game uniforms ----------------------------------------------------------------------------------------------

// One game uniform: where its floats sit in `Vita_Game_Uniforms.values`
Vita_Game_Entry :: struct {
	name:   string,
	type:   string, // the type of one element, as the reflection spells it
	count:  int, // 0 for a single value, else the array's length
	offset: int, // index of its first float in values
	floats: int, // how many floats in all: the element's floats times the count (1 if not an array)
}

/*
	A shader's game uniforms as the CPU holds them: one flat run of floats, each uniform at its own offset, in the
	order the file lists them. The renderer writes the whole thing to the program on each draw, because one uniform
	buffer is shared by every program drawn, so another shader's values would otherwise be what this one reads.
*/
Vita_Game_Uniforms :: struct {
	entries: [dynamic]Vita_Game_Entry,
	values:  [dynamic]f32,
	dirty:   bool, // set by a successful set; the renderer clears it after uploading
}

/*Makes the holder for a shader's game uniforms: every uniform in the reflection that is not the engine's, set to zero*/
create_vita_game_uniforms :: proc(reflection: ^Vita_Reflection) -> (game: Vita_Game_Uniforms) {
	// The engine's are told apart by prefix (frame_, render_, lights_, skin_), which takes in the Vita's render_shininess,
	// render_specular_strength and render_alpha_cutoff too: the same rule as the 3DS
	for uniform in reflection.uniforms {
		if is_engine_uniform(uniform.name) do continue
		shape, _ := parse_vita_type(uniform.type) // checked when the reflection was read
		elements := max(uniform.count, 1)
		entry := Vita_Game_Entry {
			name   = uniform.name,
			type   = uniform.type,
			count  = uniform.count,
			offset = len(game.values),
			floats = shape.floats * elements,
		}
		for _ in 0 ..< entry.floats do append(&game.values, 0)
		append(&game.entries, entry)
	}
	game.dirty = true
	return
}

destroy_vita_game_uniforms :: proc(game: ^Vita_Game_Uniforms) {
	delete(game.entries)
	delete(game.values)
	game^ = {}
}

/*
	Sets a game uniform by name. `value` has the uniform's type; a plain 0.5 or 3 also works for an f32. An array
	uniform takes an array or slice of exactly its length. A matrix is stored as Odin keeps it (column-major), untouched,
	because the Cg side is written transposed to read that memory (docs/shader_cg.md, "Matrices"). `message` says what is
	wrong when `ok` is false, and then nothing was changed: a refused value must not wipe the old one.
*/
set_vita_game_value :: proc(game: ^Vita_Game_Uniforms, name: string, value: any) -> (ok: bool, message: string) {
	for &entry in game.entries {
		if entry.name != name do continue

		shape, _ := parse_vita_type(entry.type)
		// Packed aside and copied on success, so a bad element halfway through an array leaves the old values whole
		packed := make([]f32, entry.floats, context.temp_allocator)

		if entry.count == 0 {
			if pack_vita_element(packed, shape, value) == false {
				return false, join_message({"`", name, "` is a ", entry.type, " in the shader; got a different type"})
			}
		} else {
			if value.id == nil || !(reflect.is_array(type_info_of(value.id)) || reflect.is_slice(type_info_of(value.id)) || reflect.is_dynamic_array(type_info_of(value.id))) {
				return false, join_message({"`", name, "` is an array of ", entry.type, " in the shader; got a value that is not an array or slice"})
			}
			if reflect.length(value) != entry.count {
				return false, join_message({"`", name, "` is an array of ", int_to_text(entry.count), " in the shader; got a different length"})
			}
			for index in 0 ..< entry.count {
				element := packed[index * shape.floats:][:shape.floats]
				item := reflect.index(value, index)
				// A `[]any` holds each element as an `any` of its own; look through that so mixed literals work
				if item.id == typeid_of(any) do item = (^any)(item.data)^
				if pack_vita_element(element, shape, item) == false {
					return false, join_message({"`", name, "` is an array of ", entry.type, " in the shader; element ", int_to_text(index), " is a different type"})
				}
			}
		}
		copy(game.values[entry.offset:][:entry.floats], packed)
		game.dirty = true
		return true, ""
	}
	return false, join_message({"the shader has no uniform called `", name, "`"})
}

@(private = "file")
join_message :: proc(parts: []string) -> string {
	// The temp allocator: the message is read once, by whoever reports it
	return strings.concatenate(parts, context.temp_allocator)
}

// Fills `destination` (one element's floats) from a value of the type the reflection names, or says it is not that type
@(private = "file")
pack_vita_element :: proc(destination: []f32, shape: Vita_Type, value: any) -> bool {
	switch shape.kind {
	case .SCALAR:
		number, ok := value_as_f32(value)
		if ok == false do return false
		destination[0] = number
		return true

	case .VECTOR:
		switch shape.rows {
		case 2:
			v, ok := value.([2]f32)
			if ok == false do return false
			copy(destination, v[:])
		case 3:
			v, ok := value.([3]f32)
			if ok == false do return false
			copy(destination, v[:])
		case 4:
			v, ok := value.([4]f32)
			if ok == false do return false
			copy(destination, v[:])
		case:
			return false
		}
		return true

	case .MATRIX:
		// Odin's own description of the value, so one path covers every matrix[R,C]f32 the reflection can name
		if value.id == nil do return false
		info, is_matrix := runtime.type_info_base(type_info_of(value.id)).variant.(runtime.Type_Info_Matrix)
		if is_matrix == false || info.row_count != shape.rows || info.column_count != shape.columns do return false
		if runtime.type_info_base(info.elem).id != typeid_of(f32) do return false
		// Column-major, `elem_stride` floats between columns: for the 4x4s and 3x3s the engine uses that is the matrix's
		// memory exactly, and a stride with padding in it is squeezed out so the float count matches the reflection
		floats := ([^]f32)(value.data)
		for column in 0 ..< shape.columns {
			for row in 0 ..< shape.rows {
				destination[column * shape.rows + row] = floats[column * info.elem_stride + row]
			}
		}
		return true
	}
	return false
}
