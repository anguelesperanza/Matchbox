package mbsc

import "core:fmt"

// The types of the shader language (docs/shader_language.md, section 3). A type is a small value; two types are
// the same when types_equal says so, not when the pointers match.

Type_Kind :: enum {
	INVALID, // an earlier error; operations on it stay quiet, so one mistake gives one message
	VOID, // what a call to a procedure without a result gives
	BOOL,
	F32,
	I32,
	U32,
	VECTOR, // [2], [3] or [4] of f32 or i32
	MATRIX, // matrix[R, C]f32, R and C from 2 to 4
	ARRAY, // [N]T for any other element or length
	STRUCT,
	TEXTURE2D,
}

Type :: struct {
	kind: Type_Kind,
	elem: ^Type, // vector and array: the element type
	count: int, // vector and array: how many elements
	rows: int, // matrix
	cols: int, // matrix
	info: ^Struct_Info, // struct
}

TYPE_INVALID := Type{kind = .INVALID}
TYPE_VOID := Type{kind = .VOID}
TYPE_BOOL := Type{kind = .BOOL}
TYPE_F32 := Type{kind = .F32}
TYPE_I32 := Type{kind = .I32}
TYPE_U32 := Type{kind = .U32}
TYPE_TEXTURE2D := Type{kind = .TEXTURE2D}

make_vector :: proc(elem: ^Type, count: int) -> ^Type {
	result := new(Type)
	result^ = Type{kind = .VECTOR, elem = elem, count = count}
	return result
}

make_matrix :: proc(rows, cols: int) -> ^Type {
	result := new(Type)
	result^ = Type{kind = .MATRIX, rows = rows, cols = cols, elem = &TYPE_F32}
	return result
}

make_array :: proc(elem: ^Type, count: int) -> ^Type {
	result := new(Type)
	result^ = Type{kind = .ARRAY, elem = elem, count = count}
	return result
}

make_struct :: proc(info: ^Struct_Info) -> ^Type {
	result := new(Type)
	result^ = Type{kind = .STRUCT, info = info}
	return result
}

// make_sized_array is what `[N]T` means: a vector when T is f32 or i32 and N is 2 to 4, otherwise an array.
make_sized_array :: proc(elem: ^Type, count: int) -> ^Type {
	if (elem.kind == .F32 || elem.kind == .I32) && count >= 2 && count <= 4 {
		return make_vector(elem, count)
	}
	return make_array(elem, count)
}

types_equal :: proc(a, b: ^Type) -> bool {
	if a == b {
		return true
	}
	if a == nil || b == nil || a.kind != b.kind {
		return false
	}
	#partial switch a.kind {
	case .VECTOR, .ARRAY:
		return a.count == b.count && types_equal(a.elem, b.elem)
	case .MATRIX:
		return a.rows == b.rows && a.cols == b.cols
	case .STRUCT:
		return a.info == b.info
	}
	return true
}

is_invalid :: proc(t: ^Type) -> bool {
	return t == nil || t.kind == .INVALID
}

// is_scalar_number is f32, i32 or u32.
is_scalar_number :: proc(t: ^Type) -> bool {
	return t.kind == .F32 || t.kind == .I32 || t.kind == .U32
}

is_integer :: proc(t: ^Type) -> bool {
	return t.kind == .I32 || t.kind == .U32
}

// is_float_gen is f32 or a vector of f32: what most built-in functions take, written `T` in the spec.
is_float_gen :: proc(t: ^Type) -> bool {
	return t.kind == .F32 || (t.kind == .VECTOR && t.elem.kind == .F32)
}

is_float_vector :: proc(t: ^Type) -> bool {
	return t.kind == .VECTOR && t.elem.kind == .F32
}

// component_count is how many components a scalar or a vector has.
component_count :: proc(t: ^Type) -> int {
	if t.kind == .VECTOR {
		return t.count
	}
	return 1
}

type_name :: proc(t: ^Type) -> string {
	if t == nil {
		return "nothing"
	}
	switch t.kind {
	case .INVALID:
		return "an unknown type"
	case .VOID:
		return "nothing"
	case .BOOL:
		return "bool"
	case .F32:
		return "f32"
	case .I32:
		return "i32"
	case .U32:
		return "u32"
	case .VECTOR, .ARRAY:
		return fmt.aprintf("[%d]%s", t.count, type_name(t.elem))
	case .MATRIX:
		return fmt.aprintf("matrix[%d, %d]f32", t.rows, t.cols)
	case .STRUCT:
		if t.info.name != "" {
			return t.info.name
		}
		return "a struct"
	case .TEXTURE2D:
		return "Texture2D"
	}
	return "an unknown type"
}
