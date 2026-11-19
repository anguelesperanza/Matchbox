package mbsc

import "core:fmt"
import "core:mem/virtual"
import "core:odin/ast"
import "core:odin/tokenizer"
import "core:strconv"

// Lowering: from the checked syntax tree to the intermediate form (ir.odin). It relies on the checker having
// accepted the shader, so a case that "can't happen" stops with an internal error instead of a diagnostic.

@(private = "file")
Lowerer :: struct {
	module:    ^Module,
	scopes:    [dynamic]map[string]^IR_Var,
	procs:     map[string]^IR_Proc, // the procedures started, by name
	ordered:   [dynamic]^IR_Proc, // finished procedures, callees first
	next_id:   int, // the next variable number in the current procedure
}

// lower_module builds the intermediate form of a module that checked without errors. It lives in the parsed
// shader's arena, so destroy_parsed frees it.
lower_module :: proc(module: ^Module) -> ^IR_Module {
	context.allocator = virtual.arena_allocator(&module.parsed.arena)

	lowerer := Lowerer {
		module = module,
	}
	ir := new(IR_Module)
	ir.target = module.target

	structs := make([dynamic]IR_Struct)
	for info in module.structs {
		append(&structs, lower_struct(module, info))
	}
	ir.structs = structs[:]

	uniforms := make([dynamic]IR_Uniform)
	for uniform in module.uniforms {
		lowered := IR_Uniform {
			name = uniform.name,
			kind = uniform.kind,
			type = module.uniform_types[uniform.name],
		}
		if uniform.block != nil {
			lowered.fields = lower_struct(module, uniform.block).fields
		}
		append(&uniforms, lowered)
	}
	ir.uniforms = uniforms[:]

	textures := make([dynamic]IR_Texture)
	for texture in module.textures {
		append(&textures, IR_Texture{name = texture.name, slot = texture.slot})
	}
	ir.textures = textures[:]

	if module.vertex_main != nil {
		ir.vertex_main = lower_proc(&lowerer, module.vertex_main.name)
		ir.vertex_main.stage = .VERTEX
	}
	if module.fragment_main != nil {
		ir.fragment_main = lower_proc(&lowerer, module.fragment_main.name)
		ir.fragment_main.stage = .FRAGMENT
	}
	ir.procs = lowerer.ordered[:]
	return ir
}

@(private = "file")
lower_struct :: proc(module: ^Module, info: ^Struct_Info) -> IR_Struct {
	fields := make([]IR_Field_Info, len(info.fields))
	types := module.struct_fields[info]
	for field, index in info.fields {
		fields[index] = IR_Field_Info {
			name = field.name,
			type = types[index],
			attr = field.attr,
			out  = field.out,
		}
	}
	return IR_Struct{name = info.name, fields = fields}
}

// ---- procedures -------------------------------------------------------------------------------------------

// lower_proc lowers a procedure the first time it is asked for, and calls on the ones it uses before it finishes,
// so `ordered` lists callees first. The checker has already rejected recursion.
@(private = "file")
lower_proc :: proc(l: ^Lowerer, name: string) -> ^IR_Proc {
	if existing, found := l.procs[name]; found {
		return existing
	}
	info := find_proc(l.module, name)
	result := new(IR_Proc)
	result.name = name
	l.procs[name] = result

	signature := l.module.signatures[name]
	result.result = signature.result

	// Each procedure has its own variable numbers and scopes; the one that called this one resumes afterwards.
	saved_scopes, saved_id := l.scopes, l.next_id
	l.scopes = make([dynamic]map[string]^IR_Var)
	l.next_id = 0
	defer {
		l.scopes, l.next_id = saved_scopes, saved_id
	}

	push_scope(l)
	params := make([dynamic]^IR_Var)
	lit := info.lit
	if lit.type != nil && lit.type.params != nil {
		index := 0
		for field in lit.type.params.list {
			for field_name in field.names {
				identifier := field_name.derived.(^ast.Ident)
				append(&params, declare_var(l, identifier.name, signature.params[index], .PARAM, false))
				index += 1
			}
		}
	}
	result.params = params[:]

	if body, is_block := lit.body.derived.(^ast.Block_Stmt); is_block {
		result.body = lower_statements(l, body.stmts)
	}
	append(&l.ordered, result)
	return result
}

// ---- scopes -----------------------------------------------------------------------------------------------

@(private = "file")
push_scope :: proc(l: ^Lowerer) {
	append(&l.scopes, make(map[string]^IR_Var))
}

@(private = "file")
pop_scope :: proc(l: ^Lowerer) {
	pop(&l.scopes)
}

