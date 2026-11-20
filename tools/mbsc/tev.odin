package mbsc

import "core:fmt"
import "core:strings"

// The 3DS fragment plan (S6). The 3DS has no pixel shader: its fragment stage is up to six TexEnv stages, each of which
// combines up to three sources with one function, and an alpha test. mbsc reads `fragment_main` as a tree of the
// operations a stage has (multiply, add, subtract, lerp, one-minus) over leaves a stage can read (a texture, the vertex
// colour, a constant), and writes the stages as a table, `<name>.tev`, that the 3DS renderer applies with `C3D_TexEnv*`
// and `C3D_AlphaTest`. Anything else is a problem the shader is told about; nothing is approximated.
//
// What the plan does with a tree:
//   - `a * b` is MODULATE, `a + b` ADD, `a - b` SUBTRACT, `lerp(a, b, t)` INTERPOLATE (src0 = b, src1 = a, src2 = t),
//     `1.0 - a` is the ONE_MINUS operand of a source, `a * b + c` is MULTIPLY_ADD and `(a + b) * c` ADD_MULTIPLY.
//   - A stage's result reaches the next stage as PREVIOUS, and only one result can wait there, so at most one operand
//     of a stage may be a computed value; a stage with two (MBS-E3) can't be written. A stage reads one constant
//     colour (MBS-E21), and a shader has six stages (MBS-E3).
//   - `saturate(x)` is `x`: every stage clamps its result to 0..1 anyway.
//   - The alpha of the colour returned, tested against a literal or an `f32` uniform and followed by `discard()`, is the
//     alpha test (docs/shader_language.md, section 19).

TEV_STAGES :: 6

Tev_Source :: enum {
	PRIMARY_COLOR,
	TEXTURE0,
	TEXTURE1,
	TEXTURE2,
	CONSTANT,
	PREVIOUS,
}

Tev_Function :: enum {
	REPLACE,
	MODULATE,
	ADD,
	SUBTRACT,
	INTERPOLATE,
	MULTIPLY_ADD,
	ADD_MULTIPLY,
}

Tev_Constant :: struct {
	used:    bool,
	uniform: string, // the name of the uniform, or "" for a literal
	value:   [4]f32,
}

Tev_Stage :: struct {
	function:  Tev_Function,
	source:    [3]Tev_Source,
	one_minus: [3]bool,
	constant:  Tev_Constant,
}

Tev_Texture :: struct {
	unit:      int,
	name:      string,
	texcoord:  int,
}

Tev_Alpha_Test :: struct {
	used:     bool,
	function: string, // GREATER, GEQUAL, ... : keeps the pixel when `alpha <function> reference` holds
	uniform:  string, // the reference's uniform, or "" for the literal
	value:    f32,
}

Tev_Plan :: struct {
	stages:   []Tev_Stage,
	textures: []Tev_Texture,
	alpha:    Tev_Alpha_Test,
}

@(private = "file")
Node_Kind :: enum {
	TEXTURE,
	COORD,
	PRIMARY,
	CONSTANT,
	MUL,
	ADD,
	SUB,
	LERP,
	ONE_MINUS,
}

@(private = "file")
Node :: struct {
	kind:     Node_Kind,
	args:     [3]^Node,
	count:    int,
	slot:     int, // TEXTURE: the unit; COORD: the texcoord
	name:     string, // TEXTURE: the texture's name; CONSTANT: the uniform ("" for a literal)
	value:    [4]f32,
	use_coord: int, // TEXTURE: which texcoord feeds it
}

@(private = "file")
Tev :: struct {
	ir:       ^IR_Module,
	problems: [dynamic]string,
	env:      map[^IR_Var]^Node,
	stages:   [dynamic]Tev_Stage,
	textures: [dynamic]Tev_Texture,
	varying:  ^IR_Var,
}

@(private = "file")
tev_problem :: proc(t: ^Tev, text: string) {
	for existing in t.problems {
		if existing == text {
			return
		}
	}
	append(&t.problems, text)
}

