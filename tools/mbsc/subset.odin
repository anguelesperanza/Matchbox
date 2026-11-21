package mbsc

import "core:fmt"
import "core:mem/virtual"
import "core:odin/ast"
import "core:odin/tokenizer"

// The shader language is a small part of Odin (docs/shader_language.md, section 2). The parser accepts all of
// Odin, so this walk finds everything outside that part and reports each one as MBS-E16.
//
// It only says "Odin, but not shader". Whether what is left makes sense (types, names, entry points) is for the
// later steps.

@(private = "file")
Checker :: struct {
	parsed:        ^Parsed,
	allowed_procs: map[^ast.Proc_Lit]struct{}, // procedure literals declared at the top level
	allowed_ranges: map[^ast.Binary_Expr]struct{}, // the `a..<b` in a `for i in a..<b`
	declared_names: map[^ast.Ident]struct{}, // names being declared, which may be spelled like a type
}

// check_subset reports every use of Odin that isn't part of the shader language. Call it only when the
// file parsed without syntax errors.
check_subset :: proc(parsed: ^Parsed) {
	context.allocator = virtual.arena_allocator(&parsed.arena)

	checker := Checker {
		parsed = parsed,
	}
	for declaration in parsed.file.decls {
		mark_top_level(&checker, declaration)
	}

	visitor := ast.Visitor {
		visit = visit_node,
		data  = &checker,
	}
	for declaration in parsed.file.decls {
		ast.walk(&visitor, declaration)
	}
}

// mark_top_level records the procedure literals that are declared at file level, also inside a top-level `when`.
@(private = "file")
mark_top_level :: proc(checker: ^Checker, statement: ^ast.Stmt) {
	if statement == nil {
		return
	}
	#partial switch node in statement.derived {
	case ^ast.Value_Decl:
		for value in node.values {
			if procedure, is_procedure := value.derived.(^ast.Proc_Lit); is_procedure {
				checker.allowed_procs[procedure] = {}
			}
		}
	case ^ast.When_Stmt:
		mark_top_level(checker, node.body)
		mark_top_level(checker, node.else_stmt)
	case ^ast.Block_Stmt:
		for inner in node.stmts {
			mark_top_level(checker, inner)
		}
	}
}

@(private = "file")
visit_node :: proc(visitor: ^ast.Visitor, node: ^ast.Node) -> ^ast.Visitor {
	if node == nil {
		return nil
	}
	checker := cast(^Checker)visitor.data
	if check_node(checker, node) {
		return visitor
	}
	return nil
}

