#+build windows

package matchbox

/*
	Reflection
	==========
	Reads the reflection file mbsc writes next to a shader (docs/shader_reflection.md) and uses it to find out what
	the shader needs: the register of each constant buffer, where each uniform sits in its buffer, the slot of each
	texture and the vertex attributes it reads.

	Nothing here talks to D3D. The renderer creates the buffers and binds them; this file only knows the layout.
*/

import "core:fmt"
import "core:reflect"
import "core:strconv"
import "core:strings"
import "vendor:directx/dxgi"

Block_Kind :: enum {
	FRAME,
	RENDER,
	GAME,
}

Reflected_Block :: struct {
	present:bool,
	register:int,
	size:int,
}

Reflected_Attribute :: struct {
	name:string,
	type:string,
}

Reflected_Value :: struct {
	block:Block_Kind,
	name:string,
	type:string, // the type of one element when the value is an array
	offset:int,
	size:int,
	count:int, // 0 when the value isn't an array
	stride:int,
}

Reflected_Texture :: struct {
	name:string,
	slot:int,
}

// Strings point into the text that was parsed, so it has to outlive this (a #load'ed file does)
Shader_Reflection :: struct {
	blocks:[Block_Kind]Reflected_Block,
	attributes:[dynamic]Reflected_Attribute,
	values:[dynamic]Reflected_Value,
	textures:[dynamic]Reflected_Texture,
	sampler:int,
	has_sampler:bool,
}

/*
	What the engine expects of a compiled shader. Lives in `mbi.shader_format`, with its values
	set where `mbi` is declared
*/
Shader_Format :: struct {
	reflection_version:int, // the .refl file version this engine reads; mbsc writes the same number
	vertex_attributes:[3]Vertex_Attribute, // what a Vertex has. A shader may read any of these, in any order, and leave some out
}

@(private)
destroy_reflection :: proc(reflection:^Shader_Reflection) {
	delete(reflection.attributes)
	delete(reflection.values)
	delete(reflection.textures)
	reflection^ = {}
}

@(private="file")
parse_block_kind :: proc(word:string) -> (kind:Block_Kind, ok:bool) {
	switch word {
	case "frame": return .FRAME, true
	case "render": return .RENDER, true
	case "game": return .GAME, true
	}
	return {}, false
}

@(private="file")
parse_number :: proc(word:string) -> (value:int, ok:bool) {
	return strconv.parse_int(word, 10)
}

/*Parses a reflection file. `message` says what is wrong when `ok` is false*/
@(private)
parse_reflection :: proc(text:string) -> (reflection:Shader_Reflection, ok:bool, message:string) {
	reflection_failed :: proc(parsed:^Shader_Reflection, line_number:int, what:string) -> (Shader_Reflection, bool, string) {
		destroy_reflection(parsed)
		return {}, false, fmt.tprintf("reflection file, line %d: %s", line_number, what)
	}

	seen_header := false
	line_number := 0
	text := text
	for line in strings.split_lines_iterator(&text) {
		line_number += 1
		line := strings.trim(line, " \t\r")
		if len(line) == 0 do continue

		words := strings.split(line, " ", context.temp_allocator)

		if seen_header == false {
			if len(words) != 2 || words[0] != "mbs-reflection" {
				return reflection_failed(&reflection, line_number, "the first line must be `mbs-reflection <version>`")
			}
			version, version_ok := parse_number(words[1])
			if version_ok == false || version != mbi.shader_format.reflection_version {
				return reflection_failed(&reflection, line_number, fmt.tprintf("version %s isn't one this engine reads (it reads %d); build the shader again", words[1], mbi.shader_format.reflection_version))
			}
			seen_header = true
			continue
		}

		switch words[0] {
		case "target":
			if len(words) != 2 || words[1] != "pc" do return reflection_failed(&reflection, line_number, "this engine reads `target pc`")

		case "attribute":
			if len(words) != 3 do return reflection_failed(&reflection, line_number, "`attribute` takes a name and a type")
			append(&reflection.attributes, Reflected_Attribute{name = words[1], type = words[2]})

		case "block":
			if len(words) != 4 do return reflection_failed(&reflection, line_number, "`block` takes a name, a register and a size")
			kind, kind_ok := parse_block_kind(words[1])
			register, register_ok := parse_number(words[2])
			size, size_ok := parse_number(words[3])
			if kind_ok == false || register_ok == false || size_ok == false do return reflection_failed(&reflection, line_number, "can't read this `block` line")
			reflection.blocks[kind] = {present = true, register = register, size = size}

		case "value":
			if len(words) != 8 do return reflection_failed(&reflection, line_number, "`value` takes a block, a name, a type, an offset, a size, a count and a stride")
			kind, kind_ok := parse_block_kind(words[1])
			offset, offset_ok := parse_number(words[4])
			size, size_ok := parse_number(words[5])
			count, count_ok := parse_number(words[6])
			stride, stride_ok := parse_number(words[7])
			if kind_ok == false || offset_ok == false || size_ok == false || count_ok == false || stride_ok == false {
				return reflection_failed(&reflection, line_number, "can't read this `value` line")
			}
			append(&reflection.values, Reflected_Value{block = kind, name = words[2], type = words[3], offset = offset, size = size, count = count, stride = stride})

		case "texture":
			if len(words) != 3 do return reflection_failed(&reflection, line_number, "`texture` takes a name and a slot")
			slot, slot_ok := parse_number(words[2])
			if slot_ok == false do return reflection_failed(&reflection, line_number, "can't read this `texture` line")
			append(&reflection.textures, Reflected_Texture{name = words[1], slot = slot})

		case "sampler":
			if len(words) != 2 do return reflection_failed(&reflection, line_number, "`sampler` takes a register")
			register, register_ok := parse_number(words[1])
			if register_ok == false do return reflection_failed(&reflection, line_number, "can't read this `sampler` line")
			reflection.sampler = register
			reflection.has_sampler = true

		case:
			return reflection_failed(&reflection, line_number, fmt.tprintf("don't know `%s`", words[0]))
		}
	}

	if seen_header == false {
		destroy_reflection(&reflection)
		return {}, false, "reflection file is empty"
	}
	return reflection, true, ""
}

