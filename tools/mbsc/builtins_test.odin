package mbsc

import "core:fmt"
import "core:strings"
import "core:testing"

// Every built-in, written as HLSL and handed to the real compiler. The table below must have a case for each entry
// of BUILTINS, so adding a built-in without a case fails a test.

Builtin_Case :: struct {
	name: string,
	body: string, // statements that leave an f32 in `r`; the inputs are the uniforms in INPUTS
}

INPUTS :: `@(uniform) a: f32
@(uniform) b: f32
@(uniform) c: f32
@(uniform) n: i32
@(uniform) v2: [2]f32
@(uniform) w2: [2]f32
@(uniform) v3: [3]f32
@(uniform) w3: [3]f32
@(uniform) v4: [4]f32
@(uniform) w4: [4]f32
@(uniform) m4: matrix[4, 4]f32
@(uniform) m3: matrix[3, 3]f32
@(texture = 0) tex: Texture2D
`

CASES := [?]Builtin_Case {
	{"abs", "r = abs(a) + abs(v3).x"},
	{"sign", "r = sign(a) + sign(v4).w"},
	{"floor", "r = floor(a) + floor(v2).y"},
	{"ceil", "r = ceil(a) + ceil(v3).z"},
	{"trunc", "r = trunc(a) + trunc(v4).x"},
	{"round", "r = round(a) + round(v2).x"},
	{"fract", "r = fract(a) + fract(v3).y"},
	{"saturate", "r = saturate(a) + saturate(v4).z"},
	{"min", "r = min(a, b) + min(v3, w3).x + min(v2, a).y"},
	{"max", "r = max(a, b) + max(v3, w3).x + max(v2, a).y"},
	{"clamp", "r = clamp(a, b, c) + clamp(v3, w3, v3).x + clamp(v2, 0.0, 1.0).y"},
	{"fmod", "r = fmod(a, b) + fmod(v3, w3).x + fmod(v2, a).y"},
	{"mod", "r = mod(a, b) + mod(v3, w3).x + mod(v2, a).y + mod(v4, w4).w"},
	{"step", "r = step(a, b) + step(v3, w3).x + step(a, v2).y"},
	{"lerp", "r = lerp(a, b, c) + lerp(v3, w3, v3).x + lerp(v2, w2, a).y"},
	{"smoothstep", "r = smoothstep(a, b, c) + smoothstep(v3, w3, v3).x + smoothstep(0.0, 1.0, v2).y"},
	{"sqrt", "r = sqrt(a) + sqrt(v3).x"},
	{"inverse_sqrt", "r = inverse_sqrt(a) + inverse_sqrt(v3).x"},
	{"exp", "r = exp(a) + exp(v3).x"},
	{"exp2", "r = exp2(a) + exp2(v3).x"},
	{"ln", "r = ln(a) + ln(v3).x"},
	{"log2", "r = log2(a) + log2(v3).x"},
	{"log10", "r = log10(a) + log10(v3).x"},
	{"pow", "r = pow(a, b) + pow(v3, w3).x + pow(v2, a).y"},
	{"to_radians", "r = to_radians(a) + to_radians(v3).x"},
	{"to_degrees", "r = to_degrees(a) + to_degrees(v3).x"},
	{"sin_approx", "r = sin_approx(a) + sin_approx(v3).x"},
	{"cos_approx", "r = cos_approx(a) + cos_approx(v3).x"},
	{"sin", "r = sin(a) + sin(v3).x"},
	{"cos", "r = cos(a) + cos(v3).x"},
	{"tan", "r = tan(a) + tan(v3).x"},
	{"asin", "r = asin(a) + asin(v3).x"},
	{"acos", "r = acos(a) + acos(v3).x"},
	{"atan", "r = atan(a) + atan(v3).x"},
	{"atan2", "r = atan2(a, b) + atan2(v3, w3).x + atan2(v2, a).y"},
	{"sinh", "r = sinh(a) + sinh(v3).x"},
	{"cosh", "r = cosh(a) + cosh(v3).x"},
	{"tanh", "r = tanh(a) + tanh(v3).x"},
	{"ldexp", "r = ldexp(a, b) + ldexp(v3, w3).x"},
	{"is_nan", "if is_nan(a) {\n\t\tr = 1.0\n\t}"},
	{"is_inf", "if is_inf(a) {\n\t\tr = 1.0\n\t}"},
	{"dot", "r = dot(v2, w2) + dot(v3, w3) + dot(v4, w4)"},
	{"length", "r = length(v2) + length(v3) + length(v4)"},
	{"distance", "r = distance(v2, w2) + distance(v3, w3) + distance(v4, w4)"},
	{"normalize", "r = normalize(v2).x + normalize(v3).y + normalize(v4).w"},
	{"cross", "r = cross(v3, w3).z"},
	{"reflect", "r = reflect(v2, w2).x + reflect(v3, w3).y + reflect(v4, w4).z"},
	{"refract", "r = refract(v3, w3, a).y"},
	{"dot3_signed", "r = dot3_signed(v3, w3) + dot3_signed(v4, w4)"},
	{"transpose", "r = (transpose(m4) * v4).y + (v4 * transpose(m4)).x"},
	{"determinant", "r = determinant(m4) + determinant(m3)"},
	{"sample", "r = sample(tex, v2).x"},
	{"sample_lod", "r = sample_lod(tex, v2, a).y"},
	{"sample_bias", "r = sample_bias(tex, v2, a).z"},
	{"sample_grad", "r = sample_grad(tex, v2, v2, w2).w"},
	{"ddx", "r = ddx(a) + ddx(v3).x"},
	{"ddy", "r = ddy(a) + ddy(v3).x"},
	{"fwidth", "r = fwidth(a) + fwidth(v3).x"},
	{"discard", "if a < 0.0 {\n\t\tdiscard()\n\t}"},
}

