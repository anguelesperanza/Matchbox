package mbsc

import "core:fmt"
import "core:odin/ast"
import "core:odin/tokenizer"
import "core:strconv"
import "core:strings"

// The type checker (S1, step 4). It reads the inside of every procedure, gives every expression a type, and
// reports MBS-E13 (type mismatch), MBS-E14 (name not found), MBS-E7 (loop bound), MBS-E27 (assigning to
// something read-only), and, with callgraph.odin, MBS-E17 (recursion) and MBS-E26 (a fragment-only built-in
// reached from the vertex stage). Which targets can run each operation is not decided here.
//
// Numbers never convert on their own: `x + 1` with an f32 `x` is an error, because `1` is an integer
// (docs/shader_language.md, section 3).

Symbol_Kind :: enum {
	LOCAL, // a variable, a loop counter or a local constant of a procedure
	PARAM,
	UNIFORM,
	TEXTURE,
	CONSTANT, // `NAME :: value` at the top level
	PROC,
	TYPE,
	TARGET,
}

Symbol :: struct {
	kind:    Symbol_Kind,
	name:    string,
	type:    ^Type, // for a PROC, its result type
	mutable: bool,
	node:    ^ast.Node, // where it is declared
	loop_counter: bool, // the counter of a `for`: the 3DS can index with it
}

Call_Edge :: struct {
	caller:  string,
	callee:  string,
	builtin: bool,
	node:    ^ast.Node, // the call
}

Proc_Types :: struct {
	params: []^Type,
	result: ^Type, // TYPE_VOID when the procedure returns nothing
}

@(private = "file")
Checker :: struct {
	module:       ^Module,
	scopes:       [dynamic]map[string]Symbol,
	proc_name:    string,
	result:       ^Type, // what the procedure being checked must return
	when_values:  map[^ast.When_Stmt]bool,
	struct_types: map[^Struct_Info]^Type,
	resolving:    map[^Struct_Info]bool,
	const_depth:  int,
}

// check_bodies types every procedure of the module. Call it once the declarations are free of errors.
check_bodies :: proc(module: ^Module) {
	checker := Checker {
		module = module,
	}
	module.types = make(map[^ast.Expr]^Type)
	module.symbols = make(map[^ast.Ident]Symbol)
	module.signatures = make(map[string]Proc_Types)
	module.struct_fields = make(map[^Struct_Info][]^Type)
	module.uniform_types = make(map[string]^Type)
	module.decl_types = make(map[^ast.Value_Decl]^Type)

	for info in module.structs {
		resolve_struct_fields(&checker, info)
	}
	for uniform in module.uniforms {
		if uniform.block != nil {
			resolve_struct_fields(&checker, uniform.block)
		}
	}
	for uniform in module.uniforms {
		module.uniform_types[uniform.name] = uniform_type(&checker, uniform)
	}
	for &info in module.procs {
		resolve_signature(&checker, &info)
	}
	for &info in module.procs {
		check_procedure(&checker, &info)
	}
	check_call_graph(module)
	check_target(module)
}

// ---- types ------------------------------------------------------------------------------------------------

@(private = "file")
resolve_struct_fields :: proc(c: ^Checker, info: ^Struct_Info) {
	if _, done := c.module.struct_fields[info]; done {
		return
	}
	if c.resolving[info] {
		err(c, "MBS-E13", "a struct can't contain itself", info.node, "this struct refers to itself", "a struct's size has to be known, and one that contains itself has no size", "use a fixed array of a different struct, or drop the field")
		return
	}
	c.resolving[info] = true
	types := make([]^Type, len(info.fields))
	for field, index in info.fields {
		types[index] = resolve_type(c, field.type)
	}
	c.resolving[info] = false
	c.module.struct_fields[info] = types
}

// struct_type returns the one type value for a struct.
@(private = "file")
struct_type :: proc(c: ^Checker, info: ^Struct_Info) -> ^Type {
	if existing, found := c.struct_types[info]; found {
		return existing
	}
	created := make_struct(info)
	c.struct_types[info] = created
	return created
}

@(private = "file")
resolve_type :: proc(c: ^Checker, expr: ^ast.Expr) -> ^Type {
	if expr == nil {
		return &TYPE_INVALID
	}
	#partial switch node in expr.derived {
	case ^ast.Paren_Expr:
		return resolve_type(c, node.expr)
	case ^ast.Ident:
		switch node.name {
		case "f32":
			return &TYPE_F32
		case "i32":
			return &TYPE_I32
		case "u32":
			return &TYPE_U32
		case "bool":
			return &TYPE_BOOL
		case "Texture2D":
			return &TYPE_TEXTURE2D
		}
		if info := find_struct(c.module, node.name); info != nil {
			resolve_struct_fields(c, info)
			return struct_type(c, info)
		}
		names := make([dynamic]string)
		append(&names, "f32", "i32", "u32", "bool", "Texture2D")
		for info in c.module.structs {
			append(&names, info.name)
		}
		help := "declare it with `Name :: struct { ... }`"
		if suggestion, close := suggest_name(node.name, names[:]); close {
			help = fmt.aprintf("did you mean `%s`?", suggestion)
		}
		err(c, "MBS-E14", fmt.aprintf("cannot find the type `%s` in this shader", node.name), node, "not found", "the shader doesn't declare a type with this name", help)
		return &TYPE_INVALID
	case ^ast.Array_Type:
		count, ok := const_int(c, node.len)
		if node.len == nil || ok == false || count < 1 {
			err(c, "MBS-E13", "an array length must be a constant whole number", node.len if node.len != nil else expr, "not a constant", "the length of an array is known when the shader is built", "write a number, like `[4]f32`, or a constant declared with `::`")
			return &TYPE_INVALID
		}
		elem := resolve_type(c, node.elem)
		if is_invalid(elem) {
			return elem
		}
		return make_sized_array(elem, count)
	case ^ast.Matrix_Type:
		rows, rows_ok := const_int(c, node.row_count)
		cols, cols_ok := const_int(c, node.column_count)
		if rows_ok == false || cols_ok == false || rows < 2 || rows > 4 || cols < 2 || cols > 4 {
			err(c, "MBS-E13", "a matrix has 2 to 4 rows and 2 to 4 columns", expr, "unsupported size", "the targets have matrices from 2x2 to 4x4", "write `matrix[4, 4]f32`")
			return &TYPE_INVALID
		}
		if elem, is_ident := node.elem.derived.(^ast.Ident); is_ident == false || elem.name != "f32" {
			err(c, "MBS-E13", "a matrix holds `f32`", node.elem, "not `f32`", "there are only float matrices", "write `matrix[4, 4]f32`")
			return &TYPE_INVALID
		}
		return make_matrix(rows, cols)
	case ^ast.Struct_Type:
		for info in c.module.structs {
			if info.node == &node.node {
				return struct_type(c, info)
			}
		}
		for uniform in c.module.uniforms {
			if uniform.block != nil && uniform.block.node == &node.node {
				return struct_type(c, uniform.block)
			}
		}
	}
	err(c, "MBS-E13", "this is not a type", expr, "expected a type here", "a type is `f32`, `i32`, `bool`, a vector, a matrix, an array or a struct", "")
	return &TYPE_INVALID
}

