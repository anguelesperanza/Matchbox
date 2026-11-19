package mbsc

import "core:fmt"
import "core:strings"
import "core:testing"

// The intermediate form: a golden file for the spec's shader, and one small shader per rule of lowering.

@(private = "file")
lower_source :: proc(source: string, target := Target.PC) -> (parsed: ^Parsed, ir: ^IR_Module) {
	parsed = parse_shader("test.mbs", source)
	if parsed.has_syntax_errors {
		return
	}
	check_subset(parsed)
	if len(parsed.diagnostics) > 0 {
		return
	}
	module := build_module(parsed, target)
	if len(parsed.diagnostics) == 0 {
		ir = lower_module(module)
	}
	return
}

// dump_of lowers a shader and returns its dump, or reports what stopped it.
@(private = "file")
dump_of :: proc(t: ^testing.T, source: string, target := Target.PC) -> string {
	parsed, ir := lower_source(source, target)
	defer destroy_parsed(parsed)
	if ir == nil {
		for diagnostic in parsed.diagnostics {
			fmt.eprintfln("    %s %s (line %d)", diagnostic.code, diagnostic.title, diagnostic.label.line)
		}
		testing.expect(t, false, "the shader should lower")
		return ""
	}
	return dump_ir(ir, context.temp_allocator)
}

@(private = "file")
SOURCE_HEAD :: `Vertex_In :: struct {
	position: [3]f32 ` + "`attr:\"position\"`" + `,
	color:    [4]f32 ` + "`attr:\"color\"`" + `,
}

Varying :: struct {
	position: [4]f32 ` + "`out:\"position\"`" + `,
	color:    [4]f32 ` + "`out:\"color\"`" + `,
}

Light :: struct {
	direction: [3]f32,
	strength:  f32,
}

@(uniform) count: i32
LIMIT :: 4
SCALE :: 2.0

fragment_main :: proc(v: Varying) -> [4]f32 {
	return v.color
}
`

// A shader whose vertex body is `body`, and which also holds `extras` at the top level.
@(private = "file")
shader :: proc(body: string, extras := "") -> string {
	return strings.concatenate({SOURCE_HEAD, extras, "\nvertex_main :: proc(input: Vertex_In) -> Varying {\n\toutput: Varying\n", body, "\n\treturn output\n}\n"}, context.temp_allocator)
}

@(private = "file")
expect_has :: proc(t: ^testing.T, dump: string, piece: string, loc := #caller_location) {
	if strings.contains(dump, piece) == false {
		fmt.eprintfln("--- dump ---\n%s------------", dump)
		testing.expectf(t, false, "the dump should contain: %s", piece, loc = loc)
	}
}

@(private = "file")
expect_lacks :: proc(t: ^testing.T, dump: string, piece: string, loc := #caller_location) {
	testing.expectf(t, strings.contains(dump, piece) == false, "the dump should not contain: %s", piece, loc = loc)
}

@(test)
the_spec_shader_lowers_to_the_golden_dump :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)

	source := #load("testdata/mesh.mbs", string)
	golden, _ := strings.replace_all(#load("testdata/mesh_pc.ir.txt", string), "\r\n", "\n", context.temp_allocator)
	dump := dump_of(t, source)
	dump, _ = strings.replace_all(dump, "\r\n", "\n", context.temp_allocator)

	testing.expect(t, dump == golden, "the dump of testdata/mesh.mbs differs from testdata/mesh_pc.ir.txt")
	if dump != golden {
		fmt.eprintfln("--- got ---\n%s--- want ---\n%s", dump, golden)
	}
}

@(test)
only_the_target_line_differs_between_targets_for_a_shader_without_when :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)

	source := #load("testdata/mesh.mbs", string)
	pc := dump_of(t, source, .PC)
	vita := dump_of(t, source, .VITA)
	pica := dump_of(t, source, .PICA200)

	testing.expect(t, strings.has_prefix(pc, "target pc\n"))
	testing.expect_value(t, strings.trim_prefix(vita, "target vita\n"), strings.trim_prefix(pc, "target pc\n"))
	testing.expect_value(t, strings.trim_prefix(pica, "target 3ds\n"), strings.trim_prefix(pc, "target pc\n"))
}

