package mbsc

import "core:fmt"
import "core:strings"
import "core:testing"
import "vendor:directx/d3d11"
import "vendor:directx/d3d_compiler"

// The layout mbsc works out for the constant buffers, against what d3dcompiler reports for the HLSL it was given.
// This is the only thing that proves the packing rules in layout.odin are HLSL's.

@(private = "file")
reflect_blob :: proc(blob: ^d3d11.IBlob) -> ^d3d11.IShaderReflection {
	reflector: rawptr
	result := d3d_compiler.Reflect(blob->GetBufferPointer(), blob->GetBufferSize(), d3d11.ID3D11ShaderReflection_UUID, &reflector)
	if result < 0 {
		return nil
	}
	return cast(^d3d11.IShaderReflection)reflector
}

// Mismatches are collected, so one run lists every wrong offset.
@(private = "file")
Check :: struct {
	by_name:  map[string]Layout_Entry,
	problems: [dynamic]string,
}

@(private = "file")
expect_offset :: proc(check: ^Check, name: string, got: int) {
	entry, found := check.by_name[name]
	if found == false {
		append(&check.problems, fmt.aprintf("d3dcompiler has `%s` and mbsc doesn't", name))
		return
	}
	if entry.offset != got {
		append(&check.problems, fmt.aprintf("`%s`: mbsc puts it at %d, d3dcompiler at %d", name, entry.offset, got))
	}
}

// walk_type compares a struct's members, and the members of each element of an array of structs, with their
// d3dcompiler offsets. `base` is where the value starts.
@(private = "file")
walk_type :: proc(check: ^Check, ir: ^IR_Module, name: string, type: ^Type, d3d_type: ^d3d11.IShaderReflectionType, base: int) {
	description: d3d11.SHADER_TYPE_DESC
	d3d_type->GetDesc(&description)

	#partial switch type.kind {
	case .ARRAY:
		stride := array_stride(ir, type)
		elem := type.elem
		for index in 0 ..< type.count {
			element_name := fmt.aprintf("%s[%d]", name, index)
			if elem.kind == .STRUCT {
				walk_struct(check, ir, element_name, elem, d3d_type, base + index * stride)
			} else if elem.kind == .ARRAY {
				// nested arrays are expanded one element at a time; d3dcompiler describes them as one array
				walk_type(check, ir, element_name, elem, d3d_type, base + index * stride)
			}
		}
	case .STRUCT:
		walk_struct(check, ir, name, type, d3d_type, base)
	}
}

@(private = "file")
walk_struct :: proc(check: ^Check, ir: ^IR_Module, name: string, type: ^Type, d3d_type: ^d3d11.IShaderReflectionType, base: int) {
	for field, index in struct_fields(ir, type) {
		member := d3d_type->GetMemberTypeByIndex(u32(index))
		member_description: d3d11.SHADER_TYPE_DESC
		member->GetDesc(&member_description)
		field_name := strings.concatenate({name, ".", field.name})
		at := base + int(member_description.Offset)
		if field.type.kind == .STRUCT || field.type.kind == .ARRAY {
			// the offset of a whole struct or array is the first thing inside it
			walk_type(check, ir, field_name, field.type, member, at)
			if field.type.kind == .ARRAY && field.type.elem.kind != .STRUCT && field.type.elem.kind != .ARRAY {
				expect_offset(check, field_name, at)
			}
		} else {
			expect_offset(check, field_name, at)
		}
	}
}

@(private = "file")
check_buffer :: proc(check: ^Check, ir: ^IR_Module, reflection: ^d3d11.IShaderReflection, buffer_name: string, layout: Layout, uniforms: []IR_Uniform, prefix: string) {
	buffer := reflection->GetConstantBufferByName(strings.clone_to_cstring(buffer_name, context.temp_allocator))
	buffer_description: d3d11.SHADER_BUFFER_DESC
	if buffer == nil || buffer->GetDesc(&buffer_description) < 0 {
		append(&check.problems, fmt.aprintf("d3dcompiler has no constant buffer `%s`", buffer_name))
		return
	}
	if int(buffer_description.Size) != layout.size {
		append(&check.problems, fmt.aprintf("`%s`: mbsc says %d bytes, d3dcompiler %d", buffer_name, layout.size, buffer_description.Size))
	}
	for entry in layout.entries {
		check.by_name[entry.name] = entry
	}

	if uniforms == nil {
		return
	}
	for uniform in uniforms {
		if uniform.kind != .GAME {
			continue
		}
		variable := buffer->GetVariableByName(strings.clone_to_cstring(uniform.name, context.temp_allocator))
		if variable == nil {
			append(&check.problems, fmt.aprintf("d3dcompiler has no variable `%s`", uniform.name))
			continue
		}
		variable_description: d3d11.SHADER_VARIABLE_DESC
		variable->GetDesc(&variable_description)
		d3d_type := variable->GetType()

		// the variable's own offset and size
		start := int(variable_description.StartOffset)
		if uniform.type.kind == .STRUCT || (uniform.type.kind == .ARRAY && uniform.type.elem.kind == .STRUCT) {
			walk_type(check, ir, uniform.name, uniform.type, d3d_type, start)
		} else if uniform.type.kind == .ARRAY && uniform.type.elem.kind == .ARRAY {
			walk_type(check, ir, uniform.name, uniform.type, d3d_type, start)
		} else {
			expect_offset(check, uniform.name, start)
		}
		if int(variable_description.Size) != packed_size(ir, uniform.type) {
			append(&check.problems, fmt.aprintf("`%s`: mbsc says it takes %d bytes, d3dcompiler %d", uniform.name, packed_size(ir, uniform.type), variable_description.Size))
		}
	}
}