// check_node looks at one node. It returns false when the node was rejected, so the walk doesn't go inside it
// and report the pieces of something that is already wrong.
@(private = "file")
check_node :: proc(checker: ^Checker, node: ^ast.Node) -> bool {
	#partial switch n in node.derived {

	// ---- declarations -------------------------------------------------------------------------------------
	case ^ast.Import_Decl, ^ast.Foreign_Import_Decl:
		return reject(checker, node.pos, 6, "`import` is not available in shaders", "a shader is one file",
			"there is nothing to import: the built-in functions are always there",
			"remove the `import` line, and write the shared code into this file")
	case ^ast.Foreign_Block_Decl:
		return reject(checker, node.pos, 7, "`foreign` is not available in shaders", "no foreign code",
			"a shader can call only itself and the built-in functions", "")
	case ^ast.Value_Decl:
		for name in n.names {
			if identifier, is_identifier := name.derived.(^ast.Ident); is_identifier {
				checker.declared_names[identifier] = {}
			}
		}
		if n.is_using {
			return reject(checker, node.pos, 5, "`using` is not available in shaders", "no `using`",
				"`using` brings names in from elsewhere, which hides where a value comes from",
				"write the name in full, for example `render.tint`")
		}
		if len(n.names) > 1 {
			return reject(checker, n.names[1].pos, 1, "a declaration can have only one name here",
				"second name", "a shader declares one value at a time",
				"write one declaration per name, one per line")
		}

	// ---- statements ---------------------------------------------------------------------------------------
	case ^ast.Defer_Stmt:
		return reject(checker, node.pos, 5, "`defer` is not available in shaders", "no deferred code",
			"a shader has no clean-up to run when it ends", "put the statement where it should run")
	case ^ast.Switch_Stmt, ^ast.Type_Switch_Stmt:
		return reject(checker, node.pos, 6, "`switch` is not available in shaders", "shaders use `if` chains",
			"the PICA200 has no jump table, and an `if` chain works on all three targets",
			"use `if mode == 0 { ... } else if mode == 1 { ... }`")
	case ^ast.Using_Stmt:
		return reject(checker, node.pos, 5, "`using` is not available in shaders", "no `using`",
			"`using` brings names in from elsewhere, which hides where a value comes from",
			"write the name in full, for example `render.tint`")
	case ^ast.Branch_Stmt:
		word := n.tok.text
		return reject(checker, node.pos, len(word), fmt.aprintf("`%s` is not available in shaders", word),
			"not in the shader language",
			"a loop runs a count that is known when the shader is built, so there is nothing to leave early",
			"narrow the range of the `for`, or guard the rest of the body with an `if`")
	case ^ast.For_Stmt:
		return reject(checker, node.pos, 3, "this form of `for` is not available in shaders",
			"use `for i in 0..<N`",
			"a loop must run a count that is known when the shader is built (a constant, or an integer uniform on the 3DS); `while`-style and C-style loops can't promise that",
			"write `for i in 0..<8 { ... }`")
	case ^ast.Range_Stmt:
		range_ok := false
		if binary, is_binary := n.expr.derived.(^ast.Binary_Expr); is_binary {
			if binary.op.kind == .Range_Half || binary.op.kind == .Range_Full {
				range_ok = true
				checker.allowed_ranges[binary] = {}
			}
		}
		if n.reverse || len(n.vals) != 1 || range_ok == false {
			return reject(checker, node.pos, 3, "this form of `for` is not available in shaders",
				"use `for i in 0..<N`",
				"a `for` can only count over a range, one value at a time, forwards",
				"write `for i in 0..<8 { ... }`")
		}
		if n.label != nil {
			return reject_label(checker, n.label)
		}
	case ^ast.Inline_Range_Stmt:
		return reject(checker, node.pos, 7, "`#unroll` is not available in shaders", "no `#unroll`",
			"mbsc decides how a loop is unrolled for each target", "write a plain `for i in 0..<N`")
	case ^ast.If_Stmt:
		if n.label != nil {
			return reject_label(checker, n.label)
		}
	case ^ast.Block_Stmt:
		if n.label != nil {
			return reject_label(checker, n.label)
		}
	case ^ast.Assign_Stmt:
		if len(n.lhs) > 1 || len(n.rhs) > 1 {
			return reject(checker, node.pos, 1, "assigning several values at once is not available in shaders",
				"one value at a time", "a shader has one return value and no multiple assignment",
				"write one assignment per line")
		}
		#partial switch n.op.kind {
		case .Eq, .Add_Eq, .Sub_Eq, .Mul_Eq, .Quo_Eq:
		case:
			return reject_operator(checker, n.op)
		}
	case ^ast.Tag_Stmt:
		return reject_directive(checker, node.pos, "")

	// ---- procedures and types -----------------------------------------------------------------------------
	case ^ast.Proc_Lit:
		if n.where_token.kind != .Invalid || len(n.where_clauses) > 0 {
			return reject(checker, node.pos, 4, "`where` clauses are not available in shaders", "no `where`",
				"a shader procedure has fixed types", "")
		}
		if n.type != nil && n.type.generic {
			return reject(checker, node.pos, 4, "generic procedures are not available in shaders", "has type parameters",
				"every type in a shader is concrete", "write the procedure for one type; copy it for another")
		}
		if n.type != nil && n.type.calling_convention != nil {
			return reject(checker, node.pos, 4, "a calling convention is not available in shaders", "no `\"c\"` or `\"contextless\"`",
				"mbsc inlines every procedure, so there is no call", "remove the convention string")
		}
		if n.type != nil && n.type.results != nil && count_results(n.type.results) > 1 {
			return reject(checker, node.pos, 4, "a procedure can return only one value in shaders", "more than one result",
				"the targets return one value", "return a struct, or an array like `[2]f32`")
		}
		if _, allowed := checker.allowed_procs[n]; allowed == false {
			return reject(checker, node.pos, 4, "a procedure must be declared at the top level of the shader",
				"procedure inside a procedure", "mbsc inlines procedures by name, which a local one doesn't have",
				"move it out to the top level: `name :: proc(...) { ... }`")
		}
	case ^ast.Struct_Type:
		if n.poly_params != nil || n.align != nil || n.min_field_align != nil || n.max_field_align != nil ||
		   n.is_packed || n.is_raw_union || n.is_no_copy || n.is_all_or_none || len(n.where_clauses) > 0 {
			return reject(checker, node.pos, 6, "this kind of struct is not available in shaders", "has parameters or a layout setting",
				"the targets lay structs out themselves", "write a plain `struct { ... }` with fields and tags")
		}
	case ^ast.Field:
		for name in n.names {
			if identifier, is_identifier := name.derived.(^ast.Ident); is_identifier {
				checker.declared_names[identifier] = {}
			}
		}
		if .Using in n.flags {
			return reject(checker, node.pos, 5, "`using` is not available in shaders", "no `using`",
				"`using` brings names in from elsewhere, which hides where a value comes from",
				"write the field's name in full")
		}
	case ^ast.Ellipsis:
		return reject(checker, node.pos, 2, "variable arguments are not available in shaders", "no `..`",
			"every call has a fixed number of arguments", "")
	case ^ast.Pointer_Type, ^ast.Multi_Pointer_Type:
		return reject_feature(checker, node, "pointers are not available in shaders", "a shader has no memory to point into", "pass the value, or return it")
	case ^ast.Deref_Expr:
		return reject_feature(checker, node, "pointers are not available in shaders", "a shader has no memory to point into", "pass the value, or return it")
	case ^ast.Slice_Expr:
		return reject_feature(checker, node, "slices are not available in shaders", "a shader has no slices, only fixed arrays", "index with a constant or a loop counter")
	case ^ast.Matrix_Index_Expr:
		return reject_feature(checker, node, "matrix elements are not available in shaders", "a matrix is used whole, as in `m * v`, because the targets store it differently", "pass the numbers you need as separate uniforms or a vector")
	case ^ast.Array_Type:
		if n.len == nil {
			return reject_feature(checker, node, "slices are not available in shaders", "a shader has no slices, only fixed arrays", "use a fixed array like `[4]f32`")
		}
	case ^ast.Dynamic_Array_Type, ^ast.Fixed_Capacity_Dynamic_Array_Type:
		return reject_feature(checker, node, "dynamic arrays are not available in shaders", "a shader has no memory allocator", "use a fixed array like `[4]f32`")
	case ^ast.Map_Type:
		return reject_feature(checker, node, "maps are not available in shaders", "a shader has no memory allocator", "use a fixed array indexed by a constant")
	case ^ast.Union_Type:
		return reject_feature(checker, node, "`union` is not available in shaders", "a shader has no tagged values", "use a struct")
	case ^ast.Enum_Type:
		return reject_feature(checker, node, "`enum` declarations are not available in shaders", "a shader has no enum types of its own", "use constants: `MODE_FADE :: 1`")
	case ^ast.Bit_Set_Type, ^ast.Bit_Field_Type:
		return reject_feature(checker, node, "`bit_set` and `bit_field` are not available in shaders", "integers are loop counters and indexes only", "use `bool` values")
	case ^ast.Typeid_Type, ^ast.Relative_Type, ^ast.Proc_Group, ^ast.Distinct_Type, ^ast.Poly_Type, ^ast.Helper_Type:
		return reject_feature(checker, node, "this kind of type is not available in shaders", "the targets know concrete types only", "use a plain type like `f32` or `[4]f32`")

	// ---- expressions --------------------------------------------------------------------------------------
	case ^ast.Basic_Lit:
		#partial switch n.tok.kind {
		case .String:
			return reject_feature(checker, node, "strings are not available in shaders", "a shader has no text", "")
		case .Rune:
			return reject_feature(checker, node, "characters are not available in shaders", "a shader has no text", "use a number")
		case .Imag:
			return reject_feature(checker, node, "imaginary numbers are not available in shaders", "a shader has no complex numbers", "")
		}
	case ^ast.Basic_Directive, ^ast.Tag_Expr:
		return reject_directive(checker, node.pos, "")
	case ^ast.Implicit:
		if n.tok.kind == .Context {
			return reject(checker, node.pos, 7, "`context` is not available in shaders", "no `context`",
				"`context` carries the allocator and logger, and a shader has neither", "")
		}
	case ^ast.Ident:
		if _, declared := checker.declared_names[n]; declared == false {
			switch n.name {
			case "new", "make", "delete", "free", "append", "clear", "resize":
				return reject(checker, node.pos, len(n.name), fmt.aprintf("`%s` is not available in shaders", n.name), "needs a memory allocator",
					"a shader has no heap, so nothing can be allocated or freed", "use a fixed array")
			case "string", "cstring", "rune", "any", "typeid", "rawptr":
				return reject_feature(checker, node, fmt.aprintf("the type `%s` is not available in shaders", n.name), "a shader has no text or untyped values", "use `f32`, `bool`, a vector or a struct")
			}
		}
	case ^ast.Ternary_If_Expr, ^ast.Ternary_When_Expr:
		return reject(checker, node.pos, node_length(node), "`a if cond else b` is not available in shaders", "no value-producing `if`",
			"only the statement form of `if` is in the language", "assign in an `if`/`else`, or use `lerp` and `step` for a branchless result")
	case ^ast.Or_Else_Expr, ^ast.Or_Return_Expr, ^ast.Or_Branch_Expr:
		return reject_feature(checker, node, "`or_else`, `or_return` and `or_break` are not available in shaders", "a shader has no optional values", "")
	case ^ast.Type_Assertion:
		return reject_feature(checker, node, "type assertions are not available in shaders", "a shader has no `any` or union values", "")
	case ^ast.Auto_Cast:
		return reject(checker, node.pos, 9, "`auto_cast` is not available in shaders", "no implicit conversion",
			"every conversion is written out, so a reader can see where a value changes type", "write the conversion as a call: `f32(x)`")
	case ^ast.Type_Cast:
		word := n.tok.text
		return reject(checker, node.pos, len(word), fmt.aprintf("`%s` is not available in shaders", word), "use a conversion call",
			"conversions are written as calls", "write `f32(x)` or `i32(x)`")
	case ^ast.Selector_Call_Expr:
		return reject_feature(checker, node, "method-style calls with `->` are not available in shaders", "a shader calls procedures by name", "write `name(a, b)`")
	case ^ast.Unary_Expr:
		#partial switch n.op.kind {
		case .Sub, .Add, .Not:
		case .And:
			return reject(checker, n.op.pos, 1, "pointers are not available in shaders", "not in the shader language", "a shader has no memory to take the address of", "use the value")
		case:
			return reject_operator(checker, n.op)
		}
	case ^ast.Binary_Expr:
		#partial switch n.op.kind {
		case .Add, .Sub, .Mul, .Quo, .Cmp_Eq, .Not_Eq, .Lt, .Gt, .Lt_Eq, .Gt_Eq, .Cmp_And, .Cmp_Or:
		case .Range_Half, .Range_Full:
			if _, in_for := checker.allowed_ranges[n]; in_for == false {
				return reject(checker, n.op.pos, len(n.op.text), "a range is only available as `for i in a..<b`", "range outside a `for`",
					"ranges are not values in a shader", "write the comparison, for example `x >= a && x < b`")
			}
		case:
			return reject_operator(checker, n.op)
		}
	}
	return true
}