@(private = "file")
declare_var :: proc(l: ^Lowerer, name: string, type: ^Type, kind: IR_Var_Kind, mutable: bool) -> ^IR_Var {
	var := new(IR_Var)
	var^ = IR_Var {
		id      = l.next_id,
		name    = name,
		type    = type,
		kind    = kind,
		mutable = mutable,
	}
	l.next_id += 1
	if name != "_" {
		l.scopes[len(l.scopes) - 1][name] = var
	}
	return var
}

@(private = "file")
find_var :: proc(l: ^Lowerer, name: string) -> ^IR_Var {
	for index := len(l.scopes) - 1; index >= 0; index -= 1 {
		if var, found := l.scopes[index][name]; found {
			return var
		}
	}
	return nil
}

// ---- statements -------------------------------------------------------------------------------------------

@(private = "file")
lower_statements :: proc(l: ^Lowerer, statements: []^ast.Stmt) -> []^IR_Stmt {
	list := make([dynamic]^IR_Stmt)
	for statement in statements {
		lower_statement(l, statement, &list)
	}
	return list[:]
}

// lower_scoped lowers a statement that opens its own scope: a block, or the single statement after `do`.
@(private = "file")
lower_scoped :: proc(l: ^Lowerer, statement: ^ast.Stmt) -> []^IR_Stmt {
	if statement == nil {
		return nil
	}
	push_scope(l)
	defer pop_scope(l)
	if block, is_block := statement.derived.(^ast.Block_Stmt); is_block {
		return lower_statements(l, block.stmts)
	}
	list := make([dynamic]^IR_Stmt)
	lower_statement(l, statement, &list)
	return list[:]
}

@(private = "file")
add_statement :: proc(list: ^[dynamic]^IR_Stmt, variant: $T) {
	statement := new(IR_Stmt)
	statement.variant = variant
	append(list, statement)
}

@(private = "file")
lower_statement :: proc(l: ^Lowerer, statement: ^ast.Stmt, list: ^[dynamic]^IR_Stmt) {
	if statement == nil {
		return
	}
	#partial switch node in statement.derived {
	case ^ast.Value_Decl:
		lower_declaration(l, node, list)
	case ^ast.Assign_Stmt:
		lower_assignment(l, node, list)
	case ^ast.Expr_Stmt:
		add_statement(list, IR_Eval{call = lower_expr(l, node.expr)})
	case ^ast.Block_Stmt:
		add_statement(list, IR_Block{body = lower_scoped(l, statement)})
	case ^ast.If_Stmt:
		lower_if(l, node, list)
	case ^ast.When_Stmt:
		// settled now: only the branch for the target stays, as a block of its own
		value, _ := eval_when(l.module, node.cond)
		chosen := node.body if value else node.else_stmt
		if chosen != nil {
			add_statement(list, IR_Block{body = lower_scoped(l, chosen)})
		}
	case ^ast.Range_Stmt:
		lower_for(l, node, list)
	case ^ast.Return_Stmt:
		value: ^IR_Expr
		if len(node.results) == 1 {
			value = lower_expr(l, node.results[0])
		}
		add_statement(list, IR_Return{value = value})
	case:
		internal_error("a statement the checker accepted")
	}
}

@(private = "file")
lower_declaration :: proc(l: ^Lowerer, decl: ^ast.Value_Decl, list: ^[dynamic]^IR_Stmt) {
	name := decl.names[0].derived.(^ast.Ident).name

	// The value is lowered before the name exists, so `x := x` means the outer `x`.
	init: ^IR_Expr
	if len(decl.values) == 1 {
		init = lower_expr(l, decl.values[0])
	}

	var := declare_var(l, name, l.module.decl_types[decl], .LOCAL, decl.is_mutable)
	add_statement(list, IR_Declare{var = var, init = init})
}

@(private = "file")
lower_assignment :: proc(l: ^Lowerer, node: ^ast.Assign_Stmt, list: ^[dynamic]^IR_Stmt) {
	target := lower_expr(l, node.lhs[0])
	value := lower_expr(l, node.rhs[0])

	op: Binary_Op
	#partial switch node.op.kind {
	case .Eq:
		add_statement(list, IR_Assign{target = target, value = value})
		return
	case .Add_Eq:
		op = .ADD
	case .Sub_Eq:
		op = .SUB
	case .Mul_Eq:
		op = .MUL
	case .Quo_Eq:
		op = .DIV
	case:
		internal_error("an assignment operator the checker accepted")
	}

	// `a += b` is `a = a + b`; the left side is lowered again so the two uses don't share a node
	current := lower_expr(l, node.lhs[0])
	combined := new(IR_Expr)
	combined.type = target.type
	combined.variant = IR_Binary{op = op, left = current, right = value}
	add_statement(list, IR_Assign{target = target, value = combined})
}