@(private = "file")
tev_fields :: proc(t: ^Tev, type: ^Type) -> []IR_Field_Info {
	if type.info.name != "" {
		return struct_fields(t.ir, type)
	}
	for uniform in t.ir.uniforms {
		if uniform.type != nil && uniform.type.info == type.info {
			return uniform.fields
		}
	}
	return nil
}

// generate_tev reads the fragment stage of a module built for the 3DS. `problems` lists what can't be written; the
// plan is complete only when it is empty.
generate_tev :: proc(ir: ^IR_Module, allocator := context.allocator) -> (plan: Tev_Plan, problems: []string) {
	context.allocator = context.temp_allocator
	t := Tev {
		ir  = ir,
		env = make(map[^IR_Var]^Node),
	}
	entry := ir.fragment_main
	result: ^Node
	alpha: Tev_Alpha_Test
	if entry == nil || len(entry.params) != 1 {
		tev_problem(&t, "`fragment_main` must take one struct")
	} else {
		t.varying = entry.params[0]
		result, alpha = read_fragment(&t, entry)
	}
	if result != nil {
		operand := emit_node(&t, result)
		if len(t.stages) == 0 {
			add_stage(&t, .REPLACE, {operand, {}, {}}, 1)
		}
	}
	if len(t.stages) > TEV_STAGES {
		tev_problem(&t, fmt.aprintf("MBS-E3 this fragment shader needs %d combiner stages; the 3DS has %d", len(t.stages), TEV_STAGES))
	}

	kept := make([]string, len(t.problems), allocator)
	for text, index in t.problems {
		kept[index] = strings.clone(text, allocator)
	}
	plan.stages = make([]Tev_Stage, len(t.stages), allocator)
	copy(plan.stages, t.stages[:])
	plan.textures = make([]Tev_Texture, len(t.textures), allocator)
	for texture, index in t.textures {
		plan.textures[index] = texture
		plan.textures[index].name = strings.clone(texture.name, allocator)
	}
	plan.alpha = alpha
	plan.alpha.uniform = strings.clone(alpha.uniform, allocator)
	for &stage in plan.stages {
		stage.constant.uniform = strings.clone(stage.constant.uniform, allocator)
	}
	return plan, kept
}

// ---- reading fragment_main ------------------------------------------------------------------------------------------

@(private = "file")
read_fragment :: proc(t: ^Tev, entry: ^IR_Proc) -> (result: ^Node, alpha: Tev_Alpha_Test) {
	returned: ^IR_Var
	for stmt in entry.body {
		switch node in stmt.variant {
		case IR_Declare:
			if node.init == nil {
				tev_problem(t, "a fragment value needs a first value on the 3DS")
				continue
			}
			t.env[node.var] = to_node(t, node.init)
		case IR_If:
			alpha = read_alpha_test(t, node)
		case IR_Return:
			if node.value == nil {
				continue
			}
			if reference, is_reference := node.value.variant.(IR_Var_Ref); is_reference {
				returned = reference.var
			}
			result = to_node(t, node.value)
		case IR_Assign, IR_For, IR_Eval, IR_Block:
			tev_problem(t, "a 3DS fragment shader is a list of `name := value` lines, an optional alpha cut-off and a `return`")
		}
	}
	if alpha.used && alpha_variable(entry) != returned {
		tev_problem(t, "MBS-E12 the alpha test has to test the colour the shader returns")
	}
	return
}

// alpha_variable is the variable the alpha test reads, found again from the statement.
@(private = "file")
alpha_variable :: proc(entry: ^IR_Proc) -> ^IR_Var {
	for stmt in entry.body {
		if node, is_if := stmt.variant.(IR_If); is_if {
			if comparison, is_comparison := node.condition.variant.(IR_Binary); is_comparison {
				if swizzle, is_swizzle := comparison.left.variant.(IR_Swizzle); is_swizzle {
					if reference, is_reference := swizzle.base.variant.(IR_Var_Ref); is_reference {
						return reference.var
					}
				}
			}
		}
	}
	return nil
}

