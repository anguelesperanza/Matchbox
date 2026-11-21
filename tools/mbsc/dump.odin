package mbsc

import "core:fmt"
import "core:mem/virtual"
import "core:strings"

// dump_ir writes the intermediate form as text, for `mbsc --dump-ir` and for the golden tests. The format is
// described in docs/shader_ir.md. The result is allocated with `allocator`.
dump_ir :: proc(ir: ^IR_Module, allocator := context.allocator) -> string {
	// The text is built in a scratch arena, because writing it allocates many small strings.
	scratch: virtual.Arena
	_ = virtual.arena_init_growing(&scratch)
	defer virtual.arena_destroy(&scratch)
	context.allocator = virtual.arena_allocator(&scratch)

	builder := strings.builder_make()
	fmt.sbprintfln(&builder, "target %s", target_name(ir.target))

	for info in ir.structs {
		fmt.sbprintfln(&builder, "\nstruct %s", info.name)
		dump_fields(&builder, info.fields)
	}

	if len(ir.uniforms) > 0 {
		fmt.sbprintln(&builder)
	}
	for uniform in ir.uniforms {
		switch uniform.kind {
		case .FRAME:
			fmt.sbprintfln(&builder, "uniform %s: the engine's frame block", uniform.name)
		case .RENDER:
			fmt.sbprintfln(&builder, "uniform %s: the engine's render block", uniform.name)
		case .GAME:
			fmt.sbprintfln(&builder, "uniform %s: %s", uniform.name, type_name(uniform.type))
		}
		dump_fields(&builder, uniform.fields)
	}
	for texture in ir.textures {
		fmt.sbprintfln(&builder, "texture %s: slot %d", texture.name, texture.slot)
	}

	for info in ir.procs {
		dump_proc(&builder, info)
	}
	return strings.clone(strings.to_string(builder), allocator)
}

@(private = "file")
target_name :: proc(target: Target) -> string {
	switch target {
	case .PC:
		return "pc"
	case .VITA:
		return "vita"
	case .PICA200:
		return "3ds"
	}
	return "?"
}

@(private = "file")
dump_fields :: proc(builder: ^strings.Builder, fields: []IR_Field_Info) {
	for field in fields {
		fmt.sbprintf(builder, "  %s: %s", field.name, type_name(field.type))
		if field.attr != "" {
			fmt.sbprintf(builder, "  attr:%s", field.attr)
		}
		if field.out != "" {
			fmt.sbprintf(builder, "  out:%s", field.out)
		}
		fmt.sbprintln(builder)
	}
}

@(private = "file")
dump_proc :: proc(builder: ^strings.Builder, info: ^IR_Proc) {
	fmt.sbprintf(builder, "\nproc %s(", info.name)
	for param, index in info.params {
		if index > 0 {
			fmt.sbprint(builder, ", ")
		}
		fmt.sbprintf(builder, "%s: %s", var_name(param), type_name(param.type))
	}
	fmt.sbprint(builder, ")")
	if info.result.kind != .VOID {
		fmt.sbprintf(builder, " -> %s", type_name(info.result))
	}
	switch info.stage {
	case .VERTEX:
		fmt.sbprint(builder, "  [vertex stage]")
	case .FRAGMENT:
		fmt.sbprint(builder, "  [fragment stage]")
	case .HELPER:
	}
	fmt.sbprintln(builder)
	dump_statements(builder, info.body, 1)
}

// var_name is how a variable is written: its name and its number, since two variables can share a name.
@(private = "file")
var_name :: proc(var: ^IR_Var) -> string {
	return fmt.aprintf("%s#%d", var.name, var.id)
}

@(private = "file")
indent :: proc(builder: ^strings.Builder, depth: int) {
	for _ in 0 ..< depth {
		fmt.sbprint(builder, "  ")
	}
}

@(private = "file")
dump_statements :: proc(builder: ^strings.Builder, statements: []^IR_Stmt, depth: int) {
	for statement in statements {
		dump_statement(builder, statement, depth)
	}
}