@(test)
when_keeps_only_the_branch_for_the_target :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)

	extras := `
pick :: proc() -> f32 {
	when TARGET == .PICA200 {
		return 11.0
	} else {
		return 22.0
	}
}
`
	source := shader("\toutput.position.x = pick()", extras)

	pc := dump_of(t, source, .PC)
	expect_has(t, pc, "return 22.0")
	expect_lacks(t, pc, "11.0")
	expect_lacks(t, pc, "when")

	pica := dump_of(t, source, .PICA200)
	expect_has(t, pica, "return 11.0")
	expect_lacks(t, pica, "22.0")
}

@(test)
constants_are_replaced_by_their_value :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)

	dump := dump_of(t, shader("\tx := 3.0 * SCALE\n\tfor i in 0..<LIMIT {\n\t}"))
	expect_has(t, dump, "(3.0 * 2.0):f32")
	expect_has(t, dump, "in 0..<4")
	expect_lacks(t, dump, "SCALE")
	expect_lacks(t, dump, "LIMIT")
}

@(test)
a_constant_ignores_a_local_of_the_same_name :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)

	dump := dump_of(t, shader("\tSCALE := 5.0\n\tx := SCALE\n\textra := helper()", "helper :: proc() -> f32 {\n\treturn SCALE\n}\n"))
	expect_has(t, dump, "return 2.0")
	expect_has(t, dump, "var x#3: f32 = SCALE#2")
}

@(test)
compound_assignment_is_written_out :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)

	dump := dump_of(t, shader("\tx := 1.0\n\tx += 2.0\n\tx *= x\n\toutput.color.xy -= input.position.xy"))
	expect_has(t, dump, "x#2 = (x#2 + 2.0):f32")
	expect_has(t, dump, "x#2 = (x#2 * x#2):f32")
	expect_has(t, dump, "output#1.color.xy = (output#1.color.xy - input#0.position.xy):[2]f32")
}

@(test)
struct_literals_list_every_field_in_order :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)

	dump := dump_of(t, shader("\ta := Light{strength = 2.0}\n\tb := Light{{1.0, 2.0, 3.0}, 4.0}\n\tc := Light{}\n\td := Light{strength = 5.0, direction = {0.0, 1.0, 0.0}}"))
	expect_has(t, dump, "var a#2: Light = Light{zero:[3]f32, 2.0}")
	expect_has(t, dump, "var b#3: Light = Light{[3]f32{1.0, 2.0, 3.0}, 4.0}")
	expect_has(t, dump, "var c#4: Light = zero:Light")
	expect_has(t, dump, "var d#5: Light = Light{[3]f32{0.0, 1.0, 0.0}, 5.0}")
}

@(test)
swizzles_become_component_numbers :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)

	dump := dump_of(t, shader("\tv := input.color.bgr\n\tw := input.color.a\n\tu := input.color.xxyy"))
	expect_has(t, dump, "input#0.color.zyx")
	expect_has(t, dump, "input#0.color.w")
	expect_has(t, dump, "input#0.color.xxyy")
}

@(test)
loops_keep_their_bounds_and_inclusiveness :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)

	dump := dump_of(t, shader("\ttotal := 0.0\n\tfor i in 1..=count {\n\t\ttotal += f32(i)\n\t}\n\tfor j in 0..<LIMIT {\n\t\ttotal += 1.0\n\t}"))
	expect_has(t, dump, "for i#3 in 1..=count")
	expect_has(t, dump, "total#2 = (total#2 + f32(i#3)):f32")
	expect_has(t, dump, "for j#4 in 0..<4")
}