@(private = "file")
resolve_signature :: proc(c: ^Checker, info: ^Proc_Info) {
	signature := Proc_Types {
		result = &TYPE_VOID,
	}
	params := make([dynamic]^Type)
	lit := info.lit
	if lit.type != nil {
		if lit.type.params != nil {
			for field in lit.type.params.list {
				resolved := resolve_type(c, field.type)
				for _ in 0 ..< max(len(field.names), 1) {
					append(&params, resolved)
				}
			}
		}
		if lit.type.results != nil && len(lit.type.results.list) > 0 {
			signature.result = resolve_type(c, lit.type.results.list[0].type)
		}
	}
	signature.params = params[:]
	c.module.signatures[info.name] = signature
}

// ---- constants --------------------------------------------------------------------------------------------

// const_int evaluates an expression that is a whole number known when mbsc runs: a literal, a top-level
// constant, or arithmetic on those.
@(private = "file")
const_int :: proc(c: ^Checker, expr: ^ast.Expr) -> (value: int, ok: bool) {
	if expr == nil || c.const_depth > 32 {
		return 0, false
	}
	c.const_depth += 1
	defer c.const_depth -= 1

	#partial switch node in expr.derived {
	case ^ast.Basic_Lit:
		if node.tok.kind == .Integer {
			parsed, parse_ok := strconv.parse_i64_maybe_prefixed(node.tok.text)
			return int(parsed), parse_ok
		}
	case ^ast.Paren_Expr:
		return const_int(c, node.expr)
	case ^ast.Unary_Expr:
		if node.op.kind == .Sub {
			inner, inner_ok := const_int(c, node.expr)
			return -inner, inner_ok
		}
	case ^ast.Ident:
		for constant in c.module.constants {
			if constant.name == node.name {
				return const_int(c, constant.value)
			}
		}
	case ^ast.Binary_Expr:
		left, left_ok := const_int(c, node.left)
		right, right_ok := const_int(c, node.right)
		if left_ok && right_ok {
			#partial switch node.op.kind {
			case .Add:
				return left + right, true
			case .Sub:
				return left - right, true
			case .Mul:
				return left * right, true
			case .Quo:
				if right != 0 {
					return left / right, true
				}
			}
		}
	}
	return 0, false
}

// ---- scopes -----------------------------------------------------------------------------------------------

@(private = "file")
push_scope :: proc(c: ^Checker) {
	append(&c.scopes, make(map[string]Symbol))
}

@(private = "file")
pop_scope :: proc(c: ^Checker) {
	pop(&c.scopes)
}

@(private = "file")
declare :: proc(c: ^Checker, name_node: ^ast.Ident, kind: Symbol_Kind, type: ^Type, mutable: bool, decl: ^ast.Node) {
	if name_node.name == "_" {
		return
	}
	scope := &c.scopes[len(c.scopes) - 1]
	if _, taken := scope[name_node.name]; taken {
		err(c, "MBS-E25", fmt.aprintf("`%s` is declared twice", name_node.name), name_node, "second declaration", "a name can be declared once in the same block", "use a different name, or assign to the first one")
		return
	}
	symbol := Symbol {
		kind    = kind,
		name    = name_node.name,
		type    = type,
		mutable = mutable,
		node    = decl,
	}
	scope[name_node.name] = symbol
	c.module.symbols[name_node] = symbol
}

// lookup finds what a name means: a local, then the shader's top-level names.
@(private = "file")
lookup :: proc(c: ^Checker, name: string) -> (symbol: Symbol, found: bool) {
	for index := len(c.scopes) - 1; index >= 0; index -= 1 {
		if local, ok := c.scopes[index][name]; ok {
			return local, true
		}
	}
	module := c.module
	for uniform in module.uniforms {
		if uniform.name == name {
			return Symbol{kind = .UNIFORM, name = name, type = uniform_type(c, uniform), node = uniform.node}, true
		}
	}
	for texture in module.textures {
		if texture.name == name {
			return Symbol{kind = .TEXTURE, name = name, type = &TYPE_TEXTURE2D, node = texture.node}, true
		}
	}
	for constant in module.constants {
		if constant.name == name {
			return Symbol{kind = .CONSTANT, name = name, type = constant_type(c, constant), node = constant.node}, true
		}
	}
	for info in module.procs {
		if info.name == name {
			result: ^Type = &TYPE_VOID
			if signature, has_signature := module.signatures[name]; has_signature {
				result = signature.result
			}
			return Symbol{kind = .PROC, name = name, type = result, node = info.node}, true
		}
	}
	if info := find_struct(module, name); info != nil {
		return Symbol{kind = .TYPE, name = name, type = struct_type(c, info), node = info.node}, true
	}
	if name == "TARGET" {
		return Symbol{kind = .TARGET, name = name, type = &TYPE_INVALID}, true
	}
	return {}, false
}

@(private = "file")
uniform_type :: proc(c: ^Checker, uniform: Uniform_Info) -> ^Type {
	if uniform.block != nil && uniform.type != nil {
		if _, is_inline := uniform.type.derived.(^ast.Struct_Type); is_inline {
			return struct_type(c, uniform.block)
		}
	}
	return resolve_type(c, uniform.type)
}

@(private = "file")
constant_type :: proc(c: ^Checker, constant: Constant_Info) -> ^Type {
	if cached, found := c.module.types[constant.value]; found {
		return cached
	}
	return check_expr(c, constant.value, nil)
}

// all_names lists every name a program could have meant, for "did you mean".
@(private = "file")
all_names :: proc(c: ^Checker) -> []string {
	names := make([dynamic]string)
	for scope in c.scopes {
		for name in scope {
			append(&names, name)
		}
	}
	module := c.module
	for uniform in module.uniforms {
		append(&names, uniform.name)
	}
	for texture in module.textures {
		append(&names, texture.name)
	}
	for constant in module.constants {
		append(&names, constant.name)
	}
	return names[:]
}

// ---- procedures and statements ----------------------------------------------------------------------------

@(private = "file")
check_procedure :: proc(c: ^Checker, info: ^Proc_Info) {
	lit := info.lit
	if lit.body == nil {
		return
	}
	signature := c.module.signatures[info.name]
	c.proc_name = info.name
	c.result = signature.result

	push_scope(c)
	defer pop_scope(c)

	if lit.type != nil && lit.type.params != nil {
		index := 0
		for field in lit.type.params.list {
			for name in field.names {
				if identifier, is_ident := name.derived.(^ast.Ident); is_ident && index < len(signature.params) {
					declare(c, identifier, .PARAM, signature.params[index], false, field)
				}
				index += 1
			}
		}
	}

	body, is_block := lit.body.derived.(^ast.Block_Stmt)
	if is_block == false {
		return
	}
	check_block_statements(c, body.stmts)

	if signature.result.kind != .VOID && is_invalid(signature.result) == false && always_returns(c, lit.body) == false {
		err(
			c,
			"MBS-E13",
			fmt.aprintf("`%s` doesn't return a value on every path", info.name),
			body.close,
			1,
			"reaches the end without a `return`",
			fmt.aprintf("`%s` returns `%s`, so each way through it must end in a `return`", info.name, type_name(signature.result)),
			"add a `return` at the end, or give every `if` an `else` that returns",
		)
	}
}

@(private = "file")
check_block_statements :: proc(c: ^Checker, statements: []^ast.Stmt) {
	for statement in statements {
		check_statement(c, statement)
	}
}