@(private = "file")
read_alpha_test :: proc(t: ^Tev, node: IR_If) -> (alpha: Tev_Alpha_Test) {
	comparison, is_comparison := node.condition.variant.(IR_Binary)
	discards := len(node.then) == 1 && len(node.otherwise) == 0
	if discards {
		if eval, is_eval := node.then[0].variant.(IR_Eval); is_eval {
			call, is_call := eval.call.variant.(IR_Builtin_Call)
			discards = is_call && call.name == "discard"
		} else {
			discards = false
		}
	}
	if is_comparison == false || discards == false {
		tev_problem(t, "MBS-E12 the only `if` a 3DS fragment shader can have is `if color.a < reference do discard()`")
		return
	}
	swizzle, is_swizzle := comparison.left.variant.(IR_Swizzle)
	if is_swizzle == false || swizzle.count != 1 || swizzle.indices[0] != 3 {
		tev_problem(t, "MBS-E12 the 3DS alpha test compares the alpha of the returned colour (`.a`)")
		return
	}
	// the pixel is kept when the condition that discards it is false
	function: string
	#partial switch comparison.op {
	case .LESS:
		function = "GEQUAL"
	case .LESS_EQUAL:
		function = "GREATER"
	case .GREATER:
		function = "LEQUAL"
	case .GREATER_EQUAL:
		function = "LESS"
	case .EQUAL:
		function = "NOTEQUAL"
	case .NOT_EQUAL:
		function = "EQUAL"
	case:
		tev_problem(t, "MBS-E12 the alpha test is a comparison of the alpha with one value")
		return
	}
	alpha = Tev_Alpha_Test {
		used     = true,
		function = function,
	}
	if literal, is_literal := comparison.right.variant.(IR_Float); is_literal {
		alpha.value = literal.value
	} else if name, is_uniform := uniform_leaf_name(t, comparison.right); is_uniform && comparison.right.type.kind == .F32 {
		alpha.uniform = name
	} else {
		tev_problem(t, "MBS-E12 the alpha reference is a number written out or an `f32` uniform")
	}
	return
}

// uniform_leaf_name is the name a uniform expression has in the 3DS programs: the engine's `<block>_<field>`, or the
// game's own name, with struct fields joined by `_`.
@(private = "file")
uniform_leaf_name :: proc(t: ^Tev, e: ^IR_Expr) -> (name: string, ok: bool) {
	#partial switch node in e.variant {
	case IR_Uniform_Ref:
		return node.name, true
	case IR_Field:
		base := uniform_leaf_name(t, node.base) or_return
		return strings.concatenate({base, "_", node.name}), true
	}
	return "", false
}

@(private = "file")
make_node :: proc(kind: Node_Kind, args: ..^Node) -> ^Node {
	result := new(Node)
	result.kind = kind
	result.count = len(args)
	for arg, index in args {
		result.args[index] = arg
	}
	return result
}

@(private = "file")
constant_node :: proc(value: [4]f32) -> ^Node {
	result := make_node(.CONSTANT)
	result.value = value
	return result
}

