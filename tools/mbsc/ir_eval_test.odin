package mbsc

import "core:fmt"
import "core:math"
import "core:strings"
import "core:testing"

// A plain evaluation of the intermediate form: what the shader means, with no target in it. The 3DS backend's output
// is run on the machine of pica_machine_test.odin and must give the same numbers.
//
// A value is a flat list of numbers: a vector's components, a matrix's rows one after the other (the order its literal
// is written in), a struct's fields or an array's elements one after the other. A boolean is 1 or 0.

Frame :: struct {
	vars:     map[^IR_Var][]f32,
	result:   []f32,
	returned: bool,
}

Interp :: struct {
	ir:       ^IR_Module,
	uniforms: map[string][]f32,
	loops:    int,
}

fields_for :: proc(ir: ^IR_Module, type: ^Type) -> []IR_Field_Info {
	if type.info.name != "" {
		return struct_fields(ir, type)
	}
	for uniform in ir.uniforms {
		if uniform.type != nil && uniform.type.info == type.info {
			return uniform.fields
		}
	}
	return nil
}

flat_size :: proc(ir: ^IR_Module, type: ^Type) -> int {
	#partial switch type.kind {
	case .VECTOR:
		return type.count
	case .MATRIX:
		return type.rows * type.cols
	case .ARRAY:
		return type.count * flat_size(ir, type.elem)
	case .STRUCT:
		total := 0
		for field in fields_for(ir, type) {
			total += flat_size(ir, field.type)
		}
		return total
	}
	return 1
}

@(private = "file")
numbers :: proc(count: int) -> []f32 {
	return make([]f32, count, context.temp_allocator)
}

@(private = "file")
one :: proc(value: f32) -> []f32 {
	result := numbers(1)
	result[0] = value
	return result
}

// interp_call runs a procedure and gives its value.
interp_call :: proc(i: ^Interp, callee: ^IR_Proc, args: [][]f32) -> []f32 {
	frame := Frame {
		vars = make(map[^IR_Var][]f32, context.temp_allocator),
	}
	for param, index in callee.params {
		frame.vars[param] = args[index]
	}
	run_statements(i, &frame, callee.body)
	return frame.result
}

@(private = "file")
run_statements :: proc(i: ^Interp, f: ^Frame, stmts: []^IR_Stmt) {
	for stmt in stmts {
		if f.returned {
			return
		}
		switch node in stmt.variant {
		case IR_Declare:
			size := flat_size(i.ir, node.var.type)
			value := numbers(size)
			if node.init != nil {
				copy(value, interp_eval(i, f, node.init))
			}
			f.vars[node.var] = value
		case IR_Assign:
			destination, lanes := place_of(i, f, node.target)
			value := interp_eval(i, f, node.value)
			if lanes == nil {
				copy(destination, value)
			} else {
				for lane, index in lanes {
					destination[lane] = value[index]
				}
			}
		case IR_If:
			if interp_eval(i, f, node.condition)[0] != 0 {
				run_statements(i, f, node.then)
			} else {
				run_statements(i, f, node.otherwise)
			}
		case IR_For:
			from := int(interp_eval(i, f, node.from)[0])
			to := int(interp_eval(i, f, node.to)[0])
			last := to if node.inclusive else to - 1
			for counter in from ..= last {
				f.vars[node.var] = one(f32(counter))
				run_statements(i, f, node.body)
			}
		case IR_Return:
			if node.value != nil {
				f.result = interp_eval(i, f, node.value)
			}
			f.returned = true
		case IR_Eval:
			interp_eval(i, f, node.call)
		case IR_Block:
			run_statements(i, f, node.body)
		}
	}
}