@(private = "file")
check_scoped :: proc(c: ^Checker, statement: ^ast.Stmt) {
	if statement == nil {
		return
	}
	push_scope(c)
	defer pop_scope(c)
	#partial switch node in statement.derived {
	case ^ast.Block_Stmt:
		check_block_statements(c, node.stmts)
	case:
		check_statement(c, statement)
	}
}

@(private = "file")
check_statement :: proc(c: ^Checker, statement: ^ast.Stmt) {
	if statement == nil {
		return
	}
	#partial switch node in statement.derived {
	case ^ast.Value_Decl:
		check_local_declaration(c, node)
	case ^ast.Assign_Stmt:
		check_assignment(c, node)
	case ^ast.Expr_Stmt:
		call, is_call := node.expr.derived.(^ast.Call_Expr)
		if is_call == false {
			err(c, "MBS-E13", "this expression does nothing", node.expr, "its value is not used", "a statement must do something: assign, declare, call or return", "")
			check_expr(c, node.expr, nil)
			return
		}
		check_call(c, call, node.expr)
	case ^ast.Block_Stmt:
		check_scoped(c, statement)
	case ^ast.If_Stmt:
		push_scope(c)
		defer pop_scope(c)
		if node.init != nil {
			check_statement(c, node.init)
		}
		condition := check_value(c, node.cond, nil)
		record_use(c, .CONDITION, node.cond, count_comparisons(node.cond))
		if is_invalid(condition) == false && condition.kind != .BOOL {
			err(c, "MBS-E13", fmt.aprintf("an `if` needs a `bool`, found `%s`", type_name(condition)), node.cond, fmt.aprintf("this is `%s`", type_name(condition)), "a condition is true or false, and numbers don't convert on their own", "compare it, for example `x != 0.0`")
		}
		check_scoped(c, node.body)
		check_scoped(c, node.else_stmt)
	case ^ast.When_Stmt:
		value, ok := eval_when(c.module, node.cond)
		if ok == false {
			return
		}
		c.when_values[node] = value
		check_scoped(c, node.body if value else node.else_stmt)
	case ^ast.Range_Stmt:
		check_range(c, node)
	case ^ast.Return_Stmt:
		check_return(c, node)
	}
}

@(private = "file")
check_local_declaration :: proc(c: ^Checker, decl: ^ast.Value_Decl) {
	if len(decl.names) != 1 {
		return
	}
	name_ident, is_ident := decl.names[0].derived.(^ast.Ident)
	if is_ident == false {
		return
	}

	declared: ^Type = nil
	if decl.type != nil {
		declared = resolve_type(c, decl.type)
	}

	result := declared
	if len(decl.values) == 1 {
		value := check_value(c, decl.values[0], declared)
		if declared == nil {
			if comp, is_literal := decl.values[0].derived.(^ast.Comp_Lit); is_literal && comp.type == nil {
				value = &TYPE_INVALID
			}
			result = value
		} else if is_invalid(value) == false && is_invalid(declared) == false && types_equal(declared, value) == false {
			mismatch(c, decl.values[0], declared, value)
		}
	} else if declared == nil {
		result = &TYPE_INVALID
	}
	declare(c, name_ident, .LOCAL, result, decl.is_mutable, decl)
	c.module.decl_types[decl] = result
}

@(private = "file")
check_assignment :: proc(c: ^Checker, node: ^ast.Assign_Stmt) {
	if len(node.lhs) != 1 || len(node.rhs) != 1 {
		return
	}
	target := check_expr(c, node.lhs[0], nil)
	check_assignable(c, node.lhs[0])

	if node.op.kind == .Eq {
		value := check_value(c, node.rhs[0], target)
		if is_invalid(value) == false && is_invalid(target) == false && types_equal(target, value) == false {
			mismatch(c, node.rhs[0], target, value)
		}
		return
	}

	// `a += b` means `a = a + b`
	value := check_value(c, node.rhs[0], nil)
	operation: tokenizer.Token_Kind
	#partial switch node.op.kind {
	case .Add_Eq:
		operation = .Add
	case .Sub_Eq:
		operation = .Sub
	case .Mul_Eq:
		operation = .Mul
	case .Quo_Eq:
		operation = .Quo
	}
	if is_invalid(target) || is_invalid(value) {
		return
	}
	combined, ok := binary_type(operation, target, value)
	if ok {
		record_arithmetic(c, node, operation, target, value)
	}
	if ok == false {
		binary_mismatch(c, node.lhs[0], node.rhs[0], node.op, target, value)
		return
	}
	if types_equal(combined, target) == false {
		err(c, "MBS-E13", fmt.aprintf("`%s` gives `%s`, which doesn't fit in `%s`", node.op.text, type_name(combined), type_name(target)), node.rhs[0], fmt.aprintf("the result is `%s`", type_name(combined)), "the result of the operation must have the type of the variable", "write the assignment out: `a = a * b`, with a variable of the right type")
	}
}

// check_assignable reports MBS-E27 when an assignment's target can't be changed.
@(private = "file")
check_assignable :: proc(c: ^Checker, target: ^ast.Expr) {
	root := target
	repeated_swizzle: ^ast.Selector_Expr
	for {
		#partial switch node in root.derived {
		case ^ast.Paren_Expr:
			root = node.expr
			continue
		case ^ast.Selector_Expr:
			if base_type, has_type := c.module.types[node.expr]; has_type && base_type.kind == .VECTOR {
				if swizzle_repeats(node.field.name) {
					repeated_swizzle = node
				}
			}
			root = node.expr
			continue
		case ^ast.Index_Expr:
			root = node.expr
			continue
		}
		break
	}

	identifier, is_ident := root.derived.(^ast.Ident)
	if is_ident == false {
		err(c, "MBS-E27", "this can't be assigned to", target, "not a variable", "only a local variable, or a part of one, can change", "assign to a local variable instead")
		return
	}
	symbol, found := lookup(c, identifier.name)
	if found == false {
		return // already reported as MBS-E14
	}
	if symbol.kind != .LOCAL || symbol.mutable == false {
		what, fix: string
		switch symbol.kind {
		case .UNIFORM:
			what = fmt.aprintf("`%s` is a uniform, and uniforms are read-only in a shader", identifier.name)
			fix = "copy it into a local variable, change that, and use the copy"
		case .PARAM:
			what = fmt.aprintf("`%s` is a parameter, and a parameter can't be changed", identifier.name)
			fix = fmt.aprintf("copy it into a local first: `copy := %s`", identifier.name)
		case .LOCAL, .CONSTANT:
			what = fmt.aprintf("`%s` is a constant", identifier.name)
			fix = "declare a variable instead of a constant: `name := value`"
		case .TEXTURE, .PROC, .TYPE, .TARGET:
			what = fmt.aprintf("`%s` can't be assigned to", identifier.name)
			fix = "assign to a local variable instead"
		}
		err(c, "MBS-E27", fmt.aprintf("cannot assign to `%s`", identifier.name), target, "read-only", what, fix)
		return
	}
	if repeated_swizzle != nil {
		err(c, "MBS-E27", fmt.aprintf("`.%s` names a component twice, so it can't be assigned to", repeated_swizzle.field.name), repeated_swizzle, "repeated component", "an assignment to `v.xx` has no single meaning", "assign each component on its own line")
	}
}