@(test)
shadowed_names_get_different_numbers :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)

	dump := dump_of(t, shader("\tx := 1.0\n\tif x > 0.0 {\n\t\tx := 2.0\n\t\toutput.position.x = x\n\t}\n\toutput.position.y = x"))
	expect_has(t, dump, "var x#2: f32 = 1.0")
	expect_has(t, dump, "var x#3: f32 = 2.0")
	expect_has(t, dump, "output#1.position.x = x#3")
	expect_has(t, dump, "output#1.position.y = x#2")
}

@(test)
helpers_come_before_their_callers_and_unused_ones_are_dropped :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)

	extras := `
outer :: proc(x: f32) -> f32 {
	return inner(x) + 1.0
}
inner :: proc(x: f32) -> f32 {
	return x * 2.0
}
unused :: proc() -> f32 {
	return 99.0
}
`
	dump := dump_of(t, shader("\toutput.position.x = outer(0.5)", extras))

	inner_at := strings.index(dump, "proc inner")
	outer_at := strings.index(dump, "proc outer")
	vertex_at := strings.index(dump, "proc vertex_main")
	testing.expect(t, inner_at >= 0 && inner_at < outer_at && outer_at < vertex_at, "inner, then outer, then vertex_main")
	expect_lacks(t, dump, "unused")
	expect_lacks(t, dump, "99.0")
}

@(test)
operators_literals_and_calls_keep_their_types :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)

	dump := dump_of(t, shader("\tn := -1\n\tm := u32(2)\n\tok := !(1.0 < 2.0) || true\n\tc := clamp(input.position.x, 0.0, 1.0)\n\ti := i32(2.5)\n\tf := (1.0 + 2.0) * 3.0"))
	expect_has(t, dump, "var n#2: i32 = (-1):i32")
	expect_has(t, dump, "var m#3: u32 = u32(2)")
	expect_has(t, dump, "((!(1.0 < 2.0):bool):bool || true):bool")
	expect_has(t, dump, "clamp(input#0.position.x, 0.0, 1.0):f32")
	expect_has(t, dump, "i32(2.5)")
	expect_has(t, dump, "((1.0 + 2.0):f32 * 3.0):f32")
}

@(test)
the_ir_tree_has_the_types_and_stages :: proc(t: ^testing.T) {
	parsed, ir := lower_source(shader("\toutput.position.x = 1.0"))
	defer destroy_parsed(parsed)

	testing.expect(t, ir != nil)
	testing.expect_value(t, ir.vertex_main.stage, IR_Stage.VERTEX)
	testing.expect_value(t, ir.fragment_main.stage, IR_Stage.FRAGMENT)
	testing.expect_value(t, ir.vertex_main.name, "vertex_main")
	testing.expect_value(t, len(ir.vertex_main.params), 1)
	testing.expect_value(t, ir.vertex_main.params[0].kind, IR_Var_Kind.PARAM)
	testing.expect_value(t, len(ir.procs), 2)
	testing.expect_value(t, len(ir.structs), 3)
	testing.expect_value(t, ir.structs[0].name, "Vertex_In")
	testing.expect_value(t, ir.structs[0].fields[0].attr, "position")
	testing.expect_value(t, ir.structs[1].fields[0].out, "position")
	testing.expect_value(t, len(ir.uniforms), 1)
	testing.expect_value(t, ir.uniforms[0].kind, Uniform_Kind.GAME)

	first := ir.vertex_main.body[0].variant.(IR_Declare)
	testing.expect(t, first.init == nil, "`output: Varying` has no value, so it starts as zero")
	testing.expect_value(t, first.var.type.kind, Type_Kind.STRUCT)
}

@(test)
a_shader_with_errors_is_not_lowered :: proc(t: ^testing.T) {
	parsed, ir := lower_source(shader("\tx := 1.0 + 2"))
	defer destroy_parsed(parsed)

	testing.expect(t, ir == nil)
	testing.expect(t, len(parsed.diagnostics) > 0)
}
