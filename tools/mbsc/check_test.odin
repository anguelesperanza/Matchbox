package mbsc

import "core:fmt"
import "core:odin/ast"
import "core:odin/tokenizer"
import "core:strings"
import "core:testing"

// A shader that checks cleanly, with one place for the vertex body and one for extra top-level code, so each
// case below changes one thing.

@(private = "file")
HEAD :: `Vertex_In :: struct {
	position: [3]f32 ` + "`attr:\"position\"`" + `,
	uv:       [2]f32 ` + "`attr:\"texcoord\"`" + `,
	color:    [4]f32 ` + "`attr:\"color\"`" + `,
}

Varying :: struct {
	position: [4]f32 ` + "`out:\"position\"`" + `,
	uv:       [2]f32 ` + "`out:\"texcoord0\"`" + `,
	color:    [4]f32 ` + "`out:\"color\"`" + `,
}

@(uniform = .FRAME) frame: struct { view_projection: matrix[4, 4]f32 }
@(uniform = .RENDER) render: struct {
	model:        matrix[4, 4]f32,
	tint:         [4]f32,
	uv_rectangle: [4]f32,
	alpha_cutoff: f32,
}
@(uniform) count: i32
@(uniform) palette: [4][4]f32
@(texture = 0) tex: Texture2D

LIMIT :: 4
`

@(private = "file")
GOOD_VERTEX :: `	output.position = frame.view_projection * [4]f32{input.position.x, input.position.y, input.position.z, 1.0}
	output.color = input.color * render.tint
	output.uv = lerp(render.uv_rectangle.xy, render.uv_rectangle.zw, input.uv)
	return output`

@(private = "file")
FRAGMENT :: `
fragment_main :: proc(v: Varying) -> [4]f32 {
	color := sample(tex, v.uv) * v.color
	if color.a < render.alpha_cutoff do discard()
	return color
}
`

@(private = "file")
shader :: proc(vertex_body: string, extras := "") -> string {
	return strings.concatenate({HEAD, extras, "\nvertex_main :: proc(input: Vertex_In) -> Varying {\n\toutput: Varying\n", vertex_body, "\n}\n", FRAGMENT}, context.temp_allocator)
}

@(private = "file")
check :: proc(source: string, target := Target.PC) -> ^Parsed {
	parsed := parse_shader("test.mbs", source)
	if parsed.has_syntax_errors {
		return parsed
	}
	check_subset(parsed)
	if len(parsed.diagnostics) == 0 {
		build_module(parsed, target)
	}
	return parsed
}

@(private = "file")
Case :: struct {
	name:   string,
	source: string,
	code:   string,
	title:  string, // a piece of the title
}

