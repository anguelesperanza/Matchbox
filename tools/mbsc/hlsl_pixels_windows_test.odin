package mbsc

import "core:fmt"
import "core:math"
import "core:strings"
import "core:testing"

// What the generated HLSL does when it runs, on Direct3D 11's software device (see gpu_windows_test.odin).

// mbs_to_hlsl runs the whole pipeline on a shader for the PC; `message` says what stopped it.
@(private = "file")
mbs_to_hlsl :: proc(source: string) -> (text: string, message: string) {
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
		return "", fmt.aprintf("%s %s (line %d)", parsed.diagnostics[0].code, parsed.diagnostics[0].title, parsed.diagnostics[0].label.line, allocator = context.temp_allocator)
	}
	problems: []string
	text, problems = generate_hlsl(lower_module(module), context.temp_allocator)
	if len(problems) > 0 {
		return "", strings.join(problems, "\n", context.temp_allocator)
	}
	return text, ""
}

// ---- the hand-written shader against the generated one ----------------------------------------------------------

@(private = "file")
IDENTITY :: [16]f32{1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1}

// The engine's constant buffers, field by field (Frame_Constants and Draw_Constants in render_windows.odin).
@(private = "file")
frame_constants :: proc() -> []f32 {
	// view_projection scales by 0.9, as a camera might; Odin lays a matrix out by columns
	values := make([]f32, 20, context.temp_allocator)
	copy(values, []f32{0.9, 0, 0, 0, 0, 0.9, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1})
	values[16] = 1.5 // time
	return values
}

@(private = "file")
draw_constants :: proc(tint_in: [4]f32, uv_rect_in: [4]f32, alpha_cutoff: f32) -> []f32 {
	tint, uv_rect := tint_in, uv_rect_in
	values := make([]f32, 28, context.temp_allocator)
	// model moves the quad by (0.1, -0.1)
	copy(values, []f32{1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0.1, -0.1, 0, 1})
	copy(values[16:20], tint[:])
	copy(values[20:24], uv_rect[:])
	values[24] = alpha_cutoff
	return values
}

// A quad that fills most of the target, with a colour at each corner.
@(private = "file")
QUAD_VERTICES := [?]f32 {
	// position           uv        color
	-0.8, -0.8, 0.0, 0.0, 1.0, 1.0, 0.5, 0.25, 1.0,
	0.8, -0.8, 0.0, 1.0, 1.0, 0.25, 1.0, 0.5, 0.75,
	0.8, 0.8, 0.0, 1.0, 0.0, 0.5, 0.25, 1.0, 0.5,
	-0.8, 0.8, 0.0, 0.0, 0.0, 1.0, 1.0, 0.5, 1.0,
}

@(private = "file")
QUAD_INDICES := [?]u16{0, 1, 2, 0, 2, 3}

// A 4 x 4 texture whose texels all differ, in colour and in alpha.
@(private = "file")
test_texture :: proc(linear: bool) -> Gpu_Texture {
	rgba := make([]u8, 4 * 4 * 4, context.temp_allocator)
	for y in 0 ..< 4 {
		for x in 0 ..< 4 {
			start := (y * 4 + x) * 4
			rgba[start] = u8(x * 80 + 15)
			rgba[start + 1] = u8(y * 80 + 15)
			rgba[start + 2] = u8(255 - x * y * 20)
			rgba[start + 3] = u8(40 + (x + y) * 30)
		}
	}
	return {width = 4, height = 4, rgba = rgba, linear = linear}
}

@(private = "file")
render_mesh :: proc(hlsl: string, pixel_entry: cstring, draw: []f32, linear: bool) -> (pixels: []f32, message: string) {
	return gpu_render(
		Gpu_Job {
			hlsl = hlsl,
			vertex_entry = "vertex_main",
			pixel_entry = pixel_entry,
			width = 32,
			height = 32,
			vertices = QUAD_VERTICES[:],
			indices = QUAD_INDICES[:],
			frame = frame_constants(),
			draw = draw,
			texture = test_texture(linear),
		},
	)
}