// ---- the engine's own blocks ------------------------------------------------------------------------------------

/*Checks that the engine's Frame_Constants and Render_Constants have the layout the shader was built for.
Returns "" when they do, otherwise what differs*/
@(private)
check_engine_blocks :: proc(reflection:^Shader_Reflection) -> string {
	check_block :: proc(reflection:^Shader_Reflection, kind:Block_Kind, name:string, size:int) -> string {
		block := reflection.blocks[kind]
		if block.present && block.size != size {
			return fmt.tprintf("the shader's `%s` block is %d bytes and the engine's struct is %d; build the shader again", name, block.size, size)
		}
		return ""
	}

	if message := check_block(reflection, .FRAME, "frame", size_of(Frame_Constants)); message != "" do return message
	if message := check_block(reflection, .RENDER, "render", size_of(Render_Constants)); message != "" do return message

	for value in reflection.values {
		expected := -1
		switch value.block {
		case .FRAME:
			switch value.name {
			case "view_projection": expected = int(offset_of(Frame_Constants, view_projection))
			case "time": expected = int(offset_of(Frame_Constants, time))
			}
		case .RENDER:
			switch value.name {
			case "model": expected = int(offset_of(Render_Constants, model))
			case "tint": expected = int(offset_of(Render_Constants, tint))
			case "uv_rectangle": expected = int(offset_of(Render_Constants, uv_rectangle))
			case "alpha_cutoff": expected = int(offset_of(Render_Constants, alpha_cutoff))
			case "shininess": expected = int(offset_of(Render_Constants, shininess))
			case "specular_strength": expected = int(offset_of(Render_Constants, specular_strength))
			}
		case .GAME:
			continue
		}
		if expected < 0 {
			return fmt.tprintf("the shader has an engine field `%s` the engine doesn't have", value.name)
		}
		if expected != value.offset {
			return fmt.tprintf("`%s` is at byte %d in the shader and %d in the engine's struct; build the shader again", value.name, value.offset, expected)
		}
	}
	return ""
}

// ---- vertex attributes ------------------------------------------------------------------------------------------

@(private)
Vertex_Attribute :: struct {
	name:string, // the `attr:"..."` tag of the shader
	type:string,
	format:dxgi.FORMAT,
	offset:u32,
}

/*Finds the engine's vertex attribute a shader asks for. `message` says what is wrong when it isn't there*/
@(private)
find_vertex_attribute :: proc(attribute:Reflected_Attribute) -> (found:Vertex_Attribute, message:string) {
	for candidate in mbi.shader_format.vertex_attributes {
		if candidate.name == attribute.name {
			if candidate.type != attribute.type {
				return {}, fmt.tprintf("the shader reads `%s` as %s and the engine's vertices have it as %s", attribute.name, attribute.type, candidate.type)
			}
			return candidate, ""
		}
	}
	return {}, fmt.tprintf("the shader reads a vertex attribute `%s`, which the engine's vertices don't have", attribute.name)
}

// ---- game values ------------------------------------------------------------------------------------------------

@(private="file")
find_game_value :: proc(reflection:^Shader_Reflection, name:string) -> (value:Reflected_Value, found:bool) {
	for candidate in reflection.values {
		if candidate.block == .GAME && candidate.name == name do return candidate, true
	}
	return {}, false
}

