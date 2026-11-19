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

	has_frame, has_draw, has_game := false, false, false
	for uniform in ir.uniforms {
		has_frame ||= uniform.kind == .FRAME
		has_draw ||= uniform.kind == .DRAW
		if uniform.kind == .GAME {
			has_game = true
			if uniform.type.kind == .STRUCT && uniform.type.info.name == "" {
				append(&found_problems, fmt.aprintf("the uniform `%s` is a struct written inline; declare the struct with a name first", uniform.name))
			}
		}
	}

	fmt.sbprintln(&builder)
	frame := engine_layout(ir, .FRAME)
	draw := engine_layout(ir, .DRAW)
	game := game_layout(ir)
	if has_frame {
		write_block(&builder, "frame", FRAME_REGISTER, frame)
	}
	if has_draw {
		write_block(&builder, "draw", DRAW_REGISTER, draw)
	}
	if has_game {
		write_block(&builder, "game", GAME_REGISTER, game)
	}

	fmt.sbprintln(&builder)
	if has_frame {
		write_values(&builder, "frame", frame)
	}
	if has_draw {
		write_values(&builder, "draw", draw)
	}
	if has_game {
		write_values(&builder, "game", game)
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