@(test)
the_type_checker_reports_what_is_wrong :: proc(t: ^testing.T) {
	// A statement in the vertex body, written before the `return`.
	body :: proc(statement: string) -> string {
		return strings.concatenate({"\t", statement, "\n", GOOD_VERTEX}, context.temp_allocator)
	}

	cases := []Case {
		// numbers don't convert
		{"float plus int literal", shader(body("x := 1.0 + 2")), "MBS-E13", "cannot apply `+`"},
		{"int plus float literal", shader(body("x := 1 + 2.0")), "MBS-E13", "cannot apply `+`"},
		{"float times int variable", shader(body("n := 2\n\tx := 1.0 * n")), "MBS-E13", "cannot apply `*`"},
		{"vector times int literal", shader(body("x := render.tint * 2")), "MBS-E13", "cannot apply `*`"},
		{"declared f32 given an int", shader(body("x: f32 = 1")), "MBS-E13", "expected `f32`, found `i32`"},
		{"literal element of the wrong type", shader(body("x := [4]f32{1.0, 0.0, 0.0, 1}")), "MBS-E13", "expected `f32`, found `i32`"},
		{"too few values in a literal", shader(body("x := [4]f32{1.0, 0.0}")), "MBS-E13", "needs 4 values"},
		{"bool arithmetic", shader(body("x := true + 1.0")), "MBS-E13", "cannot apply `+`"},
		{"vector comparison", shader(body("x := render.tint == render.tint")), "MBS-E13", "cannot apply `==`"},
		{"vectors of different length", shader(body("x := input.position + input.uv")), "MBS-E13", "cannot apply `+`"},
		{"matrix times the wrong vector", shader(body("x := frame.view_projection * input.position")), "MBS-E13", "cannot apply `*`"},
		{"if on a number", shader(body("if 1.0 {\n\t}")), "MBS-E13", "needs a `bool`"},
		{"negate a bool", shader(body("x := -true")), "MBS-E13", "cannot apply `-`"},
		{"convert a vector", shader(body("x := f32(input.position)")), "MBS-E13", "cannot convert"},
		{"index with a float", shader(body("x := palette[1.0]")), "MBS-E13", "must be a whole number"},
		{"index a number", shader(body("n := 1.0\n\tx := n[0]")), "MBS-E13", "cannot index"},
		{"field of a number", shader(body("n := 1.0\n\tx := n.field")), "MBS-E13", "has no fields"},
		{"call named arguments", shader(body("x := lerp(a = 1.0, b = 2.0, t = 0.5)")), "MBS-E13", "can't name its arguments"},
		{"expression statement", shader(body("1.0 + 2.0")), "MBS-E13", "does nothing"},
		{"no value from a call", shader(body("x := nothing()"), "nothing :: proc() {\n}\n"), "MBS-E13", "has no value"},
		{"literal with no type", shader(body("x := {}")), "MBS-E13", "cannot tell the type"},
		{"procedure as a value", shader(body("x := vertex_main")), "MBS-E13", "is a procedure"},
		{"type as a value", shader(body("x := Varying")), "MBS-E13", "is a type"},

		// built-ins
		{"built-in with the wrong types", shader(body("x := dot(input.position, input.uv)")), "MBS-E13", "can't be called"},
		{"built-in with the wrong count", shader(body("x := lerp(1.0, 2.0)")), "MBS-E13", "can't be called"},
		{"built-in given an int", shader(body("x := sqrt(4)")), "MBS-E13", "can't be called"},
		{"swizzle past the length", shader(body("x := input.position.xw")), "MBS-E13", "no component or swizzle"},
		{"swizzle mixing sets", shader(body("x := input.color.xg")), "MBS-E13", "no component or swizzle"},

		// names
		{"unknown variable", shader(body("x := colr")), "MBS-E14", "cannot find `colr`"},
		{"unknown procedure", shader(body("x := lorp(1.0, 2.0, 0.5)")), "MBS-E14", "cannot find the procedure"},
		{"not a built-in", shader(body("x := rcp(2.0)")), "MBS-E14", "not a built-in"},
		{"unknown struct field", shader(body("x := input.colr")), "MBS-E14", "has no field `colr`"},
		{"unknown type", shader(body("x: Foo")), "MBS-E14", "cannot find the type"},
		{"unknown literal field", shader(body("x := Varying{colr = input.color}")), "MBS-E14", "has no field"},
		{"engine field the shader leaves out", shader(body("x := frame.time")), "MBS-E14", "doesn't declare `frame.time`"},
		{"engine field that doesn't exist", shader(body("x := render.tnt")), "MBS-E18", "no field `tnt`"},
		{"TARGET outside a when", shader(body("if TARGET == .PC {\n\t}")), "MBS-E23", "only available in a `when`"},
		{"redeclared local", shader(body("x := 1.0\n\tx := 2.0")), "MBS-E25", "declared twice"},

		// loops
		{"loop bound is a variable", shader(body("n := 4\n\tfor i in 0..<n {\n\t}")), "MBS-E7", "not a constant"},
		{"loop bound is arithmetic on a uniform", shader(body("for i in 0..<count + 1 {\n\t}")), "MBS-E7", "not a constant"},
		{"loop bound is a float", shader(body("for i in 0..<2.0 {\n\t}")), "MBS-E13", "expected `i32`"},

		// assignment
		{"assign to a uniform", shader(body("count = 1")), "MBS-E27", "cannot assign to `count`"},
		{"assign to a field of a uniform", shader(body("render.tint = render.tint")), "MBS-E27", "cannot assign to `render`"},
		{"assign to a parameter", shader(body("input = input")), "MBS-E27", "cannot assign to `input`"},
		{"assign to a local constant", shader(body("K :: 1.0\n\tK = 2.0")), "MBS-E27", "cannot assign to `K`"},
		{"assign to a repeated swizzle", shader(body("output.uv.xx = input.uv")), "MBS-E27", "twice"},
		{"assign to a call", shader(body("lerp(1.0, 2.0, 0.5) = 1.0")), "MBS-E27", "can't be assigned to"},
		{"assign the wrong type", shader(body("x := 1.0\n\tx = 1")), "MBS-E13", "expected `f32`, found `i32`"},
		{"compound assign to the wrong type", shader(body("x := 1.0\n\tx += 1")), "MBS-E13", "cannot apply `+=`"},

		// procedures and returns
		{"missing return", shader(GOOD_VERTEX, "f :: proc(x: f32) -> f32 {\n\tif x > 0.0 {\n\t\treturn 1.0\n\t}\n}\n"), "MBS-E13", "doesn't return a value on every path"},
		{"wrong return type", shader(GOOD_VERTEX, "f :: proc(x: f32) -> f32 {\n\treturn 1\n}\n"), "MBS-E13", "expected `f32`, found `i32`"},
		{"value returned from a void procedure", shader(GOOD_VERTEX, "f :: proc() {\n\treturn 1.0\n}\n"), "MBS-E13", "returns nothing"},
		{"nothing returned from a typed procedure", shader(GOOD_VERTEX, "f :: proc() -> f32 {\n\treturn\n}\n"), "MBS-E13", "must return"},
		{"call with the wrong argument count", shader(body("x := f(1.0, 2.0)"), "f :: proc(x: f32) -> f32 {\n\treturn x\n}\n"), "MBS-E13", "takes 1 argument"},
		{"call with the wrong argument type", shader(body("x := f(1)"), "f :: proc(x: f32) -> f32 {\n\treturn x\n}\n"), "MBS-E13", "expected `f32`, found `i32`"},
		{"call a variable", shader(body("x := 1.0\n\ty := x(2.0)")), "MBS-E13", "is not a procedure"},

		// recursion and stages
		{"direct recursion", shader(GOOD_VERTEX, "fade :: proc(x: f32) -> f32 {\n\treturn fade(x - 1.0)\n}\n"), "MBS-E17", "calls itself"},
		{"mutual recursion", shader(GOOD_VERTEX, "ping :: proc(x: f32) -> f32 {\n\treturn pong(x)\n}\npong :: proc(x: f32) -> f32 {\n\treturn ping(x)\n}\n"), "MBS-E17", "call each other"},
		{"three procedures in a cycle", shader(GOOD_VERTEX, "a :: proc(x: f32) -> f32 {\n\treturn b(x)\n}\nb :: proc(x: f32) -> f32 {\n\treturn c(x)\n}\nc :: proc(x: f32) -> f32 {\n\treturn a(x)\n}\n"), "MBS-E17", "cycle of calls"},
		{"discard in the vertex stage", shader(body("discard()")), "MBS-E26", "only available in the fragment stage"},
		{"derivative reached through a helper", shader(body("x := f(1.0)"), "f :: proc(x: f32) -> f32 {\n\treturn ddx(x)\n}\n"), "MBS-E26", "`ddx`"},
	}

	for entry in cases {
		parsed := check(entry.source)
		defer destroy_parsed(parsed)

		found := false
		for diagnostic in parsed.diagnostics {
			if diagnostic.code == entry.code && strings.contains(diagnostic.title, entry.title) {
				found = true
				break
			}
		}
		if found == false {
			testing.expectf(t, false, "%s: no %s with '%s' (got %d messages)", entry.name, entry.code, entry.title, len(parsed.diagnostics))
			for diagnostic in parsed.diagnostics {
				fmt.eprintfln("    %s %s (line %d)", diagnostic.code, diagnostic.title, diagnostic.label.line)
			}
		}
	}
}