@(private = "file")
check_range :: proc(c: ^Checker, node: ^ast.Range_Stmt) {
	push_scope(c)
	defer pop_scope(c)

	binary, is_binary := node.expr.derived.(^ast.Binary_Expr)
	if is_binary {
		for bound in ([]^ast.Expr{binary.left, binary.right}) {
			t := check_value(c, bound, nil)
			if is_invalid(t) {
				continue
			}
			if t.kind != .I32 {
				mismatch(c, bound, &TYPE_I32, t)
				continue
			}
			if bound_is_known(c, bound) == false {
				err(
					c,
					"MBS-E7",
					"the loop bound is not a constant",
					bound,
					"not known when the shader is built",
					"a loop runs a count that is known when mbsc runs: a constant, or an integer uniform",
					"use a constant (`4`, or `COUNT :: 4`), or declare `@(uniform) count: i32`",
				)
			}
		}
	}

	if len(node.vals) == 1 {
		if identifier, is_ident := node.vals[0].derived.(^ast.Ident); is_ident {
			declare(c, identifier, .LOCAL, &TYPE_I32, false, node)
			if declared, found := c.scopes[len(c.scopes) - 1][identifier.name]; found {
				declared.loop_counter = true
				c.scopes[len(c.scopes) - 1][identifier.name] = declared
				c.module.symbols[identifier] = declared
			}
		}
	}
	check_scoped(c, node.body)
}

// bound_is_known is true for a constant, or an integer uniform.
@(private = "file")
bound_is_known :: proc(c: ^Checker, expr: ^ast.Expr) -> bool {
	if _, ok := const_int(c, expr); ok {
		return true
	}
	if identifier, is_ident := expr.derived.(^ast.Ident); is_ident {
		if symbol, found := lookup(c, identifier.name); found && symbol.kind == .UNIFORM && symbol.type.kind == .I32 {
			return true
		}
	}
	return false
}

@(private = "file")
check_return :: proc(c: ^Checker, node: ^ast.Return_Stmt) {
	if c.result.kind == .VOID {
		if len(node.results) > 0 {
			err(c, "MBS-E13", fmt.aprintf("`%s` returns nothing, so `return` takes no value", c.proc_name), node.results[0], "unexpected value", "the procedure has no `->` result type", "remove the value, or give the procedure a result type")
			check_value(c, node.results[0], nil)
		}
		return
	}
	if len(node.results) != 1 {
		err(c, "MBS-E13", fmt.aprintf("`%s` must return a `%s`", c.proc_name, type_name(c.result)), node, "no value to return", "a procedure with a result type returns one value", fmt.aprintf("write `return <a %s>`", type_name(c.result)))
		return
	}
	value := check_value(c, node.results[0], c.result)
	if is_invalid(value) == false && is_invalid(c.result) == false && types_equal(c.result, value) == false {
		mismatch(c, node.results[0], c.result, value)
	}
}

// always_returns is true when every path through a statement ends in a `return`.
@(private = "file")
always_returns :: proc(c: ^Checker, statement: ^ast.Stmt) -> bool {
	if statement == nil {
		return false
	}
	#partial switch node in statement.derived {
	case ^ast.Return_Stmt:
		return true
	case ^ast.Block_Stmt:
		for inner in node.stmts {
			if always_returns(c, inner) {
				return true
			}
		}
	case ^ast.If_Stmt:
		return node.else_stmt != nil && always_returns(c, node.body) && always_returns(c, node.else_stmt)
	case ^ast.When_Stmt:
		if value, known := c.when_values[node]; known {
			return always_returns(c, node.body if value else node.else_stmt)
		}
	}
	return false
}

// ---- expressions ------------------------------------------------------------------------------------------

// check_value is check_expr for a place that needs a value, so a call that returns nothing is an error.
@(private = "file")
check_value :: proc(c: ^Checker, expr: ^ast.Expr, expected: ^Type) -> ^Type {
	t := check_expr(c, expr, expected)
	if t.kind == .VOID {
		err(c, "MBS-E13", "this call has no value", expr, "returns nothing", "the procedure has no result type, so there is nothing to use", "")
		return &TYPE_INVALID
	}
	return t
}

// check_expr gives an expression its type. `expected` is what the place around it wants; only a literal
// with no type of its own, like `{}`, uses it.
@(private = "file")
check_expr :: proc(c: ^Checker, expr: ^ast.Expr, expected: ^Type) -> ^Type {
	t := check_expr_inner(c, expr, expected)
	c.module.types[expr] = t
	return t
}

@(private = "file")
check_expr_inner :: proc(c: ^Checker, expr: ^ast.Expr, expected: ^Type) -> ^Type {
	#partial switch node in expr.derived {
	case ^ast.Basic_Lit:
		#partial switch node.tok.kind {
		case .Integer:
			return &TYPE_I32
		case .Float:
			return &TYPE_F32
		}
		return &TYPE_INVALID
	case ^ast.Paren_Expr:
		return check_expr(c, node.expr, expected)
	case ^ast.Ident:
		return check_identifier(c, node)
	case ^ast.Unary_Expr:
		return check_unary(c, node)
	case ^ast.Binary_Expr:
		return check_binary(c, node)
	case ^ast.Comp_Lit:
		return check_literal(c, node, expected)
	case ^ast.Selector_Expr:
		return check_selector(c, node)
	case ^ast.Index_Expr:
		return check_index(c, node)
	case ^ast.Call_Expr:
		return check_call(c, node, expr)
	case ^ast.Implicit_Selector_Expr:
		err(c, "MBS-E13", fmt.aprintf("`.%s` has nothing to refer to here", node.field.name), expr, "no enum in a shader", "a leading `.name` only appears in `@(uniform = .FRAME)` and in `when TARGET == .PC`", "")
		return &TYPE_INVALID
	}
	return &TYPE_INVALID
}

@(private = "file")
check_identifier :: proc(c: ^Checker, node: ^ast.Ident) -> ^Type {
	switch node.name {
	case "true", "false":
		return &TYPE_BOOL
	}
	symbol, found := lookup(c, node.name)
	if found == false {
		help := "check the spelling, or declare it"
		if suggestion, close := suggest_name(node.name, all_names(c)); close {
			help = fmt.aprintf("did you mean `%s`?", suggestion)
		}
		err(c, "MBS-E14", fmt.aprintf("cannot find `%s` in this scope", node.name), node, "not found", "no variable, uniform, texture or constant has this name here", help)
		return &TYPE_INVALID
	}
	c.module.symbols[node] = symbol
	if symbol.kind == .UNIFORM {
		record_use(c, .UNIFORM_READ, node, 0, node.name)
	}

	#partial switch symbol.kind {
	case .PROC:
		err(c, "MBS-E13", fmt.aprintf("`%s` is a procedure; call it with `%s(...)`", node.name, node.name), node, "not called", "a procedure is only used by calling it", "")
		return &TYPE_INVALID
	case .TYPE:
		err(c, "MBS-E13", fmt.aprintf("`%s` is a type, not a value", node.name), node, "a type", "a struct's name can't be used as a value", fmt.aprintf("write `%s{{...}}` to build one, or `value: %s` to declare one", node.name, node.name))
		return &TYPE_INVALID
	case .TARGET:
		err(c, "MBS-E23", "`TARGET` is only available in a `when`", node, "not in a `when`", "`TARGET` is settled before the shader is compiled, so it can't be tested while the shader runs", "write `when TARGET == .PICA200 { ... }`")
		return &TYPE_INVALID
	}
	return symbol.type
}

