package mbsc

import "core:fmt"
import "core:strings"

// Where each uniform lives inside its constant buffer, by HLSL's packing rules. The runtime needs these to write a
// game's values by name, and the reflection file (reflection.odin) carries them. tests check them against what
// d3dcompiler itself reports, so they can't drift from the HLSL.
//
// The rules (Direct3D 11, column-major matrices, which is what the engine uploads):
//   - a scalar or vector goes at the next free spot that doesn't cross a 16-byte boundary
//   - a matrix, an array or a struct starts on a 16-byte boundary
//   - a matrix takes one 16-byte step per column; its last column takes only the bytes it needs
//   - an array element starts on a 16-byte boundary, and the last one takes only the bytes it needs
//   - what follows a matrix, array or struct may share the last 16 bytes if there is room

// The names and the list of entries are allocated with the temporary allocator.

// Layout_Entry is one value the runtime can set. An array of numbers or vectors is one entry with a count; an array
// of structs, or of arrays, is one entry per element, named `lights[1].strength`.
Layout_Entry :: struct {
	name:   string, // `flash`, `key_light.strength`, `lights[1].strength`; an engine field is just `time`
	type:   ^Type, // the element type when count > 0
	offset: int, // bytes from the start of the buffer
	size:   int, // bytes the whole entry takes, all elements of an array together
	count:  int, // 0 when the entry isn't an array
	stride: int, // bytes between array elements
}

Layout :: struct {
	entries: [dynamic]Layout_Entry,
	size:    int, // the buffer's size in bytes, a multiple of 16
}

@(private = "file")
round_up_16 :: proc(value: int) -> int {
	return (value + 15) / 16 * 16
}

// packed_size is the bytes a value takes in a constant buffer, without the padding after it.
packed_size :: proc(ir: ^IR_Module, type: ^Type) -> int {
	#partial switch type.kind {
	case .BOOL, .F32, .I32, .U32:
		return 4
	case .VECTOR:
		return 4 * type.count
	case .MATRIX:
		return (type.cols - 1) * 16 + type.rows * 4
	case .ARRAY:
		return (type.count - 1) * array_stride(ir, type) + packed_size(ir, type.elem)
	case .STRUCT:
		fields := struct_fields(ir, type)
		cursor := 0
		for field in fields {
			cursor = place(ir, field.type, cursor) + packed_size(ir, field.type)
		}
		return cursor
	}
	return 0
}

// array_stride is the distance between the elements of an array.
array_stride :: proc(ir: ^IR_Module, type: ^Type) -> int {
	return round_up_16(packed_size(ir, type.elem))
}

// place returns where a value goes when the previous one ended at `cursor`.
@(private = "file")
place :: proc(ir: ^IR_Module, type: ^Type, cursor: int) -> int {
	#partial switch type.kind {
	case .BOOL, .F32, .I32, .U32, .VECTOR:
		size := packed_size(ir, type)
		if cursor / 16 != (cursor + size - 1) / 16 {
			return round_up_16(cursor)
		}
		return cursor
	}
	return round_up_16(cursor)
}

// struct_fields are the fields of a struct type, with their types resolved. Nothing for a struct the module doesn't
// declare, which can't happen for a shader that passed the checker.
struct_fields :: proc(ir: ^IR_Module, type: ^Type) -> []IR_Field_Info {
	for info in ir.structs {
		if info.name == type.info.name {
			return info.fields
		}
	}
	return nil
}

@(private = "file")
add_entries :: proc(ir: ^IR_Module, layout: ^Layout, name: string, type: ^Type, offset: int) {
	#partial switch type.kind {
	case .STRUCT:
		cursor := 0
		for field in struct_fields(ir, type) {
			at := place(ir, field.type, cursor)
			add_entries(ir, layout, strings.concatenate({name, ".", field.name}, context.temp_allocator), field.type, offset + at)
			cursor = at + packed_size(ir, field.type)
		}
	case .ARRAY:
		stride := array_stride(ir, type)
		#partial switch type.elem.kind {
		case .BOOL, .F32, .I32, .U32, .VECTOR, .MATRIX:
			append(&layout.entries, Layout_Entry{name, type.elem, offset, packed_size(ir, type), type.count, stride})
		case:
			for index in 0 ..< type.count {
				add_entries(ir, layout, fmt.aprintf("%s[%d]", name, index, allocator = context.temp_allocator), type.elem, offset + index * stride)
			}
		}
	case:
		append(&layout.entries, Layout_Entry{name, type, offset, packed_size(ir, type), 0, 0})
	}
}

// game_layout is the layout of the `mbs_game` buffer: the game's uniforms in the order they are declared.
game_layout :: proc(ir: ^IR_Module) -> Layout {
	layout: Layout
	layout.entries = make([dynamic]Layout_Entry, 0, 16, context.temp_allocator)
	cursor := 0
	for uniform in ir.uniforms {
		if uniform.kind != .GAME {
			continue
		}
		at := place(ir, uniform.type, cursor)
		add_entries(ir, &layout, uniform.name, uniform.type, at)
		cursor = at + packed_size(ir, uniform.type)
	}
	layout.size = round_up_16(cursor)
	return layout
}

// engine_field_type reads the type spelling of the engine tables (`f32`, `[4]f32`, `matrix[4,4]f32`).
engine_field_type :: proc(key: string) -> ^Type {
	switch {
	case key == "f32":
		return &TYPE_F32
	case key == "[2]f32":
		return make_vector(&TYPE_F32, 2)
	case key == "[3]f32":
		return make_vector(&TYPE_F32, 3)
	case key == "[4]f32":
		return make_vector(&TYPE_F32, 4)
	case strings.has_prefix(key, "matrix[") && len(key) == len("matrix[4,4]f32"):
		return make_matrix(int(key[7] - '0'), int(key[9] - '0'))
	}
	return &TYPE_F32
}

// engine_layout is the layout of an engine block. Every field is in it, in the engine's order, whichever of them the
// shader declared: the runtime fills one fixed struct.
engine_layout :: proc(ir: ^IR_Module, kind: Uniform_Kind) -> Layout {
	layout: Layout
	layout.entries = make([dynamic]Layout_Entry, 0, 16, context.temp_allocator)
	fields: []Engine_Field = FRAME_FIELDS[:]
	if kind == .DRAW {
		fields = DRAW_FIELDS[:]
	}
	cursor := 0
	for field in fields {
		type := engine_field_type(field.type)
		at := place(ir, type, cursor)
		add_entries(ir, &layout, field.name, type, at)
		cursor = at + packed_size(ir, type)
	}
	layout.size = round_up_16(cursor)
	return layout
}
