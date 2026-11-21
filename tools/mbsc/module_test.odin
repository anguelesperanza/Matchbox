package mbsc

import "core:fmt"
import "core:strings"
import "core:testing"

@(private = "file")
MESH :: #load("testdata/mesh.mbs", string)

// A small shader that passes every check, with the pieces the cases below break one at a time.
@(private = "file")
VERTEX_IN :: `Vertex_In :: struct {
	position: [3]f32 ` + "`attr:\"position\"`" + `,
	color:    [4]f32 ` + "`attr:\"color\"`" + `,
}

`

@(private = "file")
VARYING :: `Varying :: struct {
	position: [4]f32 ` + "`out:\"position\"`" + `,
	color:    [4]f32 ` + "`out:\"color\"`" + `,
}
`

@(private = "file")
STRUCTS :: VERTEX_IN + VARYING

@(private = "file")
ENTRIES :: `
vertex_main :: proc(input: Vertex_In) -> Varying {
	output: Varying
	return output
}

fragment_main :: proc(v: Varying) -> [4]f32 {
	return v.color
}
`

@(private = "file")
build :: proc(source: string, target := Target.PC) -> (^Parsed, ^Module) {
	parsed := parse_shader("test.mbs", source)
	if parsed.has_syntax_errors {
		return parsed, nil
	}
	check_subset(parsed)
	return parsed, build_module(parsed, target)
}

@(private = "file")
Case :: struct {
	name:   string,
	source: string,
	code:   string,
	line:   int, // 0: don't check the line
	title:  string, // a piece of the title
}