// place_of is the numbers an assignment writes: a view of the variable, and the lanes of it when it is not all of it.
@(private = "file")
place_of :: proc(i: ^Interp, f: ^Frame, e: ^IR_Expr) -> (view: []f32, lanes: []int) {
	#partial switch node in e.variant {
	case IR_Var_Ref:
		return f.vars[node.var], nil
	case IR_Field:
		base, _ := place_of(i, f, node.base)
		offset := 0
		fields := fields_for(i.ir, node.base.type)
		for index in 0 ..< node.index {
			offset += flat_size(i.ir, fields[index].type)
		}
		return base[offset:offset + flat_size(i.ir, e.type)], nil
	case IR_Index:
		base, _ := place_of(i, f, node.base)
		index := int(interp_eval(i, f, node.index)[0])
		if node.base.type.kind == .VECTOR {
			result := make([]int, 1, context.temp_allocator)
			result[0] = index
			return base, result
		}
		size := flat_size(i.ir, node.base.type.elem)
		return base[index * size:(index + 1) * size], nil
	case IR_Swizzle:
		base, _ := place_of(i, f, node.base)
		result := make([]int, node.count, context.temp_allocator)
		for lane in 0 ..< node.count {
			result[lane] = int(node.indices[lane])
		}
		return base, result
	}
	panic("an assignment to something that isn't a place")
}

@(private = "file")
per_lane :: proc(a: []f32, work: proc(x: f32) -> f32) -> []f32 {
	result := numbers(len(a))
	for value, lane in a {
		result[lane] = work(value)
	}
	return result
}

@(private = "file")
per_lane2 :: proc(a, b: []f32, work: proc(x, y: f32) -> f32) -> []f32 {
	size := max(len(a), len(b))
	result := numbers(size)
	for lane in 0 ..< size {
		result[lane] = work(a[lane if len(a) > 1 else 0], b[lane if len(b) > 1 else 0])
	}
	return result
}

@(private = "file")
round_even :: proc(x: f32) -> f32 {
	f := math.floor(x)
	d := x - f
	if d > 0.5 {
		return f + 1
	}
	if d < 0.5 {
		return f
	}
	return f if math.mod(f, 2) == 0 else f + 1
}

@(private = "file")
polynomial_reference :: proc(x: f32, sine: bool) -> f32 {
	k := math.floor(x * 0.15915494309189535 + 0.5)
	r := x - 6.283185307179586 * k
	t := r * r
	if sine {
		p: f32 = 2.1478728533851322e-06
		p = p * t - 0.0001926499619928568
		p = p * t + 0.008308984952537351
		p = p * t - 0.16662438501484986
		p = p * t + 0.9999793879828708
		return r * p
	}
	p: f32 = -2.1978878103077777e-07
	p = p * t + 2.4204400324072683e-05
	p = p * t - 0.001385891587244809
	p = p * t + 0.041659822182074986
	p = p * t - 0.4999942680922626
	p = p * t + 0.9999992215743202
	return p
}

@(private = "file")
dot_of :: proc(a, b: []f32) -> f32 {
	total: f32
	for value, lane in a {
		total += value * b[lane]
	}
	return total
}

interp_eval :: proc(i: ^Interp, f: ^Frame, e: ^IR_Expr) -> []f32 {
	switch node in e.variant {
	case IR_Float:
		return one(node.value)
	case IR_Int:
		return one(f32(node.value))
	case IR_Bool:
		return one(1 if node.value else 0)
	case IR_Zero:
		return numbers(flat_size(i.ir, e.type))
	case IR_Var_Ref:
		return f.vars[node.var]
	case IR_Uniform_Ref:
		return i.uniforms[node.name]
	case IR_Texture_Ref:
		return one(0)
	case IR_Unary:
		value := interp_eval(i, f, node.operand)
		result := numbers(len(value))
		for lane in 0 ..< len(value) {
			if node.op == .NEGATE {
				result[lane] = -value[lane]
			} else {
				result[lane] = 1 if value[lane] == 0 else 0
			}
		}
		return result
	case IR_Binary:
		return interp_binary(i, f, e, node)
	case IR_Swizzle:
		base := interp_eval(i, f, node.base)
		result := numbers(node.count)
		for lane in 0 ..< node.count {
			result[lane] = base[node.indices[lane]]
		}
		return result
	case IR_Field:
		base := interp_eval(i, f, node.base)
		offset := 0
		fields := fields_for(i.ir, node.base.type)
		for index in 0 ..< node.index {
			offset += flat_size(i.ir, fields[index].type)
		}
		return base[offset:offset + flat_size(i.ir, e.type)]
	case IR_Index:
		base := interp_eval(i, f, node.base)
		index := int(interp_eval(i, f, node.index)[0])
		if node.base.type.kind == .VECTOR {
			return one(base[index])
		}
		size := flat_size(i.ir, node.base.type.elem)
		return base[index * size:(index + 1) * size]
	case IR_Convert:
		value := interp_eval(i, f, node.operand)
		if e.type.kind == .I32 || e.type.kind == .U32 {
			return one(math.trunc(value[0]))
		}
		return value
	case IR_Construct:
		parts := make([dynamic]f32, context.temp_allocator)
		for arg in node.args {
			append(&parts, ..interp_eval(i, f, arg))
		}
		return parts[:]
	case IR_Builtin_Call:
		return interp_builtin(i, f, e, node)
	case IR_Proc_Call:
		args := make([][]f32, len(node.args), context.temp_allocator)
		for arg, index in node.args {
			args[index] = interp_eval(i, f, arg)
		}
		return interp_call(i, node.callee, args)
	}
	panic("an expression the evaluator doesn't know")
}