@(test)
one_mistake_gives_one_message :: proc(t: ^testing.T) {
	// `x` is unknown, so the `+` and the `lerp` that use it say nothing more.
	parsed := check(shader("\ty := lerp(x, 1.0, 0.5) + 1.0\n" + GOOD_VERTEX))
	defer destroy_parsed(parsed)

	testing.expect_value(t, len(parsed.diagnostics), 1)
}

@(test)
every_construct_of_the_language_checks_cleanly :: proc(t: ^testing.T) {
	extras := `
Light :: struct {
	direction: [3]f32,
	strength:  f32,
}

shade :: proc(light: Light, normal: [3]f32) -> f32 {
	return max(dot(normalize(light.direction), normal), 0.0) * light.strength
}

fold :: proc(values: [4]f32) -> f32 {
	total := 0.0
	for i in 0..<LIMIT {
		total += values[i]
	}
	for i in 1..=count {
		total -= 1.0
	}
	return total
}

pulse :: proc(time: f32) -> f32 {
	when TARGET == .PICA200 {
		return 1.0
	} else {
		return 0.75 + 0.25 * sin(time * 8.0)
	}
}

branch :: proc(x: f32) -> f32 {
	if x > 1.0 && x < 2.0 || !(x == 0.0) {
		return -x / 2.0
	} else if x >= 3.0 {
		return x
	} else {
		return 0.0
	}
}
`
	body := `	light := Light{direction = {0.0, 1.0, 0.0}, strength = 2.0}
	other := Light{input.position, 1.0}
	zero := Light{}
	n := input.position.zyx
	n.xy = input.uv
	s := shade(light, n) + shade(other, n) + shade(zero, n)
	k := f32(count) + fold(palette[0]) + pulse(s) + branch(s)
	m := frame.view_projection * render.model
	p := m * [4]f32{n.x, n.y, n.z, 1.0}
	q := [4]f32{1.0, 0.0, 0.0, 1.0} * k
	w := p.xyz * s + q.rgb
	i := u32(3) + u32(count)
	b := i > u32(1) && is_nan(k) == false
	t := smoothstep(0.0, 1.0, k) + clamp(k, 0.0, 1.0) + step(0.5, k) + mod(k, 2.0) + fmod(k, 2.0) + pow(k, 2.0)
	v := min(w, 1.0) + abs(w) + saturate(w) + lerp(w, w, 0.5) + floor(w) + fract(w) + round(w)
	d := length(w) + distance(w, w) + dot(w, w)
	c := cross(w, w) + reflect(w, w) + refract(w, w, 1.5) + normalize(w)
	e := transpose(m)
	f := determinant(m)
	output.position = p + q
	output.color = input.color * render.tint * t
	output.uv = input.uv
	if b {
		output.uv.x = d + f
	}
	return output`

	// The 3DS can't do some of these (`sin`, `m * n`, whole-number arithmetic in the vertex stage); what it can't
	// do is in errors_test.odin and capability_test.odin.
	for target in Target {
		if target == .PICA200 {
			continue
		}
		parsed := parse_shader("test.mbs", shader(body, extras))
		defer destroy_parsed(parsed)
		check_subset(parsed)
		module := build_module(parsed, target)

		for diagnostic in parsed.diagnostics {
			testing.expectf(t, false, "%v: unexpected %s: %s (line %d)", target, diagnostic.code, diagnostic.title, diagnostic.label.line)
		}
		if len(parsed.diagnostics) == 0 {
			// and every one of those constructs lowers, and prints
			ir := lower_module(module)
			text := dump_ir(ir)
			testing.expectf(t, len(text) > 0, "%v: empty dump", target)
			delete(text)
		}
	}
}