@(test)
the_generated_mesh_shader_draws_what_the_hand_written_one_does :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)

	generated, message := mbs_to_hlsl(string(#load("../../matchbox/shaders/mesh.mbs", string)))
	if message != "" {
		testing.expectf(t, false, "mesh.mbs: %s", message)
		return
	}
	handwritten := string(#load("testdata/mesh_handwritten.hlsl", string))

	Scene :: struct {
		name:    string,
		tint:    [4]f32,
		uv_rect: [4]f32,
		cutoff:  f32,
		linear:  bool,
	}
	scenes := [?]Scene {
		{"a plain tinted quad", {1, 1, 1, 1}, {0, 0, 1, 1}, 0, false},
		{"a tint that changes colour and alpha", {1, 0.5, 0.25, 0.8}, {0, 0, 1, 1}, 0, false},
		{"a sprite taken from part of the texture", {1, 1, 1, 1}, {0.25, 0.5, 0.75, 1.0}, 0, false},
		{"linear filtering", {0.9, 1, 0.8, 1}, {0, 0, 1, 1}, 0, true},
		{"an alpha cut-off that drops some texels", {1, 1, 1, 1}, {0, 0, 1, 1}, 0.5, false},
		{"an alpha cut-off that drops all of them", {1, 1, 1, 1}, {0, 0, 1, 1}, 2.0, false},
	}

	plain_written := 0
	for scene in scenes {
		draw := draw_constants(scene.tint, scene.uv_rect, scene.cutoff)
		want, want_message := render_mesh(handwritten, "pixel_main", draw, scene.linear)
		if want_message != "" {
			testing.expectf(t, false, "%s, hand-written: %s", scene.name, want_message)
			continue
		}
		got, got_message := render_mesh(generated, "fragment_main", draw, scene.linear)
		if got_message != "" {
			testing.expectf(t, false, "%s, generated: %s", scene.name, got_message)
			continue
		}

		written := 0
		worst: f32
		for index in 0 ..< len(want) / 4 {
			a := pixel_at(want, 32, index % 32, index / 32)
			b := pixel_at(got, 32, index % 32, index / 32)
			if (a.x == UNWRITTEN) != (b.x == UNWRITTEN) {
				testing.expectf(t, false, "%s: pixel %d,%d is drawn by one shader and not the other", scene.name, index % 32, index / 32)
				break
			}
			if a.x == UNWRITTEN {
				continue
			}
			written += 1
			for part in 0 ..< 4 {
				worst = max(worst, abs(a[part] - b[part]))
			}
		}
		testing.expectf(t, worst <= 1e-6, "%s: the shaders differ by %v", scene.name, worst)

		// the comparison means nothing if neither shader drew anything, or if the cut-off didn't cut
		switch scene.cutoff {
		case 0:
			testing.expectf(t, written > 200, "%s: only %d pixels were drawn", scene.name, written)
			if plain_written == 0 {
				plain_written = written
			}
		case 0.5:
			testing.expectf(t, written > 0 && written < plain_written, "%s: %d pixels were drawn, against %d without the cut-off", scene.name, written, plain_written)
		case:
			testing.expectf(t, written == 0, "%s: %d pixels were drawn", scene.name, written)
		}
	}
}

// ---- numbers ----------------------------------------------------------------------------------------------------

// evaluate runs a fragment-stage expression on the software device and returns its four components. `inputs` are
// the shader's uniforms `p`, `q` and `r`, in that order; `expression` is an `[4]f32` made from them.
@(private = "file")
evaluate :: proc(expression: string, inputs: [][4]f32) -> (result: [4]f32, message: string) {
	names := [3]string{"p", "q", "r"}
	source := strings.builder_make(context.temp_allocator)
	game := make([]f32, len(inputs) * 4, context.temp_allocator)
	for input_value, index in inputs {
		input := input_value
		fmt.sbprintfln(&source, "@(uniform) %s: [4]f32", names[index])
		copy(game[index * 4:], input[:])
	}
	fmt.sbprint(
		&source,
		"\nVertex_In :: struct {\n\tposition: [3]f32 `attr:\"position\"`,\n}\n\nVarying :: struct {\n\tposition: [4]f32 `out:\"position\"`,\n}\n\n",
		"vertex_main :: proc(input: Vertex_In) -> Varying {\n\toutput: Varying\n\toutput.position = [4]f32{input.position.x, input.position.y, 0.0, 1.0}\n\treturn output\n}\n\n",
		"fragment_main :: proc(v: Varying) -> [4]f32 {\n\treturn ",
		expression,
		"\n}\n",
	)

	hlsl, hlsl_message := mbs_to_hlsl(strings.to_string(source))
	if hlsl_message != "" {
		return {}, hlsl_message
	}
	// one triangle that covers the whole 1 x 1 target
	vertices := [?]f32{-1, -1, 0, 0, 0, 0, 0, 0, 0, 3, -1, 0, 0, 0, 0, 0, 0, 0, -1, 3, 0, 0, 0, 0, 0, 0, 0}
	indices := [?]u16{0, 1, 2}
	pixels, render_message := gpu_render(
		Gpu_Job {
			hlsl = hlsl,
			vertex_entry = "vertex_main",
			pixel_entry = "fragment_main",
			width = 1,
			height = 1,
			vertices = vertices[:],
			indices = indices[:],
			game = game,
		},
	)
	if render_message != "" {
		return {}, render_message
	}
	return pixel_at(pixels, 1, 0, 0), ""
}

@(private = "file")
expect_close :: proc(t: ^testing.T, what: string, got, want: f32, tolerance: f32 = 1e-6, loc := #caller_location) {
	testing.expectf(t, abs(got - want) <= tolerance, "%s: got %v, want %v", what, got, want, loc = loc)
}

@(test)
mod_takes_the_sign_of_the_divisor_and_fmod_of_the_dividend :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)

	got, message := evaluate("[4]f32{mod(p.x, q.x), mod(p.y, q.y), fmod(p.x, q.x), fmod(p.y, q.y)}", {{-1, 5.5, 0, 0}, {3, -2, 0, 0}})
	if message != "" {
		testing.expect(t, false, message)
		return
	}
	expect_close(t, "mod(-1, 3)", got.x, 2)
	expect_close(t, "mod(5.5, -2)", got.y, -0.5)
	expect_close(t, "fmod(-1, 3)", got.z, -1)
	expect_close(t, "fmod(5.5, -2)", got.w, 1.5)

	// a vector and a single number
	got, message = evaluate("mod(p, q.x)", {{-1, 7, -7.5, 2.5}, {3, 0, 0, 0}})
	if message != "" {
		testing.expect(t, false, message)
		return
	}
	expect_close(t, "mod(-1, 3)", got.x, 2)
	expect_close(t, "mod(7, 3)", got.y, 1)
	expect_close(t, "mod(-7.5, 3)", got.z, 1.5)
	expect_close(t, "mod(2.5, 3)", got.w, 2.5)
}