@(private = "file")
check_unary :: proc(c: ^Checker, node: ^ast.Unary_Expr) -> ^Type {
	operand := check_value(c, node.expr, nil)
	if is_invalid(operand) {
		return operand
	}
	#partial switch node.op.kind {
	case .Not:
		if operand.kind == .BOOL {
			return operand
		}
	case .Sub, .Add:
		if is_scalar_number(operand) || operand.kind == .VECTOR || operand.kind == .MATRIX {
			return operand
		}
	}
	err(c, "MBS-E13", fmt.aprintf("cannot apply `%s` to `%s`", node.op.text, type_name(operand)), node, fmt.aprintf("this is `%s`", type_name(operand)), "`!` is for `bool`, and `-` is for numbers, vectors and matrices", "")
	return &TYPE_INVALID
}

@(private = "file")
check_binary :: proc(c: ^Checker, node: ^ast.Binary_Expr) -> ^Type {
	left := check_value(c, node.left, nil)
	right := check_value(c, node.right, nil)
	if is_invalid(left) || is_invalid(right) {
		return &TYPE_INVALID
	}
	result, ok := binary_type(node.op.kind, left, right)
	if ok == false {
		binary_mismatch(c, node.left, node.right, node.op, left, right)
		return &TYPE_INVALID
	}
	record_arithmetic(c, node, node.op.kind, left, right)
	return result
}

// binary_type is the type of `a op b`, or ok = false when the operation isn't defined for those types.
binary_type :: proc(op: tokenizer.Token_Kind, a, b: ^Type) -> (result: ^Type, ok: bool) {
	#partial switch op {
	case .Cmp_And, .Cmp_Or:
		if a.kind == .BOOL && b.kind == .BOOL {
			return &TYPE_BOOL, true
		}
	case .Lt, .Gt, .Lt_Eq, .Gt_Eq:
		if is_scalar_number(a) && a.kind == b.kind {
			return &TYPE_BOOL, true
		}
	case .Cmp_Eq, .Not_Eq:
		if (is_scalar_number(a) || a.kind == .BOOL) && a.kind == b.kind {
			return &TYPE_BOOL, true
		}
	case .Add, .Sub, .Mul, .Quo:
		return arithmetic_type(op, a, b)
	}
	return nil, false
}

@(private = "file")
arithmetic_type :: proc(op: tokenizer.Token_Kind, a, b: ^Type) -> (result: ^Type, ok: bool) {
	if is_scalar_number(a) && a.kind == b.kind {
		return a, true
	}
	if a.kind == .VECTOR && types_equal(a, b) {
		return a, true
	}
	if a.kind == .VECTOR && is_scalar_number(b) && b.kind == a.elem.kind {
		return a, true
	}
	if is_scalar_number(a) && b.kind == .VECTOR && a.kind == b.elem.kind {
		return b, true
	}

	if a.kind == .MATRIX || b.kind == .MATRIX {
		#partial switch op {
		case .Add, .Sub:
			if a.kind == .MATRIX && b.kind == .MATRIX && a.rows == b.rows && a.cols == b.cols {
				return a, true
			}
		case .Mul:
			if a.kind == .MATRIX && b.kind == .MATRIX && a.cols == b.rows {
				return make_matrix(a.rows, b.cols), true
			}
			if a.kind == .MATRIX && is_float_vector(b) && a.cols == b.count {
				return make_vector(&TYPE_F32, a.rows), true
			}
			if is_float_vector(a) && b.kind == .MATRIX && a.count == b.rows {
				return make_vector(&TYPE_F32, b.cols), true
			}
			if a.kind == .MATRIX && b.kind == .F32 {
				return a, true
			}
			if a.kind == .F32 && b.kind == .MATRIX {
				return b, true
			}
		case .Quo:
			if a.kind == .MATRIX && b.kind == .F32 {
				return a, true
			}
		}
	}
	return nil, false
}

// binary_mismatch explains an operation that isn't defined for its two types, with a fix when there is an obvious one.
@(private = "file")
binary_mismatch :: proc(c: ^Checker, left_expr, right_expr: ^ast.Expr, op: tokenizer.Token, a, b: ^Type) {
	note := "the operation is not defined for these two types"
	help := ""

	a_base, b_base := a, b
	if a.kind == .VECTOR {
		a_base = a.elem
	}
	if b.kind == .VECTOR {
		b_base = b.elem
	}
	both_scalar := is_scalar_number(a) && is_scalar_number(b)

	switch {
	case is_scalar_number(a_base) && is_scalar_number(b_base) && a_base.kind != b_base.kind:
		note = "numbers never convert on their own, so the two sides must have the same type"
		if literal, is_literal := right_expr.derived.(^ast.Basic_Lit); is_literal && b_base.kind == .I32 && a_base.kind == .F32 && literal.tok.kind == .Integer {
			help = fmt.aprintf("write the number with a dot: `%s.0`", literal.tok.text)
		} else if left_literal, is_left_literal := left_expr.derived.(^ast.Basic_Lit); is_left_literal && a_base.kind == .I32 && b_base.kind == .F32 && left_literal.tok.kind == .Integer {
			help = fmt.aprintf("write the number with a dot: `%s.0`", left_literal.tok.text)
		} else if both_scalar && a.kind == .F32 {
			help = fmt.aprintf("convert the other side: `f32(%s)`", node_text(c.module.parsed, right_expr))
		} else if both_scalar && b.kind == .F32 {
			help = fmt.aprintf("convert the other side: `f32(%s)`", node_text(c.module.parsed, left_expr))
		}
	case (a.kind == .VECTOR || b.kind == .VECTOR) && (op.kind == .Lt || op.kind == .Gt || op.kind == .Lt_Eq || op.kind == .Gt_Eq || op.kind == .Cmp_Eq || op.kind == .Not_Eq):
		note = "a comparison gives one `bool`, so it compares single numbers"
		help = "compare a component: `v.x < w.x`"
	case a.kind == .VECTOR && b.kind == .VECTOR && a.count != b.count:
		note = "two vectors must have the same length"
	case a.kind == .MATRIX || b.kind == .MATRIX:
		note = "a matrix multiplies a vector or matrix with a matching size, and adds only to a matrix of the same size"
	case a.kind == .BOOL || b.kind == .BOOL:
		note = "`bool` values are combined with `&&`, `||` and `!`, not arithmetic"
	}

	err(
		c,
		"MBS-E13",
		fmt.aprintf("cannot apply `%s` to `%s` and `%s`", op.text, type_name(a), type_name(b)),
		op.pos,
		len(op.text),
		fmt.aprintf("`%s` on the left, `%s` on the right", type_name(a), type_name(b)),
		note,
		help,
	)
}