@(test)
the_spec_mesh_shader_checks_cleanly :: proc(t: ^testing.T) {
	parsed := check(#load("testdata/mesh.mbs", string))
	defer destroy_parsed(parsed)

	for diagnostic in parsed.diagnostics {
		testing.expectf(t, false, "unexpected %s: %s (line %d)", diagnostic.code, diagnostic.title, diagnostic.label.line)
	}
}

@(test)
every_expression_gets_a_type :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	parsed := parse_shader("test.mbs", shader(GOOD_VERTEX))
	defer destroy_parsed(parsed)
	check_subset(parsed)
	module := build_module(parsed, .PC)

	testing.expect_value(t, len(parsed.diagnostics), 0)
	testing.expect(t, len(module.types) > 20)

	// The uv_rectangle swizzle is a [2]f32, and the lerp of two of them is too.
	found_lerp := false
	for expr, type in module.types {
		if call, is_call := expr.derived.(^ast.Call_Expr); is_call {
			if callee, is_ident := call.expr.derived.(^ast.Ident); is_ident && callee.name == "lerp" {
				found_lerp = true
				testing.expect_value(t, temp_type_name(type), "[2]f32")
			}
		}
	}
	testing.expect(t, found_lerp)

	testing.expect_value(t, len(module.signatures), 2)
	testing.expect_value(t, temp_type_name(module.signatures["fragment_main"].result), "[4]f32")
	testing.expect_value(t, temp_type_name(module.signatures["vertex_main"].result), "Varying")
}

