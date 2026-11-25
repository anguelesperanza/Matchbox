package mbsc

import "core:fmt"
import "core:mem/virtual"
import "core:strings"

// The reflection file: what the runtime needs to know about a built shader without reading the shader. The format
// is in docs/shader_reflection.md.

REFLECTION_VERSION :: 1

// reflection_type spells a type the way the file does: no spaces, so each line splits on spaces.
reflection_type :: proc(type: ^Type) -> string {
	#partial switch type.kind {
	case .BOOL:
		return "bool"
	case .F32:
		return "f32"
	case .I32:
		return "i32"
	case .U32:
		return "u32"
	case .VECTOR:
		return fmt.aprintf("[%d]%s", type.count, reflection_type(type.elem))
	case .MATRIX:
		return fmt.aprintf("matrix[%d,%d]f32", type.rows, type.cols)
	}
	return "unknown"
}

@(private = "file")
write_block :: proc(builder: ^strings.Builder, name: string, register: int, layout: Layout) {
	fmt.sbprintfln(builder, "block %s %d %d", name, register, layout.size)
}

@(private = "file")
write_values :: proc(builder: ^strings.Builder, block: string, layout: Layout) {
	for entry in layout.entries {
		fmt.sbprintfln(
			builder,
			"value %s %s %s %d %d %d %d",
			block,
			entry.name,
			reflection_type(entry.type),
			entry.offset,
			entry.size,
			entry.count,
			entry.stride,
		)
	}
}

// generate_reflection writes the reflection file for a module built for the PC. `problems` lists what it can't
// describe; when it isn't empty the text is not complete. Both are allocated with `allocator`.
generate_reflection :: proc(ir: ^IR_Module, allocator := context.allocator) -> (text: string, problems: []string) {
	// The text is built in a scratch arena, because writing it allocates many small strings.
	scratch: virtual.Arena
	_ = virtual.arena_init_growing(&scratch)
	defer virtual.arena_destroy(&scratch)
	context.allocator = virtual.arena_allocator(&scratch)

	found_problems := make([dynamic]string)
	builder := strings.builder_make()
	fmt.sbprintfln(&builder, "mbs-reflection %d", REFLECTION_VERSION)
	fmt.sbprintln(&builder, "target pc")

	// the vertex attributes, in the order of the vertex input struct
	fmt.sbprintln(&builder)
	if ir.vertex_main != nil && len(ir.vertex_main.params) > 0 {
		for field in struct_fields(ir, ir.vertex_main.params[0].type) {
			if field.attr != "" {
				fmt.sbprintfln(&builder, "attribute %s %s", field.attr, reflection_type(field.type))
			}
		}
	}

	has_frame, has_render, has_game := false, false, false
	for uniform in ir.uniforms {
		has_frame ||= uniform.kind == .FRAME
		has_render ||= uniform.kind == .RENDER
		if uniform.kind == .GAME {
			has_game = true
			if uniform.type.kind == .STRUCT && uniform.type.info.name == "" {
				append(&found_problems, fmt.aprintf("the uniform `%s` is a struct written inline; declare the struct with a name first", uniform.name))
			}
		}
	}

	// The lights block is declared by mbsc, not the shader, whenever a light built-in is called (lighting.odin). The
	// specular reads the material from `render`, which the HLSL then declares even when the shader didn't, so the
	// runtime has to bind it as well
	lights := calls_light_builtin(ir) || declares_lights(ir)
	has_render ||= calls_light_builtin(ir)

	fmt.sbprintln(&builder)
	frame := engine_layout(ir, .FRAME)
	draw := engine_layout(ir, .RENDER)
	game := game_layout(ir)
	if has_frame {
		write_block(&builder, "frame", FRAME_REGISTER, frame)
	}
	if has_render {
		write_block(&builder, "render", RENDER_REGISTER, draw)
	}
	if has_game {
		write_block(&builder, "game", GAME_REGISTER, game)
	}
	if lights {
		write_light_reflection(&builder, false)
	}

	fmt.sbprintln(&builder)
	if has_frame {
		write_values(&builder, "frame", frame)
	}
	if has_render {
		write_values(&builder, "render", draw)
	}
	if has_game {
		write_values(&builder, "game", game)
	}
	if lights {
		write_light_reflection(&builder, true)
	}

	if len(ir.textures) > 0 {
		fmt.sbprintln(&builder)
		for texture in ir.textures {
			fmt.sbprintfln(&builder, "texture %s %d", texture.name, texture.slot)
		}
		fmt.sbprintfln(&builder, "sampler %d", SAMPLER_REGISTER)
	}

	kept_problems := make([]string, len(found_problems), allocator)
	for problem, index in found_problems {
		kept_problems[index] = strings.clone(problem, allocator)
	}
	return strings.clone(strings.to_string(builder), allocator), kept_problems
}