// mismatch reports a value of the wrong type where another type was wanted.
@(private = "file")
mismatch :: proc(c: ^Checker, node: ^ast.Expr, expected, found: ^Type) {
	help := ""
	note := "numbers never convert on their own, and the two types must be the same"
	if literal, is_literal := node.derived.(^ast.Basic_Lit); is_literal && literal.tok.kind == .Integer && expected.kind == .F32 {
		help = fmt.aprintf("write the number with a dot: `%s.0`", literal.tok.text)
	} else if is_scalar_number(expected) && is_scalar_number(found) {
		help = fmt.aprintf("convert it: `%s(%s)`", type_name(expected), node_text(c.module.parsed, node))
	} else if expected.kind == .BOOL {
		help = "compare it to get a `bool`, for example `x != 0.0`"
	}
	err(c, "MBS-E13", fmt.aprintf("expected `%s`, found `%s`", type_name(expected), type_name(found)), node, fmt.aprintf("this is `%s`", type_name(found)), note, help)
}

@(private = "file")
check_literal :: proc(c: ^Checker, node: ^ast.Comp_Lit, expected: ^Type) -> ^Type {
	literal_type: ^Type
	if node.type != nil {
		literal_type = resolve_type(c, node.type)
	} else if expected != nil && is_invalid(expected) == false {
		literal_type = expected
	} else {
		if expected == nil {
			err(c, "MBS-E13", "cannot tell the type of this literal", node, "no type", "a literal with no type in front of it takes the type of the place it is used", "write the type: `[4]f32{...}`")
		}
		for element in node.elems {
			check_expr(c, element, nil)
		}
		return &TYPE_INVALID
	}
	if is_invalid(literal_type) {
		for element in node.elems {
			check_expr(c, element, nil)
		}
		return literal_type
	}

	#partial switch literal_type.kind {
	case .VECTOR, .ARRAY:
		check_positional(c, node, literal_type.elem, literal_type.count, literal_type)
	case .MATRIX:
		check_positional(c, node, &TYPE_F32, literal_type.rows * literal_type.cols, literal_type)
	case .STRUCT:
		check_struct_literal(c, node, literal_type)
	case:
		err(c, "MBS-E13", fmt.aprintf("`%s` can't be written as a `{{...}}` literal", type_name(literal_type)), node, "not a vector, matrix, array or struct", "", "")
		return &TYPE_INVALID
	}
	return literal_type
}

@(private = "file")
check_positional :: proc(c: ^Checker, node: ^ast.Comp_Lit, elem: ^Type, count: int, whole: ^Type) {
	if len(node.elems) != 0 && len(node.elems) != count {
		err(c, "MBS-E13", fmt.aprintf("`%s` needs %d values, found %d", type_name(whole), count, len(node.elems)), node, fmt.aprintf("%d values", len(node.elems)), "a literal lists every component, or none for all zeros", fmt.aprintf("write all %d, or `{{}}` for zeros", count))
	}
	for element in node.elems {
		if _, is_named := element.derived.(^ast.Field_Value); is_named {
			err(c, "MBS-E13", "a vector, matrix or array literal can't name its elements", element, "named element", "", "write the values in order")
			continue
		}
		value := check_value(c, element, elem)
		if is_invalid(value) == false && types_equal(value, elem) == false {
			mismatch(c, element, elem, value)
		}
	}
}

@(private = "file")
check_struct_literal :: proc(c: ^Checker, node: ^ast.Comp_Lit, struct_type: ^Type) {
	info := struct_type.info
	field_types := c.module.struct_fields[info]
	if len(node.elems) == 0 {
		return
	}

	_, named := node.elems[0].derived.(^ast.Field_Value)
	if named == false && len(node.elems) != len(info.fields) {
		err(c, "MBS-E13", fmt.aprintf("`%s` has %d fields, found %d values", type_name(struct_type), len(info.fields), len(node.elems)), node, fmt.aprintf("%d values", len(node.elems)), "a positional literal gives every field, in order", "name the fields: `Name{field = value}`")
	}

	for element, index in node.elems {
		if field_value, is_named := element.derived.(^ast.Field_Value); is_named {
			field_name, is_ident := field_value.field.derived.(^ast.Ident)
			if is_ident == false {
				continue
			}
			found := -1
			for field, field_index in info.fields {
				if field.name == field_name.name {
					found = field_index
				}
			}
			if found < 0 {
				names := make([dynamic]string)
				for field in info.fields {
					append(&names, field.name)
				}
				help := fmt.aprintf("the fields are: %s", strings.join(names[:], ", "))
				if suggestion, close := suggest_name(field_name.name, names[:]); close {
					help = fmt.aprintf("did you mean `%s`?", suggestion)
				}
				err(c, "MBS-E14", fmt.aprintf("`%s` has no field `%s`", type_name(struct_type), field_name.name), field_name, "not a field", "", help)
				check_expr(c, field_value.value, nil)
				continue
			}
			expected := field_types[found] if found < len(field_types) else &TYPE_INVALID
			value := check_value(c, field_value.value, expected)
			if is_invalid(value) == false && is_invalid(expected) == false && types_equal(value, expected) == false {
				mismatch(c, field_value.value, expected, value)
			}
		} else if index < len(field_types) {
			value := check_value(c, element, field_types[index])
			if is_invalid(value) == false && is_invalid(field_types[index]) == false && types_equal(value, field_types[index]) == false {
				mismatch(c, element, field_types[index], value)
			}
		}
	}
}

@(private = "file")
check_selector :: proc(c: ^Checker, node: ^ast.Selector_Expr) -> ^Type {
	base := check_expr(c, node.expr, nil)
	if is_invalid(base) {
		return base
	}
	name := node.field.name

	#partial switch base.kind {
	case .STRUCT:
		info := base.info
		field_types := c.module.struct_fields[info]
		for field, index in info.fields {
			if field.name == name {
				return field_types[index] if index < len(field_types) else &TYPE_INVALID
			}
		}
		report_unknown_field(c, node, base)
		return &TYPE_INVALID
	case .VECTOR:
		result, ok := swizzle_type(base, name)
		if ok {
			return result
		}
		err(c, "MBS-E13", fmt.aprintf("`%s` has no component or swizzle `.%s`", type_name(base), name), node.field, "not a swizzle of this vector", fmt.aprintf("a `%s` has %d components: %s", type_name(base), base.count, components_text(base.count)), "use `x y z w` or `r g b a`, up to the vector's length, and don't mix the two sets")
		return &TYPE_INVALID
	}
	err(c, "MBS-E13", fmt.aprintf("`%s` has no fields", type_name(base)), node.field, fmt.aprintf("`.%s` on `%s`", name, type_name(base)), "only a struct has named fields, and only a vector has components", "")
	return &TYPE_INVALID
}

@(private = "file")
components_text :: proc(count: int) -> string {
	switch count {
	case 2:
		return "x y (or r g)"
	case 3:
		return "x y z (or r g b)"
	}
	return "x y z w (or r g b a)"
}