@(private = "file")
interp_binary :: proc(i: ^Interp, f: ^Frame, e: ^IR_Expr, node: IR_Binary) -> []f32 {
	a := interp_eval(i, f, node.left)
	b := interp_eval(i, f, node.right)

	if node.left.type.kind == .MATRIX && node.op == .MUL {
		rows, columns := node.left.type.rows, node.left.type.cols
		result := numbers(rows)
		for row in 0 ..< rows {
			for column in 0 ..< columns {
				result[row] += a[row * columns + column] * b[column]
			}
		}
		return result
	}
	if node.right.type.kind == .MATRIX && node.op == .MUL {
		rows, columns := node.right.type.rows, node.right.type.cols
		result := numbers(columns)
		for column in 0 ..< columns {
			for row in 0 ..< rows {
				result[column] += a[row] * b[row * columns + column]
			}
		}
		return result
	}

	size := max(len(a), len(b))
	result := numbers(size)
	for lane in 0 ..< size {
		x, y := a[lane if len(a) > 1 else 0], b[lane if len(b) > 1 else 0]
		switch node.op {
		case .ADD:
			result[lane] = x + y
		case .SUB:
			result[lane] = x - y
		case .MUL:
			result[lane] = x * y
		case .DIV:
			result[lane] = x / y
		case .LESS:
			result[lane] = 1 if x < y else 0
		case .GREATER:
			result[lane] = 1 if x > y else 0
		case .LESS_EQUAL:
			result[lane] = 1 if x <= y else 0
		case .GREATER_EQUAL:
			result[lane] = 1 if x >= y else 0
		case .EQUAL:
			result[lane] = 1 if x == y else 0
		case .NOT_EQUAL:
			result[lane] = 1 if x != y else 0
		case .AND:
			result[lane] = 1 if x != 0 && y != 0 else 0
		case .OR:
			result[lane] = 1 if x != 0 || y != 0 else 0
		}
	}
	return result
}