@(test)
binary_type_follows_the_arithmetic_rules :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	defer free_all(context.temp_allocator)
	f32_type, i32_type, bool_type := &TYPE_F32, &TYPE_I32, &TYPE_BOOL
	vec3 := make_vector(f32_type, 3)
	vec4 := make_vector(f32_type, 4)
	mat4 := make_matrix(4, 4)

	expect :: proc(t: ^testing.T, op: tokenizer.Token_Kind, a, b: ^Type, want: string) {
		result, ok := binary_type(op, a, b)
		if want == "" {
			testing.expectf(t, ok == false, "%v %v %v should not be allowed", type_name(a), op, type_name(b))
			return
		}
		testing.expectf(t, ok, "%v %v %v should be allowed", type_name(a), op, type_name(b))
		if ok {
			testing.expect_value(t, type_name(result), want)
		}
	}

	expect(t, .Add, f32_type, f32_type, "f32")
	expect(t, .Add, f32_type, i32_type, "")
	expect(t, .Mul, vec3, f32_type, "[3]f32")
	expect(t, .Mul, f32_type, vec3, "[3]f32")
	expect(t, .Quo, vec3, vec3, "[3]f32")
	expect(t, .Add, vec3, vec4, "")
	expect(t, .Mul, mat4, vec4, "[4]f32")
	expect(t, .Mul, vec4, mat4, "[4]f32")
	expect(t, .Mul, mat4, mat4, "matrix[4, 4]f32")
	expect(t, .Mul, mat4, vec3, "")
	expect(t, .Add, mat4, mat4, "matrix[4, 4]f32")
	expect(t, .Add, mat4, f32_type, "")
	expect(t, .Lt, f32_type, f32_type, "bool")
	expect(t, .Lt, vec3, vec3, "")
	expect(t, .Cmp_Eq, bool_type, bool_type, "bool")
	expect(t, .Cmp_And, bool_type, bool_type, "bool")
	expect(t, .Cmp_And, f32_type, bool_type, "")
}

@(test)
swizzles_follow_the_vector_length :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	defer free_all(context.temp_allocator)
	vec3 := make_vector(&TYPE_F32, 3)

	Want :: struct {
		name, type: string,
	}
	wants := [?]Want{{"x", "f32"}, {"zyx", "[3]f32"}, {"xx", "[2]f32"}, {"rgb", "[3]f32"}, {"b", "f32"}, {"xyzx", "[4]f32"}}
	for entry in wants {
		name, want := entry.name, entry.type
		result, ok := swizzle_type(vec3, name)
		testing.expectf(t, ok, name)
		if ok {
			testing.expect_value(t, type_name(result), want)
		}
	}
	for name in ([]string{"w", "xw", "a", "xg", "xyzwx", "", "q"}) {
		_, ok := swizzle_type(vec3, name)
		testing.expectf(t, ok == false, name)
	}
}

@(private = "file")
temp_type_name :: proc(t: ^Type) -> string {
	context.allocator = context.temp_allocator
	return type_name(t)
}