// generate_reflection_vita writes the reflection file for a module built for the Vita. There are no constant buffers
// there: the runtime sets a uniform by the name of its parameter in the `.gxp` program (`gfx.set_uniform`), so the
// file lists the names, and the vertex attributes and texture units. A program drops a uniform it doesn't read, so a
// name the runtime can't find in one of the two programs is not a mistake.
generate_reflection_vita :: proc(ir: ^IR_Module, allocator := context.allocator) -> (text: string, problems: []string) {
	scratch: virtual.Arena
	_ = virtual.arena_init_growing(&scratch)
	defer virtual.arena_destroy(&scratch)
	context.allocator = virtual.arena_allocator(&scratch)

	found_problems := make([dynamic]string)
	builder := strings.builder_make()
	fmt.sbprintfln(&builder, "mbs-reflection %d", REFLECTION_VERSION)
	fmt.sbprintln(&builder, "target vita")

	fmt.sbprintln(&builder)
	if ir.vertex_main != nil && len(ir.vertex_main.params) > 0 {
		for field in struct_fields(ir, ir.vertex_main.params[0].type) {
			if field.attr != "" {
				fmt.sbprintfln(&builder, "attribute %s %s", field.attr, reflection_type(field.type))
			}
		}
	}

	fmt.sbprintln(&builder)
	for uniform in ir.uniforms {
		// the lights block is listed below, the same whether declared or brought in by a built-in
		if uniform.kind == .GAME || uniform.kind == .LIGHTS {
			continue
		}
		for entry in engine_layout(ir, uniform.kind).entries {
			fmt.sbprintfln(&builder, "uniform %s_%s %s %d", uniform.name, entry.name, reflection_type(entry.type), entry.count)
		}
	}
	for uniform in ir.uniforms {
		if uniform.kind == .GAME && uniform.type.kind == .STRUCT && uniform.type.info.name == "" {
			append(&found_problems, fmt.aprintf("the uniform `%s` is a struct written inline; declare the struct with a name first", uniform.name))
		}
	}
	for entry in game_layout(ir).entries {
		fmt.sbprintfln(&builder, "uniform %s %s %d", entry.name, reflection_type(entry.type), entry.count)
	}
	// A shader that lights reads the lights uniforms mbsc declares for it (cg.odin), and `render`'s material, which the
	// Cg declares as `render_*` when the shader left the block out. The runtime finds them all by these names
	if calls_light_builtin(ir) || declares_lights(ir) {
		declared_render := calls_light_builtin(ir) == false // only the built-ins bring `render` in
		for uniform in ir.uniforms {
			declared_render ||= uniform.kind == .RENDER
		}
		if declared_render == false {
			for entry in engine_layout(ir, .RENDER).entries {
				fmt.sbprintfln(&builder, "uniform render_%s %s %d", entry.name, reflection_type(entry.type), entry.count)
			}
		}
		fmt.sbprintfln(&builder, "uniform %s [4]f32 0", LIGHT_UNIFORM_NAMES[0])
		for name in LIGHT_UNIFORM_NAMES[1:] {
			fmt.sbprintfln(&builder, "uniform %s [4]f32 %d", name, get_max_lights(.VITA))
		}
	}

	if len(ir.textures) > 0 {
		fmt.sbprintln(&builder)
		for texture in ir.textures {
			fmt.sbprintfln(&builder, "texture %s %d", texture.name, texture.slot)
		}
	}

	kept_problems := make([]string, len(found_problems), allocator)
	for problem, index in found_problems {
		kept_problems[index] = strings.clone(problem, allocator)
	}
	return strings.clone(strings.to_string(builder), allocator), kept_problems
}

// generate_reflection_pica writes the reflection file for a module built for the 3DS. A vertex attribute is the
// register `v<n>` it arrives in, and a uniform is the name it has in the `.shbin` (the runtime finds its register with
// `shaderInstanceGetUniformLocation`), with how many registers it takes. Only the uniforms the vertex program reads are
// listed. A matrix takes one register per row, a row being what `dp4` reads.
generate_reflection_pica :: proc(ir: ^IR_Module, allocator := context.allocator) -> (text: string, problems: []string) {
	scratch: virtual.Arena
	_ = virtual.arena_init_growing(&scratch)
	defer virtual.arena_destroy(&scratch)
	context.allocator = virtual.arena_allocator(&scratch)

	program, found_problems := generate_pica(ir)
	builder := strings.builder_make()
	fmt.sbprintfln(&builder, "mbs-reflection %d", REFLECTION_VERSION)
	fmt.sbprintln(&builder, "target 3ds")

	fmt.sbprintln(&builder)
	if ir.vertex_main != nil && len(ir.vertex_main.params) > 0 {
		for field, index in struct_fields(ir, ir.vertex_main.params[0].type) {
			if field.attr != "" {
				fmt.sbprintfln(&builder, "attribute %s %s %d", field.attr, reflection_type(field.type), index)
			}
		}
	}

	fmt.sbprintln(&builder)
	for uniform in program.uniforms {
		if uniform.is_bool {
			fmt.sbprintfln(&builder, "bool %s", uniform.name)
		} else {
			fmt.sbprintfln(&builder, "uniform %s %s %d", uniform.name, reflection_type(uniform.type), uniform.registers)
		}
	}

	kept_problems := make([]string, len(found_problems), allocator)
	for problem, index in found_problems {
		kept_problems[index] = strings.clone(problem, allocator)
	}
	return strings.clone(strings.to_string(builder), allocator), kept_problems
}