// to_node turns an expression into a tree of stage operations.
@(private = "file")
to_node :: proc(t: ^Tev, e: ^IR_Expr) -> ^Node {
	#partial switch node in e.variant {
	case IR_Float:
		return constant_node({node.value, node.value, node.value, node.value})
	case IR_Zero:
		return constant_node({})
	case IR_Var_Ref:
		if value, found := t.env[node.var]; found {
			return value
		}
		tev_problem(t, fmt.aprintf("`%s` isn't a value the 3DS can combine", node.var.name))
		return constant_node({})
	case IR_Uniform_Ref, IR_Field:
		return field_node(t, e)
	case IR_Swizzle:
		if node.count == 4 && node.indices == {0, 1, 2, 3} {
			return to_node(t, node.base)
		}
		tev_problem(t, "MBS-E2 a part of a colour (`.rgb`, `.a`) can't be combined on the 3DS; combine whole colours")
		return constant_node({})
	case IR_Construct:
		if e.type.kind == .VECTOR && e.type.count == 4 {
			value: [4]f32
			literals := true
			for arg, index in node.args {
				if literal, is_literal := arg.variant.(IR_Float); is_literal && index < 4 {
					value[index] = literal.value
				} else {
					literals = false
				}
			}
			if literals && len(node.args) == 4 {
				return constant_node(value)
			}
		}
		tev_problem(t, "MBS-E2 a colour built from parts can't be combined on the 3DS; write all four numbers, or use a uniform")
		return constant_node({})
	case IR_Binary:
		#partial switch node.op {
		case .MUL:
			return make_node(.MUL, to_node(t, node.left), to_node(t, node.right))
		case .ADD:
			return make_node(.ADD, to_node(t, node.left), to_node(t, node.right))
		case .SUB:
			left := to_node(t, node.left)
			if left.kind == .CONSTANT && left.name == "" && left.value == {1, 1, 1, 1} {
				return make_node(.ONE_MINUS, to_node(t, node.right))
			}
			return make_node(.SUB, left, to_node(t, node.right))
		}
		tev_problem(t, "MBS-E2 only `*`, `+` and `-` combine colours on the 3DS")
		return constant_node({})
	case IR_Builtin_Call:
		switch node.name {
		case "sample":
			return sample_node(t, node)
		case "lerp":
			return make_node(.LERP, to_node(t, node.args[0]), to_node(t, node.args[1]), to_node(t, node.args[2]))
		case "saturate":
			return to_node(t, node.args[0])
		}
		tev_problem(t, fmt.aprintf("MBS-E2 `%s` can't run in a 3DS fragment shader", node.name))
		return constant_node({})
	case IR_Proc_Call:
		return inline_node(t, node)
	}
	tev_problem(t, "MBS-E2 this expression can't run in a 3DS fragment shader")
	return constant_node({})
}

// field_node is a field of the varying (the vertex colour or a texture coordinate) or a fragment uniform.
@(private = "file")
field_node :: proc(t: ^Tev, e: ^IR_Expr) -> ^Node {
	if field, is_field := e.variant.(IR_Field); is_field {
		if reference, is_reference := field.base.variant.(IR_Var_Ref); is_reference && reference.var == t.varying {
			info := tev_fields(t, field.base.type)[field.index]
			switch {
			case info.out == "color":
				return make_node(.PRIMARY)
			case strings.has_prefix(info.out, "texcoord"):
				result := make_node(.COORD)
				result.slot = int(info.out[len("texcoord")] - '0')
				return result
			}
			tev_problem(t, fmt.aprintf("MBS-E2 `%s` isn't something a 3DS combiner can read; it reads the vertex colour and texture colours", info.name))
			return constant_node({})
		}
	}
	if name, is_uniform := uniform_leaf_name(t, e); is_uniform {
		if is_float_vector(e.type) && e.type.count == 4 {
			result := constant_node({})
			result.name = name
			return result
		}
		tev_problem(t, fmt.aprintf("the uniform `%s` isn't a colour; a 3DS combiner reads a `[4]f32` uniform as a constant colour", name))
		return constant_node({})
	}
	tev_problem(t, "MBS-E2 this value can't be combined on the 3DS")
	return constant_node({})
}

@(private = "file")
sample_node :: proc(t: ^Tev, call: IR_Builtin_Call) -> ^Node {
	texture, is_texture := call.args[0].variant.(IR_Texture_Ref)
	if is_texture == false {
		tev_problem(t, "MBS-E2 `sample` needs a texture")
		return constant_node({})
	}
	coordinate := to_node(t, call.args[1])
	if coordinate.kind != .COORD {
		tev_problem(t, "MBS-E2 the coordinate of a 3DS `sample` is a `texcoord` output of the vertex stage, unchanged")
		return constant_node({})
	}
	for existing in t.textures {
		if existing.unit == texture.slot && existing.texcoord != coordinate.slot {
			tev_problem(t, fmt.aprintf("the texture `%s` is read with two different texture coordinates; a 3DS texture unit has one", texture.name))
		}
	}
	found := false
	for existing in t.textures {
		if existing.unit == texture.slot {
			found = true
		}
	}
	if found == false {
		append(&t.textures, Tev_Texture{unit = texture.slot, name = texture.name, texcoord = coordinate.slot})
	}
	result := make_node(.TEXTURE)
	result.slot = texture.slot
	result.name = texture.name
	return result
}