@(test)
declarations_report_what_is_wrong :: proc(t: ^testing.T) {
	cases := []Case {
		// attributes and variables
		{"unknown attribute", STRUCTS + "@(unifrom) c: f32\n" + ENTRIES, "MBS-E24", 10, "unknown attribute"},
		{"global variable", STRUCTS + "d: f32\n" + ENTRIES, "MBS-E24", 10, "not a uniform or a texture"},
		{"uniform with a value", STRUCTS + "@(uniform) d: f32 = 1.0\n" + ENTRIES, "MBS-E24", 10, "can't be given a value"},
		{"unknown block", STRUCTS + "@(uniform = .FRAMES) frame: struct { time: f32 }\n" + ENTRIES, "MBS-E24", 10, "unknown uniform block"},
		{"texture with no slot", STRUCTS + "@(texture) a: Texture2D\n" + ENTRIES, "MBS-E24", 10, "can't be used here"},
		{"slot is not a number", STRUCTS + "@(texture = 1.5) a: Texture2D\n" + ENTRIES, "MBS-E24", 10, "whole number"},
		{"attribute on a constant", STRUCTS + "@(uniform) K :: 1.0\n" + ENTRIES, "MBS-E24", 10, "can't be used here"},
		{"texture of the wrong type", STRUCTS + "@(texture = 0) a: f32\n" + ENTRIES, "MBS-E13", 10, "`Texture2D`"},
		{"two textures in one slot", STRUCTS + "@(texture = 0) a: Texture2D\n@(texture = 0) b: Texture2D\n" + ENTRIES, "MBS-E25", 11, "slot 0 is used twice"},
		{"name declared twice", STRUCTS + "K :: 1.0\nK :: 2.0\n" + ENTRIES, "MBS-E25", 11, "declared twice"},
		{"predeclared name", STRUCTS + "TARGET :: 1\n" + ENTRIES, "MBS-E25", 10, "declared twice"},
		{"two frame blocks", STRUCTS + "@(uniform = .FRAME) a: struct { time: f32 }\n@(uniform = .FRAME) b: struct { time: f32 }\n" + ENTRIES, "MBS-E25", 11, "declared twice"},
		{"bad field tag", "Vertex_In :: struct {\n\tposition: [3]f32 `attr`,\n}\n" + ENTRIES, "MBS-E24", 2, "can't be read"},

		// engine uniforms
		{"unknown engine field", STRUCTS + "@(uniform = .RENDER) render: struct { tnt: [4]f32, tint: [4]f32 }\n" + ENTRIES, "MBS-E18", 10, "no field `tnt`"},
		{"engine field of the wrong type", STRUCTS + "@(uniform = .RENDER) render: struct { tint: [3]f32 }\n" + ENTRIES, "MBS-E13", 10, "wrong type"},
		{"engine block that isn't a struct", STRUCTS + "@(uniform = .RENDER) render: f32\n" + ENTRIES, "MBS-E13", 10, "must be a struct"},

		// when
		{"unknown target", STRUCTS + "when TARGET == .PICA2000 {\n\tK :: 1\n}\n" + ENTRIES, "MBS-E23", 10, "not a target"},
		{"when without TARGET", STRUCTS + "when true && sin(1.0) > 0.0 {\n\tK :: 1\n}\n" + ENTRIES, "MBS-E23", 10, "can't be decided"},

		// entry points
		{"missing fragment_main", STRUCTS + "vertex_main :: proc(input: Vertex_In) -> Varying {\n\toutput: Varying\n\treturn output\n}\n", "MBS-E15", 1, "`fragment_main` is missing"},
		{"missing vertex_main", STRUCTS + "fragment_main :: proc(v: Varying) -> [4]f32 {\n\treturn v.color\n}\n", "MBS-E15", 1, "`vertex_main` is missing"},
		{"entry that is not a procedure", STRUCTS + "vertex_main :: 1\nfragment_main :: proc(v: Varying) -> [4]f32 {\n\treturn v.color\n}\n", "MBS-E15", 10, "must be a procedure"},
		{"vertex_main with two parameters", STRUCTS + "vertex_main :: proc(a: Vertex_In, b: f32) -> Varying {\n\toutput: Varying\n\treturn output\n}\nfragment_main :: proc(v: Varying) -> [4]f32 {\n\treturn v.color\n}\n", "MBS-E15", 10, "one parameter"},
		{"vertex_main with no result", STRUCTS + "vertex_main :: proc(input: Vertex_In) {\n}\nfragment_main :: proc(v: Varying) -> [4]f32 {\n\treturn v.color\n}\n", "MBS-E15", 10, "one value"},
		{"unknown struct", STRUCTS + "vertex_main :: proc(input: Vertex_Inn) -> Varying {\n\toutput: Varying\n\treturn output\n}\nfragment_main :: proc(v: Varying) -> [4]f32 {\n\treturn v.color\n}\n", "MBS-E14", 10, "`Vertex_Inn`"},
		{"fragment_main takes the wrong struct", STRUCTS + "Other :: struct {\n\tposition: [4]f32 `out:\"position\"`,\n}\nvertex_main :: proc(input: Vertex_In) -> Varying {\n\toutput: Varying\n\treturn output\n}\nfragment_main :: proc(v: Other) -> [4]f32 {\n\treturn {}\n}\n", "MBS-E15", 17, "must take `Varying`"},
		{"fragment_main returns the wrong type", STRUCTS + "vertex_main :: proc(input: Vertex_In) -> Varying {\n\toutput: Varying\n\treturn output\n}\nfragment_main :: proc(v: Varying) -> [3]f32 {\n\treturn {}\n}\n", "MBS-E15", 14, "`[4]f32`"},

		// the vertex input and the varying
		{"vertex field without attr", "Vertex_In :: struct {\n\tposition: [3]f32,\n}\n" + VARYING + ENTRIES, "MBS-E15", 2, "no `attr:` tag"},
		{"unknown attribute value", "Vertex_In :: struct {\n\tposition: [3]f32 `attr:\"positon\"`,\n}\n" + VARYING + ENTRIES, "MBS-E24", 2, "not a known attribute"},
		{"out on the vertex input", "Vertex_In :: struct {\n\tposition: [3]f32 `attr:\"position\" out:\"position\"`,\n}\n" + VARYING + ENTRIES, "MBS-E24", 2, "`out:` is for the vertex output"},
		{"no position output", "Vertex_In :: struct {\n\tposition: [3]f32 `attr:\"position\"`,\n}\nVarying :: struct {\n\tcolor: [4]f32 `out:\"color\"`,\n}\n" + ENTRIES, "MBS-E15", 4, "no `out:\"position\"`"},
		{"position of the wrong type", "Vertex_In :: struct {\n\tposition: [3]f32 `attr:\"position\"`,\n}\nVarying :: struct {\n\tposition: [3]f32 `out:\"position\"`,\n}\n" + ENTRIES, "MBS-E15", 5, "must be `[4]f32`"},
		{"two position outputs", "Vertex_In :: struct {\n\tposition: [3]f32 `attr:\"position\"`,\n}\nVarying :: struct {\n\tposition: [4]f32 `out:\"position\"`,\n\tother: [4]f32 `out:\"position\"`,\n}\n" + ENTRIES, "MBS-E25", 6, "two fields write `position`"},
		{"unknown output", "Vertex_In :: struct {\n\tposition: [3]f32 `attr:\"position\"`,\n}\nVarying :: struct {\n\tposition: [4]f32 `out:\"position\"`,\n\tcolor: [4]f32 `out:\"colour\"`,\n}\n" + ENTRIES, "MBS-E24", 6, "not a known output"},
		{"attr on the varying", "Vertex_In :: struct {\n\tposition: [3]f32 `attr:\"position\"`,\n}\nVarying :: struct {\n\tposition: [4]f32 `out:\"position\" attr:\"position\"`,\n}\n" + ENTRIES, "MBS-E24", 5, "`attr:` is for the vertex input"},
	}

	for entry in cases {
		parsed, _ := build(entry.source)
		defer destroy_parsed(parsed)

		found := false
		for diagnostic in parsed.diagnostics {
			if diagnostic.code == entry.code && strings.contains(diagnostic.title, entry.title) {
				found = true
				if entry.line != 0 {
					testing.expectf(t, diagnostic.label.line == entry.line, "%s: on line %d, wanted %d", entry.name, diagnostic.label.line, entry.line)
				}
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
a_correct_shader_has_no_messages_for_every_target :: proc(t: ^testing.T) {
	for target in Target {
		for source in ([]string{STRUCTS + ENTRIES, MESH}) {
			parsed, module := build(source, target)
			defer destroy_parsed(parsed)

			for diagnostic in parsed.diagnostics {
				testing.expectf(t, false, "%v: unexpected %s: %s (line %d)", target, diagnostic.code, diagnostic.title, diagnostic.label.line)
			}
			testing.expect(t, module != nil)
		}
	}
}

@(test)
the_module_holds_what_the_shader_declares :: proc(t: ^testing.T) {
	parsed, module := build(MESH)
	defer destroy_parsed(parsed)

	testing.expect_value(t, len(module.structs), 2)
	testing.expect_value(t, len(module.procs), 2)
	testing.expect_value(t, len(module.textures), 1)
	testing.expect_value(t, len(module.uniforms), 2)
	testing.expect_value(t, module.textures[0].name, "tex")
	testing.expect_value(t, module.textures[0].slot, 0)
	testing.expect_value(t, module.uniforms[0].kind, Uniform_Kind.FRAME)
	testing.expect_value(t, module.uniforms[1].kind, Uniform_Kind.RENDER)
	testing.expect_value(t, len(module.uniforms[1].block.fields), 4)

	if testing.expect(t, module.vertex_in != nil && module.varying != nil) {
		testing.expect_value(t, module.vertex_in.name, "Vertex_In")
		testing.expect_value(t, module.varying.name, "Varying")
		testing.expect_value(t, module.varying.fields[1].out, "texcoord0")
		testing.expect_value(t, module.vertex_in.fields[1].attr, "texcoord")
	}
	testing.expect(t, module.vertex_main != nil && module.fragment_main != nil)
}

@(test)
when_picks_the_branch_for_the_target :: proc(t: ^testing.T) {
	source := STRUCTS + `
when TARGET == .PICA200 {
	ONLY_3DS :: 1
} else {
	NOT_3DS :: 2
}

when TARGET != .VITA && !(TARGET == .PC && false) {
	NOT_VITA :: 3
}

when .VITA == TARGET || TARGET == .PC {
	VITA_OR_PC :: 4
}
` + ENTRIES

	expected := [Target][]string {
		.PC      = {"NOT_3DS", "NOT_VITA", "VITA_OR_PC"},
		.VITA    = {"NOT_3DS", "VITA_OR_PC"},
		.PICA200 = {"ONLY_3DS", "NOT_VITA"},
	}
	for target in Target {
		parsed, module := build(source, target)
		defer destroy_parsed(parsed)

		testing.expect_value(t, len(parsed.diagnostics), 0)
		names := make([dynamic]string, context.temp_allocator)
		for constant in module.constants {
			append(&names, constant.name)
		}
		testing.expectf(t, strings.join(names[:], ",", context.temp_allocator) == strings.join(expected[target], ",", context.temp_allocator), "%v: %v", target, names[:])
	}
}

@(test)
when_can_give_each_target_its_own_entry_point :: proc(t: ^testing.T) {
	source := STRUCTS + `
vertex_main :: proc(input: Vertex_In) -> Varying {
	output: Varying
	return output
}

when TARGET == .PICA200 {
	fragment_main :: proc(v: Varying) -> [4]f32 {
		return v.color
	}
} else {
	fragment_main :: proc(v: Varying) -> [4]f32 {
		return v.color * 2.0
	}
}
`
	for target in Target {
		parsed, module := build(source, target)
		defer destroy_parsed(parsed)

		testing.expect_value(t, len(parsed.diagnostics), 0)
		testing.expect(t, module.fragment_main != nil)
	}
}

@(test)
tags_are_read :: proc(t: ^testing.T) {
	tags, ok := parse_tag("`attr:\"position\" out:\"texcoord0\"`")
	defer delete(tags)
	testing.expect(t, ok)
	if testing.expect_value(t, len(tags), 2) {
		testing.expect_value(t, tags[0], Tag{"attr", "position"})
		testing.expect_value(t, tags[1], Tag{"out", "texcoord0"})
	}

	empty_tags, empty_ok := parse_tag("")
	testing.expect(t, empty_ok)
	delete(empty_tags)

	for bad in ([]string{"`attr`", "`attr:position`", "`attr:\"position`", "`:\"x\"`"}) {
		bad_tags, bad_ok := parse_tag(bad)
		testing.expect(t, bad_ok == false, bad)
		delete(bad_tags)
	}
}

@(test)
names_are_suggested_when_close :: proc(t: ^testing.T) {
	suggestion, found := suggest_name("tnt", {"model", "tint", "uv_rectangle"})
	testing.expect(t, found)
	testing.expect_value(t, suggestion, "tint")

	_, far := suggest_name("banana", {"model", "tint", "uv_rectangle"})
	testing.expect(t, far == false)

	key := type_key("matrix[4, 4]f32")
	defer delete(key)
	testing.expect_value(t, key, "matrix[4,4]f32")
}