in_stage :: proc(case_: Builtin_Case, vertex: bool) -> string {
	body := case_.body
	if vertex {
		return strings.concatenate(
			{
				INPUTS,
				"\nVertex_In :: struct {\n\tposition: [3]f32 `attr:\"position\"`,\n}\n\nVarying :: struct {\n\tposition: [4]f32 `out:\"position\"`,\n}\n\n",
				"vertex_main :: proc(input: Vertex_In) -> Varying {\n\toutput: Varying\n\tr: f32\n\t",
				body,
				"\n\toutput.position = [4]f32{r, input.position.x, 0.0, 1.0}\n\treturn output\n}\n\n",
				"fragment_main :: proc(v: Varying) -> [4]f32 {\n\treturn v.position\n}\n",
			},
			context.temp_allocator,
		)
	}
	return strings.concatenate(
		{
			INPUTS,
			"\nVertex_In :: struct {\n\tposition: [3]f32 `attr:\"position\"`,\n}\n\nVarying :: struct {\n\tposition: [4]f32 `out:\"position\"`,\n}\n\n",
			"vertex_main :: proc(input: Vertex_In) -> Varying {\n\toutput: Varying\n\toutput.position = [4]f32{input.position.x, input.position.y, 0.0, 1.0}\n\treturn output\n}\n\n",
			"fragment_main :: proc(v: Varying) -> [4]f32 {\n\tr: f32\n\t",
			body,
			"\n\treturn [4]f32{r, r, r, 1.0}\n}\n",
		},
		context.temp_allocator,
	)
}

@(private = "file")
generate_for :: proc(t: ^testing.T, source: string, name: string) -> (text: string, ok: bool) {
	parsed := parse_shader("test.mbs", source)
	defer destroy_parsed(parsed)
	if parsed.has_syntax_errors == false {
		check_subset(parsed)
	}
	module: ^Module
	if len(parsed.diagnostics) == 0 {
		module = build_module(parsed, .PC)
	}
	if len(parsed.diagnostics) > 0 {
		fmt.eprintfln("--- %s ---\n%s", name, source)
		for diagnostic in parsed.diagnostics {
			fmt.eprintfln("    %s %s (line %d)", diagnostic.code, diagnostic.title, diagnostic.label.line)
		}
		testing.expectf(t, false, "`%s`: the test shader should check", name)
		return "", false
	}
	problems: []string
	text, problems = generate_hlsl(lower_module(module), context.temp_allocator)
	if len(problems) > 0 {
		fmt.eprintfln("--- %s ---\n%s", name, source)
		testing.expectf(t, false, "`%s`: %s", name, strings.join(problems, "\n", context.temp_allocator))
		return "", false
	}
	return text, true
}

@(test)
every_builtin_has_a_case :: proc(t: ^testing.T) {
	for builtin in BUILTINS {
		found := false
		for case_ in CASES {
			if case_.name == builtin.name {
				found = true
			}
		}
		testing.expectf(t, found, "the built-in `%s` has no case in builtins_test.odin", builtin.name)
	}
	for case_ in CASES {
		found := false
		for builtin in BUILTINS {
			if case_.name == builtin.name {
				found = true
			}
		}
		testing.expectf(t, found, "the case `%s` isn't a built-in", case_.name)
	}
}

@(test)
every_builtin_is_written_as_hlsl_that_compiles :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)

	for case_ in CASES {
		fragment_only := false
		for builtin in BUILTINS {
			if builtin.name == case_.name {
				fragment_only = builtin.fragment_only
			}
		}
		for vertex in ([2]bool{false, true}) {
			if vertex && fragment_only {
				continue
			}
			text, ok := generate_for(t, in_stage(case_, vertex), case_.name)
			if ok {
				expect_compiles(t, text)
			}
		}
	}
}

@(test)
every_builtin_is_written_as_cg_that_compiles :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)

	for case_ in CASES {
		fragment_only := false
		for builtin in BUILTINS {
			if builtin.name == case_.name {
				fragment_only = builtin.fragment_only
			}
		}
		for vertex in ([2]bool{false, true}) {
			if vertex && fragment_only {
				continue
			}
			programs, ok := generate_cg_text(t, in_stage(case_, vertex), case_.name)
			if ok {
				// only the stage the built-in is in is worth compiling: the other one is the plain wrapper
				message, ran := compile_cg(programs.vertex if vertex else programs.fragment, vertex)
				if ran && message != "" {
					fmt.eprintfln("--- %s (%s) ---\n%s", case_.name, "vertex" if vertex else "fragment", message)
					testing.expectf(t, false, "psp2cgc rejected `%s` in the %s program", case_.name, "vertex" if vertex else "fragment")
				}
			}
		}
	}
}