@(private = "file")
lower_if :: proc(l: ^Lowerer, node: ^ast.If_Stmt, list: ^[dynamic]^IR_Stmt) {
	// `if x := f(); x > 0.0 { ... }` becomes a block holding the declaration and the `if`
	if node.init != nil {
		push_scope(l)
		defer pop_scope(l)
		inner := make([dynamic]^IR_Stmt)
		lower_statement(l, node.init, &inner)
		add_statement(&inner, lower_plain_if(l, node))
		add_statement(list, IR_Block{body = inner[:]})
		return
	}
	add_statement(list, lower_plain_if(l, node))
}

@(private = "file")
lower_plain_if :: proc(l: ^Lowerer, node: ^ast.If_Stmt) -> IR_If {
	result := IR_If {
		condition = lower_expr(l, node.cond),
		then      = lower_scoped(l, node.body),
		otherwise = lower_scoped(l, node.else_stmt),
	}
	return result
}

@(private = "file")
lower_for :: proc(l: ^Lowerer, node: ^ast.Range_Stmt, list: ^[dynamic]^IR_Stmt) {
	range := node.expr.derived.(^ast.Binary_Expr)
	from := lower_expr(l, range.left)
	to := lower_expr(l, range.right)

	push_scope(l)
	defer pop_scope(l)
	counter := "_"
	if len(node.vals) == 1 {
		if identifier, is_ident := node.vals[0].derived.(^ast.Ident); is_ident {
			counter = identifier.name
		}
	}
	var := declare_var(l, counter, &TYPE_I32, .LOOP, false)
	add_statement(list, IR_For{var = var, from = from, to = to, inclusive = range.op.kind == .Range_Full, body = lower_scoped(l, node.body)})
}

// ---- expressions ------------------------------------------------------------------------------------------

@(private = "file")
make_expr :: proc(type: ^Type, variant: $T) -> ^IR_Expr {
	result := new(IR_Expr)
	result.type = type
	result.variant = variant
	return result
}

@(private = "file")
type_of :: proc(l: ^Lowerer, expr: ^ast.Expr) -> ^Type {
	if type, found := l.module.types[expr]; found {
		return type
	}
	internal_error("an expression the checker didn't type")
	return nil
}

@(private = "file")
lower_expr :: proc(l: ^Lowerer, expr: ^ast.Expr) -> ^IR_Expr {
	type := type_of(l, expr)
	#partial switch node in expr.derived {
	case ^ast.Paren_Expr:
		return lower_expr(l, node.expr)
	case ^ast.Basic_Lit:
		return lower_literal(node, type)
	case ^ast.Ident:
		return lower_identifier(l, node, type)
	case ^ast.Unary_Expr:
		operand := lower_expr(l, node.expr)
		#partial switch node.op.kind {
		case .Add:
			return operand
		case .Sub:
			return make_expr(type, IR_Unary{op = .NEGATE, operand = operand})
		case .Not:
			return make_expr(type, IR_Unary{op = .NOT, operand = operand})
		}
	case ^ast.Binary_Expr:
		return make_expr(type, IR_Binary{op = binary_op(node.op.kind), left = lower_expr(l, node.left), right = lower_expr(l, node.right)})
	case ^ast.Selector_Expr:
		return lower_selector(l, node, type)
	case ^ast.Index_Expr:
		return make_expr(type, IR_Index{base = lower_expr(l, node.expr), index = lower_expr(l, node.index)})
	case ^ast.Comp_Lit:
		return lower_comp_lit(l, node, type)
	case ^ast.Call_Expr:
		return lower_call(l, node, type)
	}
	internal_error("an expression the checker accepted")
	return nil
}

@(private = "file")
lower_literal :: proc(node: ^ast.Basic_Lit, type: ^Type) -> ^IR_Expr {
	#partial switch node.tok.kind {
	case .Integer:
		value, _ := strconv.parse_i64_maybe_prefixed(node.tok.text)
		return make_expr(type, IR_Int{value = value})
	case .Float:
		value, _ := strconv.parse_f32(node.tok.text)
		return make_expr(type, IR_Float{value = value})
	}
	internal_error("a literal the checker accepted")
	return nil
}

@(private = "file")
lower_identifier :: proc(l: ^Lowerer, node: ^ast.Ident, type: ^Type) -> ^IR_Expr {
	switch node.name {
	case "true":
		return make_expr(type, IR_Bool{value = true})
	case "false":
		return make_expr(type, IR_Bool{value = false})
	}
	if var := find_var(l, node.name); var != nil {
		return make_expr(var.type, IR_Var_Ref{var = var})
	}

	symbol, found := l.module.symbols[node]
	if found == false {
		internal_error("a name the checker didn't resolve")
	}
	#partial switch symbol.kind {
	case .UNIFORM:
		for uniform in l.module.uniforms {
			if uniform.name == node.name {
				return make_expr(type, IR_Uniform_Ref{name = node.name, kind = uniform.kind})
			}
		}
	case .TEXTURE:
		for texture in l.module.textures {
			if texture.name == node.name {
				return make_expr(type, IR_Texture_Ref{name = node.name, slot = texture.slot})
			}
		}
	case .CONSTANT:
		for constant in l.module.constants {
			if constant.name == node.name {
				// The value is written where the name was. Its own names mean the shader's top level, not a
				// local that happens to share a name.
				saved := l.scopes
				l.scopes = make([dynamic]map[string]^IR_Var)
				defer l.scopes = saved
				return lower_expr(l, constant.value)
			}
		}
	}
	internal_error("a name the checker accepted")
	return nil
}