@(private = "file")
dump_statement :: proc(builder: ^strings.Builder, statement: ^IR_Stmt, depth: int) {
	indent(builder, depth)
	switch node in statement.variant {
	case IR_Declare:
		keyword := "var" if node.var.mutable else "const"
		fmt.sbprintf(builder, "%s %s: %s", keyword, var_name(node.var), type_name(node.var.type))
		if node.init != nil {
			fmt.sbprintf(builder, " = %s", expr_text(node.init))
		} else {
			fmt.sbprint(builder, " = zero")
		}
		fmt.sbprintln(builder)
	case IR_Assign:
		fmt.sbprintfln(builder, "%s = %s", expr_text(node.target), expr_text(node.value))
	case IR_If:
		fmt.sbprintfln(builder, "if %s", expr_text(node.condition))
		dump_statements(builder, node.then, depth + 1)
		if len(node.otherwise) > 0 {
			indent(builder, depth)
			fmt.sbprintln(builder, "else")
			dump_statements(builder, node.otherwise, depth + 1)
		}
	case IR_For:
		range := "..="if node.inclusive else "..<"
		fmt.sbprintfln(builder, "for %s in %s%s%s", var_name(node.var), expr_text(node.from), range, expr_text(node.to))
		dump_statements(builder, node.body, depth + 1)
	case IR_Return:
		if node.value != nil {
			fmt.sbprintfln(builder, "return %s", expr_text(node.value))
		} else {
			fmt.sbprintln(builder, "return")
		}
	case IR_Eval:
		fmt.sbprintln(builder, expr_text(node.call))
	case IR_Block:
		fmt.sbprintln(builder, "block")
		dump_statements(builder, node.body, depth + 1)
	}
}

// expr_text writes an expression on one line. A result that isn't obvious from its parts carries its type:
// `(a * b):[4]f32`.
@(private = "file")
expr_text :: proc(expr: ^IR_Expr) -> string {
	switch node in expr.variant {
	case IR_Float:
		return float_text(node.value)
	case IR_Int:
		return fmt.aprintf("%d", node.value) if expr.type.kind == .I32 else fmt.aprintf("%du", node.value)
	case IR_Bool:
		return "true" if node.value else "false"
	case IR_Zero:
		return fmt.aprintf("zero:%s", type_name(expr.type))
	case IR_Var_Ref:
		return var_name(node.var)
	case IR_Uniform_Ref:
		return node.name
	case IR_Texture_Ref:
		return node.name
	case IR_Unary:
		symbol := "-" if node.op == .NEGATE else "!"
		return fmt.aprintf("(%s%s):%s", symbol, expr_text(node.operand), type_name(expr.type))
	case IR_Binary:
		return fmt.aprintf("(%s %s %s):%s", expr_text(node.left), binary_symbol(node.op), expr_text(node.right), type_name(expr.type))
	case IR_Swizzle:
		components := "xyzw"
		letters: [4]u8
		for index in 0 ..< node.count {
			letters[index] = components[node.indices[index]]
		}
		return fmt.aprintf("%s.%s", expr_text(node.base), string(letters[:node.count]))
	case IR_Field:
		return fmt.aprintf("%s.%s", expr_text(node.base), node.name)
	case IR_Index:
		return fmt.aprintf("%s[%s]", expr_text(node.base), expr_text(node.index))
	case IR_Convert:
		return fmt.aprintf("%s(%s)", type_name(expr.type), expr_text(node.operand))
	case IR_Construct:
		return fmt.aprintf("%s{{%s}}", type_name(expr.type), list_text(node.args))
	case IR_Builtin_Call:
		return fmt.aprintf("%s(%s)%s", node.name, list_text(node.args), result_suffix(expr.type))
	case IR_Proc_Call:
		return fmt.aprintf("%s(%s)%s", node.callee.name, list_text(node.args), result_suffix(expr.type))
	}
	return "?"
}

// result_suffix is `:type`, or nothing for a call that gives no value.
@(private = "file")
result_suffix :: proc(type: ^Type) -> string {
	if type.kind == .VOID {
		return ""
	}
	return fmt.aprintf(":%s", type_name(type))
}

@(private = "file")
list_text :: proc(list: []^IR_Expr) -> string {
	parts := make([]string, len(list))
	for item, index in list {
		parts[index] = expr_text(item)
	}
	return strings.join(parts, ", ")
}

@(private = "file")
float_text :: proc(value: f32) -> string {
	text := fmt.aprintf("%v", value)
	for character in transmute([]u8)text {
		if character == '.' || character == 'e' || character == 'E' || character == 'n' || character == 'i' {
			return text
		}
	}
	return fmt.aprintf("%s.0", text)
}

@(private = "file")
binary_symbol :: proc(op: Binary_Op) -> string {
	switch op {
	case .ADD:
		return "+"
	case .SUB:
		return "-"
	case .MUL:
		return "*"
	case .DIV:
		return "/"
	case .LESS:
		return "<"
	case .GREATER:
		return ">"
	case .LESS_EQUAL:
		return "<="
	case .GREATER_EQUAL:
		return ">="
	case .EQUAL:
		return "=="
	case .NOT_EQUAL:
		return "!="
	case .AND:
		return "&&"
	case .OR:
		return "||"
	}
	return "?"
}