@(private = "file")
count_results :: proc(results: ^ast.Field_List) -> int {
	count := 0
	for field in results.list {
		count += max(len(field.names), 1)
	}
	return count
}

// reject adds one MBS-E16 message and returns false, so a caller can `return reject(...)`.
@(private = "file")
reject :: proc(checker: ^Checker, pos: tokenizer.Pos, length: int, title, label, note, help: string) -> bool {
	add_diagnostic(checker.parsed, "MBS-E16", title, pos, length, label, note, help)
	return false
}

@(private = "file")
reject_feature :: proc(checker: ^Checker, node: ^ast.Node, title, note, help: string) -> bool {
	return reject(checker, node.pos, node_length(node), title, "not in the shader language", note, help)
}

// node_length is how many characters a node covers on its first line, for the carets under it.
@(private = "file")
node_length :: proc(node: ^ast.Node) -> int {
	if node.end.line == node.pos.line && node.end.offset > node.pos.offset {
		return node.end.offset - node.pos.offset
	}
	return 1
}

@(private = "file")
reject_label :: proc(checker: ^Checker, label: ^ast.Expr) -> bool {
	return reject(checker, label.pos, 1, "labels are not available in shaders", "no labels",
		"labels exist to leave a loop early, which a shader's loops don't do", "remove the label")
}