@(private = "file")
lower_selector :: proc(l: ^Lowerer, node: ^ast.Selector_Expr, type: ^Type) -> ^IR_Expr {
	base := lower_expr(l, node.expr)
	#partial switch base.type.kind {
	case .STRUCT:
		for field, index in base.type.info.fields {
			if field.name == node.field.name {
				return make_expr(type, IR_Field{base = base, index = index, name = field.name})
			}
		}
	case .VECTOR:
		swizzle := IR_Swizzle {
			base  = base,
			count = len(node.field.name),
		}
		position_set := node.field.name[0] == 'x' || node.field.name[0] == 'y' || node.field.name[0] == 'z' || node.field.name[0] == 'w'
		for character, index in transmute([]u8)node.field.name {
			swizzle.indices[index] = component_index(character, position_set)
		}
		return make_expr(type, swizzle)
	}
	internal_error("a field the checker accepted")
	return nil
}

@(private = "file")
component_index :: proc(character: u8, position_set: bool) -> u8 {
	if position_set {
		switch character {
		case 'x':
			return 0
		case 'y':
			return 1
		case 'z':
			return 2
		}
		return 3
	}
	switch character {
	case 'r':
		return 0
	case 'g':
		return 1
	case 'b':
		return 2
	}
	return 3
}

@(private = "file")
binary_op :: proc(kind: tokenizer.Token_Kind) -> Binary_Op {
	#partial switch kind {
	case .Add:
		return .ADD
	case .Sub:
		return .SUB
	case .Mul:
		return .MUL
	case .Quo:
		return .DIV
	case .Lt:
		return .LESS
	case .Gt:
		return .GREATER
	case .Lt_Eq:
		return .LESS_EQUAL
	case .Gt_Eq:
		return .GREATER_EQUAL
	case .Cmp_Eq:
		return .EQUAL
	case .Not_Eq:
		return .NOT_EQUAL
	case .Cmp_And:
		return .AND
	case .Cmp_Or:
		return .OR
	}
	internal_error("an operator the checker accepted")
	return .ADD
}

@(private = "file")
lower_comp_lit :: proc(l: ^Lowerer, node: ^ast.Comp_Lit, type: ^Type) -> ^IR_Expr {
	if len(node.elems) == 0 {
		return make_expr(type, IR_Zero{})
	}
	args := make([dynamic]^IR_Expr)

	if type.kind != .STRUCT {
		for element in node.elems {
			append(&args, lower_expr(l, element))
		}
		return make_expr(type, IR_Construct{args = args[:]})
	}

	// A struct literal lists every field in order: given by name or by position, and zero when left out.
	info := type.info
	field_types := l.module.struct_fields[info]
	given := make([]^IR_Expr, len(info.fields))
	for element, index in node.elems {
		if field_value, is_named := element.derived.(^ast.Field_Value); is_named {
			name := field_value.field.derived.(^ast.Ident).name
			for field, field_index in info.fields {
				if field.name == name {
					given[field_index] = lower_expr(l, field_value.value)
				}
			}
		} else {
			given[index] = lower_expr(l, element)
		}
	}
	for value, index in given {
		append(&args, value if value != nil else make_expr(field_types[index], IR_Zero{}))
	}
	return make_expr(type, IR_Construct{args = args[:]})
}

@(private = "file")
lower_call :: proc(l: ^Lowerer, node: ^ast.Call_Expr, type: ^Type) -> ^IR_Expr {
	callee := node.expr.derived.(^ast.Ident)
	args := make([]^IR_Expr, len(node.args))
	for argument, index in node.args {
		args[index] = lower_expr(l, argument)
	}

	switch callee.name {
	case "f32", "i32", "u32":
		return make_expr(type, IR_Convert{operand = args[0]})
	}
	if symbol, found := l.module.symbols[callee]; found && symbol.kind == .PROC {
		return make_expr(type, IR_Proc_Call{callee = lower_proc(l, callee.name), args = args})
	}
	return make_expr(type, IR_Builtin_Call{name = callee.name, args = args})
}

@(private = "file")
internal_error :: proc(what: string) {
	fmt.panicf("mbsc: internal error: lowering met %s; this is a bug in mbsc", what)
}