@(private = "file")
interp_builtin :: proc(i: ^Interp, f: ^Frame, e: ^IR_Expr, node: IR_Builtin_Call) -> []f32 {
	args := make([][]f32, len(node.args), context.temp_allocator)
	for arg, index in node.args {
		if arg.type.kind != .TEXTURE2D {
			args[index] = interp_eval(i, f, arg)
		}
	}
	switch node.name {
	case "abs":
		return per_lane(args[0], proc(x: f32) -> f32 {return abs(x)})
	case "sign":
		return per_lane(args[0], proc(x: f32) -> f32 {return 1 if x > 0 else (-1 if x < 0 else 0)})
	case "floor":
		return per_lane(args[0], proc(x: f32) -> f32 {return math.floor(x)})
	case "ceil":
		return per_lane(args[0], proc(x: f32) -> f32 {return math.ceil(x)})
	case "trunc":
		return per_lane(args[0], proc(x: f32) -> f32 {return math.trunc(x)})
	case "round":
		return per_lane(args[0], round_even)
	case "fract":
		return per_lane(args[0], proc(x: f32) -> f32 {return x - math.floor(x)})
	case "saturate":
		return per_lane(args[0], proc(x: f32) -> f32 {return clamp(x, 0, 1)})
	case "min":
		return per_lane2(args[0], args[1], proc(x, y: f32) -> f32 {return min(x, y)})
	case "max":
		return per_lane2(args[0], args[1], proc(x, y: f32) -> f32 {return max(x, y)})
	case "clamp":
		low := per_lane2(args[0], args[1], proc(x, y: f32) -> f32 {return max(x, y)})
		return per_lane2(low, args[2], proc(x, y: f32) -> f32 {return min(x, y)})
	case "fmod":
		return per_lane2(args[0], args[1], proc(x, y: f32) -> f32 {return x - y * math.trunc(x / y)})
	case "mod":
		return per_lane2(args[0], args[1], proc(x, y: f32) -> f32 {return x - y * math.floor(x / y)})
	case "step":
		return per_lane2(args[0], args[1], proc(edge, x: f32) -> f32 {return 1 if x >= edge else 0})
	case "lerp":
		size := len(args[0])
		result := numbers(size)
		for lane in 0 ..< size {
			t := args[2][lane if len(args[2]) > 1 else 0]
			result[lane] = args[0][lane] + t * (args[1][lane] - args[0][lane])
		}
		return result
	case "smoothstep":
		size := len(args[2])
		result := numbers(size)
		for lane in 0 ..< size {
			low := args[0][lane if len(args[0]) > 1 else 0]
			high := args[1][lane if len(args[1]) > 1 else 0]
			t := clamp((args[2][lane] - low) / (high - low), 0, 1)
			result[lane] = t * t * (3 - 2 * t)
		}
		return result
	case "sqrt":
		return per_lane(args[0], proc(x: f32) -> f32 {return math.sqrt(x)})
	case "inverse_sqrt":
		return per_lane(args[0], proc(x: f32) -> f32 {return 1 / math.sqrt(x)})
	case "exp":
		return per_lane(args[0], proc(x: f32) -> f32 {return math.exp(x)})
	case "exp2":
		return per_lane(args[0], proc(x: f32) -> f32 {return math.pow(f32(2), x)})
	case "ln":
		return per_lane(args[0], proc(x: f32) -> f32 {return math.ln(x)})
	case "log2":
		return per_lane(args[0], proc(x: f32) -> f32 {return math.log2(x)})
	case "log10":
		return per_lane(args[0], proc(x: f32) -> f32 {return math.log10(x)})
	case "pow":
		return per_lane2(args[0], args[1], proc(x, y: f32) -> f32 {return math.pow(x, y)})
	case "to_radians":
		return per_lane(args[0], proc(x: f32) -> f32 {return x * (math.PI / 180)})
	case "to_degrees":
		return per_lane(args[0], proc(x: f32) -> f32 {return x * (180 / math.PI)})
	case "sin_approx":
		return per_lane(args[0], proc(x: f32) -> f32 {return polynomial_reference(x, true)})
	case "cos_approx":
		return per_lane(args[0], proc(x: f32) -> f32 {return polynomial_reference(x, false)})
	case "dot":
		return one(dot_of(args[0], args[1]))
	case "length":
		return one(math.sqrt(dot_of(args[0], args[0])))
	case "distance":
		difference := numbers(len(args[0]))
		for value, lane in args[0] {
			difference[lane] = value - args[1][lane]
		}
		return one(math.sqrt(dot_of(difference, difference)))
	case "normalize":
		length := math.sqrt(dot_of(args[0], args[0]))
		return per_lane2(args[0], one(length), proc(x, y: f32) -> f32 {return x / y})
	case "cross":
		a, b := args[0], args[1]
		result := numbers(3)
		result[0] = a[1] * b[2] - a[2] * b[1]
		result[1] = a[2] * b[0] - a[0] * b[2]
		result[2] = a[0] * b[1] - a[1] * b[0]
		return result
	case "reflect":
		projection := 2 * dot_of(args[1], args[0])
		result := numbers(len(args[0]))
		for lane in 0 ..< len(result) {
			result[lane] = args[0][lane] - projection * args[1][lane]
		}
		return result
	case "refract":
		eta := args[2][0]
		projection := dot_of(args[1], args[0])
		k := 1 - eta * eta * (1 - projection * projection)
		result := numbers(3)
		if k >= 0 {
			for lane in 0 ..< 3 {
				result[lane] = eta * args[0][lane] - (eta * projection + math.sqrt(k)) * args[1][lane]
			}
		}
		return result
	}
	panic(strings.concatenate({"the evaluator doesn't know the built-in ", node.name}, context.temp_allocator))
}