// inline_node reads a helper written as `name := value` lines and a `return`, with its parameters standing for the
// arguments.
@(private = "file")
inline_node :: proc(t: ^Tev, call: IR_Proc_Call) -> ^Node {
	for param, index in call.callee.params {
		t.env[param] = to_node(t, call.args[index])
	}
	for stmt in call.callee.body {
		#partial switch node in stmt.variant {
		case IR_Declare:
			if node.init != nil {
				t.env[node.var] = to_node(t, node.init)
			}
		case IR_Return:
			return to_node(t, node.value)
		case:
			tev_problem(t, fmt.aprintf("MBS-E2 `%s` has more than lines of `name := value` and a `return`; a 3DS combiner can't run it", call.callee.name))
		}
	}
	return constant_node({})
}

// ---- stages -------------------------------------------------------------------------------------------------------

@(private = "file")
Operand :: struct {
	source:    Tev_Source,
	one_minus: bool,
	constant:  Tev_Constant,
}

@(private = "file")
is_computed :: proc(n: ^Node) -> bool {
	#partial switch n.kind {
	case .TEXTURE, .COORD, .PRIMARY, .CONSTANT:
		return false
	case .ONE_MINUS:
		return is_computed(n.args[0])
	}
	return true
}

@(private = "file")
add_stage :: proc(t: ^Tev, function: Tev_Function, operands: [3]Operand, count: int) {
	stage := Tev_Stage {
		function = function,
	}
	for index in 0 ..< count {
		stage.source[index] = operands[index].source
		stage.one_minus[index] = operands[index].one_minus
		if operands[index].source == .CONSTANT {
			if stage.constant.used && stage.constant != operands[index].constant {
				tev_problem(t, "MBS-E21 one combiner stage can read only one constant colour, and this one needs two different ones")
			}
			stage.constant = operands[index].constant
			stage.constant.used = true
		}
	}
	append(&t.stages, stage)
}

// leaf_operand is what a stage names to read a leaf. A computed value is PREVIOUS: it was just written by a stage.
@(private = "file")
leaf_operand :: proc(t: ^Tev, n: ^Node) -> Operand {
	#partial switch n.kind {
	case .TEXTURE:
		return Operand{source = Tev_Source(int(Tev_Source.TEXTURE0) + n.slot)}
	case .PRIMARY:
		return Operand{source = .PRIMARY_COLOR}
	case .CONSTANT:
		return Operand{source = .CONSTANT, constant = Tev_Constant{used = true, uniform = n.name, value = n.value}}
	case .ONE_MINUS:
		if is_computed(n.args[0]) == false {
			inner := leaf_operand(t, n.args[0])
			inner.one_minus = !inner.one_minus
			return inner
		}
	case .COORD:
		tev_problem(t, "MBS-E2 a texture coordinate can't be used as a colour on the 3DS")
		return Operand{source = .PRIMARY_COLOR}
	}
	return Operand{source = .PREVIOUS}
}