// A field the struct doesn't have. When the struct is one of the engine's blocks the message is the engine's.
@(private = "file")
report_unknown_field :: proc(c: ^Checker, node: ^ast.Selector_Expr, base: ^Type) {
	name := node.field.name
	block_name := ""
	engine: []Engine_Field
	for uniform in c.module.uniforms {
		if uniform.block == base.info && uniform.kind != .GAME {
			block_name = get_engine_block_name(uniform.kind)
			engine = get_engine_fields(uniform.kind)
		}
	}

	if block_name != "" {
		for engine_field in engine {
			if engine_field.name == name {
				err(c, "MBS-E14", fmt.aprintf("this shader doesn't declare `%s.%s`", block_name, name), node.field, "not declared", fmt.aprintf("the engine provides `%s`, but the shader's `%s` block leaves it out", name, block_name), fmt.aprintf("add `%s: %s` to the block", name, display_type(engine_field.type)))
				return
			}
		}
		names := make([dynamic]string)
		for engine_field in engine {
			append(&names, engine_field.name)
		}
		help := "use one of the engine's fields"
		if suggestion, close := suggest_name(name, names[:]); close {
			help = fmt.aprintf("did you mean `%s`?", suggestion)
		}
		err(c, "MBS-E18", fmt.aprintf("the engine's `%s` block has no field `%s`", block_name, name), node.field, "not a field of the engine's block", fmt.aprintf("`%s` has: %s", block_name, strings.join(names[:], ", ")), help)
		return
	}

	names := make([dynamic]string)
	for field in base.info.fields {
		append(&names, field.name)
	}
	help := fmt.aprintf("the fields are: %s", strings.join(names[:], ", "))
	if suggestion, close := suggest_name(name, names[:]); close {
		help = fmt.aprintf("did you mean `%s`?", suggestion)
	}
	err(c, "MBS-E14", fmt.aprintf("`%s` has no field `%s`", type_name(base), name), node.field, "not a field", "no field of this name exists", help)
}

// swizzle_type is the type of `v.xyz`, or ok = false when the letters aren't valid for the vector.
swizzle_type :: proc(vector: ^Type, name: string) -> (result: ^Type, ok: bool) {
	if len(name) < 1 || len(name) > 4 {
		return nil, false
	}
	position_set := name[0] == 'x' || name[0] == 'y' || name[0] == 'z' || name[0] == 'w'
	for character in transmute([]u8)name {
		index: int
		if position_set {
			switch character {
			case 'x':
				index = 0
			case 'y':
				index = 1
			case 'z':
				index = 2
			case 'w':
				index = 3
			case:
				return nil, false
			}
		} else {
			switch character {
			case 'r':
				index = 0
			case 'g':
				index = 1
			case 'b':
				index = 2
			case 'a':
				index = 3
			case:
				return nil, false
			}
		}
		if index >= vector.count {
			return nil, false
		}
	}
	if len(name) == 1 {
		return vector.elem, true
	}
	return make_vector(vector.elem, len(name)), true
}

@(private = "file")
swizzle_repeats :: proc(name: string) -> bool {
	for first in 0 ..< len(name) {
		for second in first + 1 ..< len(name) {
			if name[first] == name[second] {
				return true
			}
		}
	}
	return false
}

@(private = "file")
check_index :: proc(c: ^Checker, node: ^ast.Index_Expr) -> ^Type {
	base := check_expr(c, node.expr, nil)
	index := check_value(c, node.index, nil)
	if is_invalid(base) {
		return base
	}
	if base.kind != .ARRAY && base.kind != .VECTOR {
		note := "only arrays and vectors can be indexed"
		if base.kind == .MATRIX {
			note = "a matrix can't be indexed in a shader; pass the rows you need as vectors"
		}
		err(c, "MBS-E13", fmt.aprintf("cannot index `%s`", type_name(base)), node.expr, fmt.aprintf("this is `%s`", type_name(base)), note, "")
		return &TYPE_INVALID
	}
	if is_invalid(index) == false && index.kind != .I32 && index.kind != .U32 {
		err(c, "MBS-E13", fmt.aprintf("an index must be a whole number, found `%s`", type_name(index)), node.index, fmt.aprintf("this is `%s`", type_name(index)), "indexes are `i32` or `u32`", fmt.aprintf("convert it: `i32(%s)`", node_text(c.module.parsed, node.index)))
	} else if is_invalid(index) == false && index_is_fixed(c, node.index) == false && index_is_float_cast(c, node.index) == false {
		record_use(c, .DYNAMIC_INDEX, node.index)
	}
	return base.elem
}

// ---- calls ------------------------------------------------------------------------------------------------

@(private = "file")
check_call :: proc(c: ^Checker, node: ^ast.Call_Expr, expr: ^ast.Expr) -> ^Type {
	result := check_call_inner(c, node)
	c.module.types[expr] = result
	return result
}

@(private = "file")
check_call_inner :: proc(c: ^Checker, node: ^ast.Call_Expr) -> ^Type {
	callee, is_ident := node.expr.derived.(^ast.Ident)
	if is_ident == false {
		err(c, "MBS-E13", "only a procedure or a built-in can be called", node.expr, "not a name", "a shader calls procedures by name", "")
		for argument in node.args {
			check_expr(c, argument, nil)
		}
		return &TYPE_INVALID
	}

	for argument in node.args {
		if field_value, is_named := argument.derived.(^ast.Field_Value); is_named {
			err(c, "MBS-E13", "a call can't name its arguments", field_value, "named argument", "arguments are given in order", "write the values without the names")
			return &TYPE_INVALID
		}
	}

	switch callee.name {
	case "f32", "i32", "u32":
		return check_conversion(c, node, callee)
	}

	if symbol, found := lookup(c, callee.name); found {
		c.module.symbols[callee] = symbol
		#partial switch symbol.kind {
		case .PROC:
			return check_procedure_call(c, node, callee)
		case .LOCAL, .PARAM, .UNIFORM, .TEXTURE, .CONSTANT:
			err(c, "MBS-E13", fmt.aprintf("`%s` is not a procedure", callee.name), callee, "can't be called", fmt.aprintf("`%s` is a %s", callee.name, symbol_word(symbol.kind)), "")
			return &TYPE_INVALID
		case .TYPE:
			err(c, "MBS-E13", fmt.aprintf("`%s` is a type; write `%s{{...}}` to build one", callee.name, callee.name), callee, "a type", "", "")
			return &TYPE_INVALID
		}
	}

	if builtin, found := find_builtin(callee.name); found {
		return check_builtin_call(c, node, callee, builtin)
	}

	for argument in node.args {
		check_expr(c, argument, nil)
	}
	if entry, found := find_not_builtin(callee.name); found {
		err(c, "MBS-E14", fmt.aprintf("`%s` is not a built-in of the shader language", callee.name), callee, "not available", entry.reason, entry.help)
		return &TYPE_INVALID
	}

	names := make([dynamic]string)
	for builtin in BUILTINS {
		append(&names, builtin.name)
	}
	for info in c.module.procs {
		append(&names, info.name)
	}
	help := "check the spelling; the built-in functions are listed in docs/shader_language.md, section 13"
	if suggestion, close := suggest_name(callee.name, names[:]); close {
		help = fmt.aprintf("did you mean `%s`?", suggestion)
	}
	err(c, "MBS-E14", fmt.aprintf("cannot find the procedure `%s`", callee.name), callee, "not found", "it is neither a procedure of this shader nor a built-in", help)
	return &TYPE_INVALID
}

@(private = "file")
symbol_word :: proc(kind: Symbol_Kind) -> string {
	switch kind {
	case .LOCAL:
		return "variable"
	case .PARAM:
		return "parameter"
	case .UNIFORM:
		return "uniform"
	case .TEXTURE:
		return "texture"
	case .CONSTANT:
		return "constant"
	case .PROC:
		return "procedure"
	case .TYPE:
		return "type"
	case .TARGET:
		return "target"
	}
	return "name"
}