// ---- running a shader both ways -----------------------------------------------------------------------------------

// A pattern of numbers for the inputs. Each kind finds different mistakes.
Input_Kind :: enum {
	MIXED, // numbers of both signs, none near zero
	POSITIVE, // for square roots and logarithms
	TIES, // exact halves, for `round`
	WHOLE, // exact whole numbers and their neighbours
}

@(private = "file")
next_number :: proc(state: ^u32, kind: Input_Kind, counter: ^int) -> f32 {
	state^ = state^ * 1664525 + 1013904223
	unit := f32(state^ >> 8) / f32(1 << 24)
	counter^ += 1
	switch kind {
	case .MIXED:
		value := 0.3 + unit * 2.7
		return -value if state^ & 1 == 1 else value
	case .POSITIVE:
		return 0.3 + unit * 2.7
	case .TIES:
		ties := [?]f32{0.5, 1.5, 2.5, -0.5, -1.5, -2.5, 3.5, 0.25}
		return ties[counter^ % len(ties)]
	case .WHOLE:
		wholes := [?]f32{1, 2, -1, -2, 3, 0.999, 2.001, -2.999}
		return wholes[counter^ % len(wholes)]
	}
	return 0
}

@(private = "file")
fill_numbers :: proc(state: ^u32, kind: Input_Kind, counter: ^int, count: int) -> []f32 {
	result := numbers(count)
	for index in 0 ..< count {
		result[index] = next_number(state, kind, counter)
	}
	return result
}

// registers_from_flat is how a value sits in uniform registers: a scalar or a vector in one, a matrix one row each.
@(private = "file")
registers_from_flat :: proc(ir: ^IR_Module, type: ^Type, flat: []f32, into: ^[dynamic][4]f32) {
	#partial switch type.kind {
	case .MATRIX:
		for row in 0 ..< type.rows {
			register: [4]f32
			for column in 0 ..< type.cols {
				register[column] = flat[row * type.cols + column]
			}
			append(into, register)
		}
	case .ARRAY:
		size := flat_size(ir, type.elem)
		for index in 0 ..< type.count {
			registers_from_flat(ir, type.elem, flat[index * size:(index + 1) * size], into)
		}
	case .STRUCT:
		offset := 0
		for field in fields_for(ir, type) {
			size := flat_size(ir, field.type)
			registers_from_flat(ir, field.type, flat[offset:offset + size], into)
			offset += size
		}
	case:
		register: [4]f32
		for value, lane in flat {
			register[lane] = value
		}
		append(into, register)
	}
}

// fill_leaves gives the uniforms the program declared the numbers the evaluator uses, under the names the backend chose.
@(private = "file")
fill_leaves :: proc(m: ^Machine, ir: ^IR_Module, prefix: string, type: ^Type, flat: []f32) {
	leaf := type
	for leaf.kind == .ARRAY {
		leaf = leaf.elem
	}
	if leaf.kind == .STRUCT {
		if type.kind == .ARRAY {
			size := flat_size(ir, type.elem)
			for index in 0 ..< type.count {
				fill_leaves(m, ir, fmt.tprintf("%s_%d", prefix, index), type.elem, flat[index * size:(index + 1) * size])
			}
			return
		}
		offset := 0
		for field in fields_for(ir, type) {
			size := flat_size(ir, field.type)
			fill_leaves(m, ir, fmt.tprintf("%s_%s", prefix, field.name), field.type, flat[offset:offset + size])
			offset += size
		}
		return
	}
	name := pica_safe_name(prefix)
	if type.kind == .BOOL {
		if name in m.bools {
			m.bools[name] = flat[0] != 0
		}
		return
	}
	if name in m.floats {
		registers := make([dynamic][4]f32, context.temp_allocator)
		registers_from_flat(ir, type, flat, &registers)
		copy(m.floats[name], registers[:])
	}
}