@(test)
round_goes_to_the_even_neighbour_on_a_half :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)

	got, message := evaluate("round(p)", {{0.5, 1.5, 2.5, -2.5}})
	if message != "" {
		testing.expect(t, false, message)
		return
	}
	expect_close(t, "round(0.5)", got.x, 0)
	expect_close(t, "round(1.5)", got.y, 2)
	expect_close(t, "round(2.5)", got.z, 2)
	expect_close(t, "round(-2.5)", got.w, -2)
}

@(test)
sin_approx_and_cos_approx_stay_within_their_stated_error :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)

	// the error stated in section 15 of the language reference is 6.2e-06 (sin) and 1.2e-06 (cos) up to pi, and the
	// promise is 1e-05 up to 10 pi; the small allowance on top is the float arithmetic of the device itself
	inputs := [8]f32{0, 0.5, 1, 2, 3.1415927, -2.5, 10, 31}
	worst_sin: f32
	worst_cos: f32
	for start := 0; start < len(inputs); start += 4 {
		x := [4]f32{inputs[start], inputs[start + 1], inputs[start + 2], inputs[start + 3]}
		sines, sine_message := evaluate("sin_approx(p)", {x})
		cosines, cosine_message := evaluate("cos_approx(p)", {x})
		if sine_message != "" || cosine_message != "" {
			testing.expect(t, false, sine_message if sine_message != "" else cosine_message)
			return
		}
		for part in 0 ..< 4 {
			angle := f64(x[part])
			worst_sin = max(worst_sin, abs(sines[part] - f32(math.sin(angle))))
			worst_cos = max(worst_cos, abs(cosines[part] - f32(math.cos(angle))))
		}
	}
	testing.expectf(t, worst_sin <= 1.2e-5, "sin_approx is off by %v", worst_sin)
	testing.expectf(t, worst_cos <= 1.2e-5, "cos_approx is off by %v", worst_cos)
}

@(test)
dot3_signed_recentres_the_colours_before_the_dot :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)

	// the fourth component is not part of the dot
	got, message := evaluate("[4]f32{dot3_signed(p, q), dot3_signed(p, p), 0.0, 1.0}", {{1, 0.5, 0, 0.9}, {1, 0.5, 0.25, 0.1}})
	if message != "" {
		testing.expect(t, false, message)
		return
	}
	// a - 0.5 = (0.5, 0, -0.5) and b - 0.5 = (0.5, 0, -0.25): the dot is 0.375, and four times that is 1.5
	expect_close(t, "dot3_signed(p, q)", got.x, 1.5)
	// p against itself: (0.25 + 0 + 0.25) * 4
	expect_close(t, "dot3_signed(p, p)", got.y, 2)
}