// The spelling the reflection file uses for a type the game can pass, or "" for one it can't
@(private="file")
value_type_text :: proc(value:any) -> string {
	switch _ in value {
	case f32: return "f32"
	case i32: return "i32"
	case u32: return "u32"
	case bool: return "bool"
	case [2]f32: return "[2]f32"
	case [3]f32: return "[3]f32"
	case [4]f32: return "[4]f32"
	case [2]i32: return "[2]i32"
	case [3]i32: return "[3]i32"
	case [4]i32: return "[4]i32"
	case matrix[2, 2]f32: return "matrix[2,2]f32"
	case matrix[2, 3]f32: return "matrix[2,3]f32"
	case matrix[2, 4]f32: return "matrix[2,4]f32"
	case matrix[3, 2]f32: return "matrix[3,2]f32"
	case matrix[3, 3]f32: return "matrix[3,3]f32"
	case matrix[3, 4]f32: return "matrix[3,4]f32"
	case matrix[4, 2]f32: return "matrix[4,2]f32"
	case matrix[4, 3]f32: return "matrix[4,3]f32"
	case matrix[4, 4]f32: return "matrix[4,4]f32"
	}
	return ""
}

// A matrix goes in by columns: column c starts 16 bytes * c in, and takes 4 bytes a row
@(private="file")
write_matrix :: proc(destination:[]byte, m:matrix[$R, $C]f32) {
	for column in 0..<C {
		for row in 0..<R {
			element := m[row, column]
			copy(destination[column * 16 + row * 4:], (cast([^]byte)&element)[:4])
		}
	}
}

// Writes one element whose type matches the reflection's. A bool takes 4 bytes in a constant buffer
@(private="file")
write_element :: proc(destination:[]byte, value:any) {
	switch v in value {
	case bool:
		flag:u32 = 1 if v else 0
		copy(destination, (cast([^]byte)&flag)[:4])
	case matrix[2, 2]f32: write_matrix(destination, v)
	case matrix[2, 3]f32: write_matrix(destination, v)
	case matrix[2, 4]f32: write_matrix(destination, v)
	case matrix[3, 2]f32: write_matrix(destination, v)
	case matrix[3, 3]f32: write_matrix(destination, v)
	case matrix[3, 4]f32: write_matrix(destination, v)
	case matrix[4, 2]f32: write_matrix(destination, v)
	case matrix[4, 3]f32: write_matrix(destination, v)
	case matrix[4, 4]f32: write_matrix(destination, v)
	case:
		// scalars and vectors lie in memory the way the buffer wants them
		copy(destination, (cast([^]byte)value.data)[:reflect.size_of_typeid(value.id)])
	}
}

// A literal like 0.5 or 3 arrives as an f64 or an int; the shader's own type decides what it means
@(private="file")
convert_literal :: proc(value:any, wanted:string, storage:^[8]byte) -> any {
	switch v in value {
	case f64:
		if wanted == "f32" {
			(cast(^f32)&storage[0])^ = f32(v)
			return (cast(^f32)&storage[0])^
		}
	case int:
		switch wanted {
		case "i32":
			(cast(^i32)&storage[0])^ = i32(v)
			return (cast(^i32)&storage[0])^
		case "u32":
			(cast(^u32)&storage[0])^ = u32(v)
			return (cast(^u32)&storage[0])^
		case "f32":
			(cast(^f32)&storage[0])^ = f32(v)
			return (cast(^f32)&storage[0])^
		}
	}
	return value
}

/*Writes a game value into the bytes of the game block. `message` says what is wrong when `ok` is false.
`value` is one value of the shader's type, or a slice of them for an array uniform; a plain 0.5 or 3 also works
for an f32, i32 or u32*/
@(private)
write_shader_value :: proc(reflection:^Shader_Reflection, block:[]byte, name:string, value:any) -> (ok:bool, message:string) {
	entry, found := find_game_value(reflection, name)
	if found == false do return false, fmt.tprintf("the shader has no uniform called `%s`", name)

	value := value
	if entry.count == 0 {
		storage:[8]byte
		value = convert_literal(value, entry.type, &storage)
		have := value_type_text(value)
		if have != entry.type {
			return false, fmt.tprintf("`%s` is a %s in the shader; got %s", name, entry.type, have if have != "" else "a type a uniform can't be")
		}
		write_element(block[entry.offset:entry.offset + entry.size], value)
		return true, ""
	}

	// an array: a slice with as many elements as the shader's array has
	if reflect.is_slice(type_info_of(value.id)) == false && reflect.is_array(type_info_of(value.id)) == false {
		return false, fmt.tprintf("`%s` is an array of %d in the shader; pass a slice with %d elements", name, entry.count, entry.count)
	}
	length := reflect.length(value)
	if length != entry.count {
		return false, fmt.tprintf("`%s` has %d elements in the shader; got %d", name, entry.count, length)
	}
	for index in 0..<length {
		element := reflect.index(value, index)
		storage:[8]byte
		element = convert_literal(element, entry.type, &storage)
		have := value_type_text(element)
		if have != entry.type {
			return false, fmt.tprintf("the elements of `%s` are %s in the shader; got %s", name, entry.type, have if have != "" else "a type a uniform can't be")
		}
		start := entry.offset + index * entry.stride
		write_element(block[start:start + entry.stride], element)
	}
	return true, ""
}