// Outcome of running one shader on both.
Run_Result :: struct {
	ok:      bool,
	message: string,
}

// compare_runs runs vertex_main of the module on the evaluator and, as assembly, on the machine, and compares every
// output the vertex stage writes for the fragment stage.
compare_runs :: proc(ir: ^IR_Module, assembly: string, kind: Input_Kind, seed: u32) -> Run_Result {
	state := seed
	counter := 0
	interp := Interp {
		ir       = ir,
		uniforms = make(map[string][]f32, context.temp_allocator),
	}
	machine := Machine {
		floats  = make(map[string][][4]f32, context.temp_allocator),
		bools   = make(map[string]bool, context.temp_allocator),
		outputs = make(map[string][4]f32, context.temp_allocator),
	}
	lines := machine_load(&machine, assembly)

	for uniform in ir.uniforms {
		flat := fill_numbers(&state, kind, &counter, flat_size(ir, uniform.type))
		if uniform.type.kind == .BOOL {
			flat[0] = f32(seed % 2)
		}
		interp.uniforms[uniform.name] = flat
		fill_leaves(&machine, ir, uniform.name, uniform.type, flat)
	}

	entry := ir.vertex_main
	input_fields := fields_for(ir, entry.params[0].type)
	input := make([dynamic]f32, context.temp_allocator)
	for field, index in input_fields {
		values := fill_numbers(&state, kind, &counter, flat_size(ir, field.type))
		append(&input, ..values)
		for value, lane in values {
			machine.inputs[index][lane] = value
		}
	}

	expected := interp_call(&interp, entry, [][]f32{input[:]})
	machine_run(&machine, lines)

	offset := 0
	for field in fields_for(ir, entry.result) {
		size := flat_size(ir, field.type)
		if field.out != "" {
			got := machine.outputs[strings.concatenate({"mbs_out_", field.out}, context.temp_allocator)]
			for lane in 0 ..< size {
				want := expected[offset + lane]
				if math.is_nan(want) || math.is_inf(want, 0) {
					continue
				}
				tolerance := 2e-3 * abs(want) + 2e-4
				if abs(got[lane] - want) > tolerance || math.is_nan(got[lane]) {
					return Run_Result{false, fmt.tprintf("`%s` lane %d: the program gives %v, the shader means %v", field.out, lane, got[lane], want)}
				}
			}
		}
		offset += size
	}
	return Run_Result{true, ""}
}

// expect_pica_matches builds `source` for the 3DS and checks the program against the evaluator on several inputs.
expect_pica_matches :: proc(t: ^testing.T, source: string, name: string, kinds: []Input_Kind) -> bool {
	ir, parsed, message := build_ir_for(source, .PICA200)
	defer destroy_parsed(parsed)
	if message != "" {
		testing.expectf(t, false, "`%s` should check for the 3DS: %s", name, message)
		return false
	}
	program, problems := generate_pica(ir, context.temp_allocator)
	if len(problems) > 0 {
		testing.expectf(t, false, "`%s`: %s", name, strings.join(problems, "; ", context.temp_allocator))
		return false
	}
	good := true
	for kind in kinds {
		for seed in u32(1) ..= 6 {
			result := compare_runs(ir, program.vertex, kind, seed * 7919)
			if result.ok == false {
				fmt.eprintfln("--- %s (%v, seed %d) ---\n%s\n%s", name, kind, seed, result.message, program.vertex)
				testing.expectf(t, false, "`%s` differs from the shader's meaning: %s", name, result.message)
				good = false
				break
			}
		}
	}
	return good
}