@(private = "file")
check_conversion :: proc(c: ^Checker, node: ^ast.Call_Expr, callee: ^ast.Ident) -> ^Type {
	result: ^Type
	switch callee.name {
	case "f32":
		result = &TYPE_F32
	case "i32":
		result = &TYPE_I32
	case:
		result = &TYPE_U32
	}
	if len(node.args) != 1 {
		err(c, "MBS-E13", fmt.aprintf("`%s(...)` takes one value, found %d", callee.name, len(node.args)), node, "wrong number of arguments", "a conversion changes one number to another type", fmt.aprintf("write `%s(x)`", callee.name))
		for argument in node.args {
			check_expr(c, argument, nil)
		}
		return result
	}
	argument := check_value(c, node.args[0], nil)
	if is_invalid(argument) == false && is_scalar_number(argument) == false {
		err(c, "MBS-E13", fmt.aprintf("cannot convert `%s` to `%s`", type_name(argument), callee.name), node.args[0], fmt.aprintf("this is `%s`", type_name(argument)), "conversions are between `f32`, `i32` and `u32`", "convert one component at a time: `f32(v.x)`")
	}
	return result
}

@(private = "file")
check_procedure_call :: proc(c: ^Checker, node: ^ast.Call_Expr, callee: ^ast.Ident) -> ^Type {
	signature := c.module.signatures[callee.name]
	append(&c.module.edges, Call_Edge{caller = c.proc_name, callee = callee.name, node = node})

	if len(node.args) != len(signature.params) {
		err(c, "MBS-E13", fmt.aprintf("`%s` takes %d argument(s), found %d", callee.name, len(signature.params), len(node.args)), node, fmt.aprintf("%d given", len(node.args)), fmt.aprintf("`%s` is declared with %d parameter(s)", callee.name, len(signature.params)), "")
		for argument in node.args {
			check_expr(c, argument, nil)
		}
		return signature.result
	}
	for argument, index in node.args {
		expected := signature.params[index]
		value := check_value(c, argument, expected)
		if is_invalid(value) == false && is_invalid(expected) == false && types_equal(value, expected) == false {
			mismatch(c, argument, expected, value)
		}
		if literal, is_literal := argument.derived.(^ast.Comp_Lit); is_literal && is_invalid(value) == false && value.kind == .ARRAY {
			record_use(c, .ARRAY_LITERAL_ARGUMENT, literal)
		}
	}
	return signature.result
}

@(private = "file")
check_builtin_call :: proc(c: ^Checker, node: ^ast.Call_Expr, callee: ^ast.Ident, builtin: Builtin) -> ^Type {
	args := make([]^Type, len(node.args))
	any_invalid := false
	for argument, index in node.args {
		args[index] = check_value(c, argument, nil)
		if is_invalid(args[index]) {
			any_invalid = true
		}
	}
	append(&c.module.edges, Call_Edge{caller = c.proc_name, callee = callee.name, builtin = true, node = node})

	result, ok := builtin_result(builtin.rule, args)
	if ok {
		return result
	}
	if any_invalid {
		return &TYPE_INVALID
	}

	names := make([dynamic]string)
	for arg in args {
		append(&names, type_name(arg))
	}
	err(
		c,
		"MBS-E13",
		fmt.aprintf("`%s` can't be called with (%s)", callee.name, strings.join(names[:], ", ")),
		node,
		"arguments don't fit",
		fmt.aprintf("the signature is `%s`", builtin.signature),
		"`T` is `f32` or a float vector; numbers never convert on their own, so write `1.0` and not `1`",
	)
	return &TYPE_INVALID
}

// ---- uses that only some targets can do -------------------------------------------------------------------

// record_use notes an operation inside a procedure. capability.odin decides, for the target being built, whether it
// is allowed where it was written.
@(private = "file")
record_use :: proc(c: ^Checker, kind: Use_Kind, node: ^ast.Node, count := 0, name := "") {
	if c.proc_name == "" {
		return
	}
	append(&c.module.uses, Use{kind = kind, proc_name = c.proc_name, node = node, count = count, name = name})
}

// record_arithmetic notes `a + b` and the like on whole numbers, and a matrix times a matrix. A calculation made of
// constants alone is done by mbsc and isn't recorded.
@(private = "file")
record_arithmetic :: proc(c: ^Checker, node: ^ast.Node, op: tokenizer.Token_Kind, left, right: ^Type) {
	if op == .Mul && left.kind == .MATRIX && right.kind == .MATRIX {
		record_use(c, .MATRIX_PRODUCT, node)
		return
	}
	#partial switch op {
	case .Add, .Sub, .Mul, .Quo:
		if has_integer(left) || has_integer(right) {
			if expr, is_expr := node.derived.(^ast.Binary_Expr); is_expr {
				if _, constant := const_int(c, expr); constant {
					return
				}
			}
			record_use(c, .INT_ARITHMETIC, node)
		}
	}
}

@(private = "file")
has_integer :: proc(t: ^Type) -> bool {
	return is_integer(t) || (t.kind == .VECTOR && is_integer(t.elem))
}

// count_comparisons is how many `<`, `==` and the like a condition holds.
@(private = "file")
count_comparisons :: proc(condition: ^ast.Expr) -> int {
	if condition == nil {
		return 0
	}
	#partial switch node in condition.derived {
	case ^ast.Paren_Expr:
		return count_comparisons(node.expr)
	case ^ast.Unary_Expr:
		return count_comparisons(node.expr)
	case ^ast.Binary_Expr:
		#partial switch node.op.kind {
		case .Lt, .Gt, .Lt_Eq, .Gt_Eq, .Cmp_Eq, .Not_Eq:
			return 1
		}
		return count_comparisons(node.left) + count_comparisons(node.right)
	}
	return 0
}

// index_is_fixed is true for an index that is a constant or the counter of a `for`: what the 3DS can use.
@(private = "file")
index_is_fixed :: proc(c: ^Checker, index: ^ast.Expr) -> bool {
	if _, constant := const_int(c, index); constant {
		return true
	}
	if identifier, is_ident := index.derived.(^ast.Ident); is_ident {
		if symbol, found := c.module.symbols[identifier]; found && symbol.loop_counter {
			return true
		}
	}
	return false
}

// index_is_float_cast says whether an index is written `i32(x)` with x a float: the one computed index the 3DS can
// take, through its address register (pica_indexed_read, G6). Written inline, so the cast is where the index is used
@(private = "file")
index_is_float_cast :: proc(c: ^Checker, index: ^ast.Expr) -> bool {
	call, is_call := index.derived.(^ast.Call_Expr)
	if is_call == false || len(call.args) != 1 do return false
	callee, is_ident := call.expr.derived.(^ast.Ident)
	if is_ident == false || callee.name != "i32" do return false
	argument := c.module.types[call.args[0]]
	return argument != nil && argument.kind == .F32
}

// ---- messages ---------------------------------------------------------------------------------------------

@(private = "file")
err :: proc {
	err_node,
	err_pos,
}

@(private = "file")
err_node :: proc(c: ^Checker, code, title: string, node: ^ast.Node, label, note, help: string) {
	error_at_node(c.module, code, title, node, label, note, help)
}

@(private = "file")
err_pos :: proc(c: ^Checker, code, title: string, pos: tokenizer.Pos, length: int, label, note, help: string) {
	error_at_pos(c.module, code, title, pos, length, label, note, help)
}