// check_engine_block compares the field offsets of an engine block, by the names the HLSL gives them.
@(private = "file")
check_engine_block :: proc(check: ^Check, ir: ^IR_Module, reflection: ^d3d11.IShaderReflection, buffer_name: string, block: string, kind: Uniform_Kind) {
	buffer := reflection->GetConstantBufferByName(strings.clone_to_cstring(buffer_name, context.temp_allocator))
	if buffer == nil {
		append(&check.problems, fmt.aprintf("d3dcompiler has no constant buffer `%s`", buffer_name))
		return
	}
	for entry in engine_layout(ir, kind).entries {
		variable_name := fmt.aprintf("%s_%s", block, entry.name)
		variable := buffer->GetVariableByName(strings.clone_to_cstring(variable_name, context.temp_allocator))
		if variable == nil {
			append(&check.problems, fmt.aprintf("d3dcompiler has no variable `%s`", variable_name))
			continue
		}
		variable_description: d3d11.SHADER_VARIABLE_DESC
		variable->GetDesc(&variable_description)
		if int(variable_description.StartOffset) != entry.offset {
			append(&check.problems, fmt.aprintf("`%s.%s`: mbsc puts it at %d, d3dcompiler at %d", block, entry.name, entry.offset, variable_description.StartOffset))
		}
	}
}

@(test)
the_layout_is_the_one_d3dcompiler_works_out :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	context.allocator = context.temp_allocator

	source, _ := strings.replace_all(string(#load("testdata/uniforms.mbs", string)), "\r\n", "\n", context.temp_allocator)
	ir, parsed, message := build_ir(source)
	defer destroy_parsed(parsed)
	if message != "" {
		testing.expect(t, false, message)
		return
	}
	hlsl, problems := generate_hlsl(ir, context.temp_allocator)
	if len(problems) > 0 {
		testing.expect(t, false, strings.join(problems, "\n", context.temp_allocator))
		return
	}

	// the game buffer is read by the fragment stage, the frame buffer by the vertex stage
	pixel_blob, pixel_message := compile_blob(hlsl, "fragment_main", "ps_5_0")
	vertex_blob, vertex_message := compile_blob(hlsl, "vertex_main", "vs_5_0")
	if pixel_blob == nil || vertex_blob == nil {
		testing.expectf(t, false, "d3dcompiler rejected the HLSL: %s %s", pixel_message, vertex_message)
		return
	}
	defer pixel_blob->Release()
	defer vertex_blob->Release()
	pixel_reflection := reflect_blob(pixel_blob)
	vertex_reflection := reflect_blob(vertex_blob)
	if pixel_reflection == nil || vertex_reflection == nil {
		testing.expect(t, false, "can't reflect the compiled shaders")
		return
	}
	defer pixel_reflection->Release()
	defer vertex_reflection->Release()

	check := Check {
		by_name = make(map[string]Layout_Entry),
	}
	game := game_layout(ir)
	check_buffer(&check, ir, pixel_reflection, "mbs_game", game, ir.uniforms, "")
	check_buffer(&check, ir, pixel_reflection, "draw_block", engine_layout(ir, .DRAW), nil, "draw")
	check_buffer(&check, ir, vertex_reflection, "frame_block", engine_layout(ir, .FRAME), nil, "frame")

	check_engine_block(&check, ir, pixel_reflection, "draw_block", "draw", .DRAW)
	check_engine_block(&check, ir, vertex_reflection, "frame_block", "frame", .FRAME)

	if len(check.problems) > 0 {
		testing.expectf(t, false, "mbsc and d3dcompiler disagree:\n%s", strings.join(check.problems[:], "\n", context.temp_allocator))
	}
}