// emit_node writes the stages that compute a node and says where its value is.
@(private = "file")
emit_node :: proc(t: ^Tev, n: ^Node) -> Operand {
	if is_computed(n) == false {
		return leaf_operand(t, n)
	}
	if n.kind == .ONE_MINUS {
		inner := emit_node(t, n.args[0])
		inner.one_minus = !inner.one_minus
		add_stage(t, .REPLACE, {inner, {}, {}}, 1)
		return Operand{source = .PREVIOUS}
	}

	// two stages fused into one: `a * b + c` and `(a + b) * c`
	function: Tev_Function
	parts: [3]^Node
	count := 0
	switch n.kind {
	case .MUL:
		function, parts, count = .MODULATE, {n.args[0], n.args[1], nil}, 2
		for side in 0 ..< 2 {
			if n.args[side].kind == .ADD && fusable({n.args[side].args[0], n.args[side].args[1], n.args[1 - side]}) {
				function, parts, count = .ADD_MULTIPLY, {n.args[side].args[0], n.args[side].args[1], n.args[1 - side]}, 3
				break
			}
		}
	case .ADD:
		function, parts, count = .ADD, {n.args[0], n.args[1], nil}, 2
		for side in 0 ..< 2 {
			if n.args[side].kind == .MUL && fusable({n.args[side].args[0], n.args[side].args[1], n.args[1 - side]}) {
				function, parts, count = .MULTIPLY_ADD, {n.args[side].args[0], n.args[side].args[1], n.args[1 - side]}, 3
				break
			}
		}
	case .SUB:
		function, parts, count = .SUBTRACT, {n.args[0], n.args[1], nil}, 2
	case .LERP:
		// INTERPOLATE is src0 * src2 + src1 * (1 - src2), and lerp(a, b, t) is a * (1 - t) + b * t
		function, parts, count = .INTERPOLATE, {n.args[1], n.args[0], n.args[2]}, 3
	case .TEXTURE, .COORD, .PRIMARY, .CONSTANT, .ONE_MINUS:
	}

	computed := 0
	for index in 0 ..< count {
		if is_computed(parts[index]) {
			computed += 1
		}
	}
	if computed > 1 {
		tev_problem(t, "MBS-E3 a combiner stage can use only one value computed by an earlier stage, and this expression needs two; write the shader so one side is a texture, the vertex colour or a constant")
	}
	operands: [3]Operand
	for index in 0 ..< count {
		if is_computed(parts[index]) {
			operands[index] = emit_node(t, parts[index])
		}
	}
	for index in 0 ..< count {
		if is_computed(parts[index]) == false {
			operands[index] = leaf_operand(t, parts[index])
		}
	}
	add_stage(t, function, operands, count)
	return Operand{source = .PREVIOUS}
}

// fusable is true when at most one of the three parts is a computed value.
@(private = "file")
fusable :: proc(parts: [3]^Node) -> bool {
	computed := 0
	for part in parts {
		if is_computed(part) {
			computed += 1
		}
	}
	return computed <= 1
}

// ---- the table ----------------------------------------------------------------------------------------------------

TEV_VERSION :: 1

// format_tev writes the table the 3DS renderer reads.
format_tev :: proc(plan: Tev_Plan, allocator := context.allocator) -> string {
	builder := strings.builder_make(allocator)
	fmt.sbprintfln(&builder, "mbs-tev %d", TEV_VERSION)
	fmt.sbprintln(&builder, "target 3ds")
	fmt.sbprintln(&builder)
	for texture in plan.textures {
		fmt.sbprintfln(&builder, "texture %d %s texcoord %d", texture.unit, texture.name, texture.texcoord)
	}
	if len(plan.textures) > 0 {
		fmt.sbprintln(&builder)
	}
	for stage, index in plan.stages {
		fmt.sbprintf(&builder, "stage %d %v", index, stage.function)
		for source, position in stage.source {
			if stage.function == .REPLACE && position > 0 {
				break
			}
			if (stage.function == .MODULATE || stage.function == .ADD || stage.function == .SUBTRACT) && position > 1 {
				break
			}
			fmt.sbprintf(&builder, " %v%s", source, "!" if stage.one_minus[position] else "")
		}
		if stage.constant.used {
			if stage.constant.uniform != "" {
				fmt.sbprintf(&builder, " constant uniform %s", stage.constant.uniform)
			} else {
				fmt.sbprintf(&builder, " constant %v %v %v %v", stage.constant.value[0], stage.constant.value[1], stage.constant.value[2], stage.constant.value[3])
			}
		}
		fmt.sbprintln(&builder)
	}
	if plan.alpha.used {
		fmt.sbprintln(&builder)
		if plan.alpha.uniform != "" {
			fmt.sbprintfln(&builder, "alphatest %s uniform %s", plan.alpha.function, plan.alpha.uniform)
		} else {
			fmt.sbprintfln(&builder, "alphatest %s %v", plan.alpha.function, plan.alpha.value)
		}
	}
	return strings.to_string(builder)
}