@(private = "file")
reject_directive :: proc(checker: ^Checker, pos: tokenizer.Pos, help: string) -> bool {
	return reject(checker, pos, 1, "`#` directives are not available in shaders", "no directives",
		"directives talk to the Odin compiler, and a shader is read by mbsc", help)
}

@(private = "file")
reject_operator :: proc(checker: ^Checker, op: tokenizer.Token) -> bool {
	help := ""
	#partial switch op.kind {
	case .Mod, .Mod_Mod, .Mod_Eq, .Mod_Mod_Eq:
		help = "use `mod(a, b)`, which is `a - b * floor(a / b)`, or `fmod(a, b)`"
	case .And, .Or, .Xor, .And_Not, .Shl, .Shr, .And_Eq, .Or_Eq, .Xor_Eq, .And_Not_Eq, .Shl_Eq, .Shr_Eq:
		help = "integers are loop counters and indexes only, so there is no bit arithmetic"
	case .In, .Not_In:
		help = "compare with `==` and `||`, or loop over a range"
	}
	title := fmt.aprintf("the operator `%s` is not available in shaders", op.text)
	return reject(checker, op.pos, len(op.text), title, "not in the shader language",
		"a shader uses `+ - * /`, comparisons, `&&`, `||`, `!` and unary `-`", help)
}
