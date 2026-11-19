package mbsc

import "core:strings"

// What the engine provides to every shader. The reference is docs/shader_language.md, sections 4 and 5, and
// the engine's own Frame_Constants and Draw_Constants in render_windows.odin.

Engine_Field :: struct {
	name: string,
	type: string, // written without spaces, as type_key makes it
}

@(rodata)
FRAME_FIELDS := [?]Engine_Field{{"view_projection", "matrix[4,4]f32"}, {"time", "f32"}}

@(rodata)
DRAW_FIELDS := [?]Engine_Field{{"model", "matrix[4,4]f32"}, {"tint", "[4]f32"}, {"uv_rect", "[4]f32"}, {"alpha_cutoff", "f32"}}

// The vertex attributes the engine's mesh format has today. More come with the 3D work.
@(rodata)
VERTEX_ATTRIBUTES := [?]string{"position", "texcoord", "color"}

// The names a vertex stage can write for the fragment stage (part 1, section 4, "Varyings").
@(rodata)
VARYING_OUTPUTS := [?]string{"position", "color", "texcoord0", "texcoord1", "texcoord2", "normalquat", "view"}

// Names that exist before the shader declares anything.
@(rodata)
PREDECLARED_NAMES := [?]string{"TARGET", "Target", "Texture2D"}

// type_key writes a type the way the engine tables do, with the spaces taken out, so `matrix[4, 4]f32` and
// `matrix[4,4]f32` compare equal.
type_key :: proc(text: string, allocator := context.allocator) -> string {
	builder := strings.builder_make(allocator)
	for character in transmute([]u8)text {
		if character != ' ' && character != '\t' && character != '\r' && character != '\n' {
			strings.write_byte(&builder, character)
		}
	}
	return strings.to_string(builder)
}

// suggest_name finds the candidate closest to `name`, when one is close enough to be a likely typing mistake.
suggest_name :: proc(name: string, candidates: []string) -> (suggestion: string, found: bool) {
	best := 3 // a name must be within two edits
	for candidate in candidates {
		distance := edit_distance(name, candidate)
		if distance < best {
			best = distance
			suggestion = candidate
			found = true
		}
	}
	return
}

// edit_distance is the number of single-letter changes (add, remove, swap one) between two words.
@(private = "file")
edit_distance :: proc(a, b: string) -> int {
	if len(a) == 0 {
		return len(b)
	}
	if len(b) == 0 {
		return len(a)
	}
	previous := make([]int, len(b) + 1, context.temp_allocator)
	current := make([]int, len(b) + 1, context.temp_allocator)
	for j in 0 ..= len(b) {
		previous[j] = j
	}
	for i in 1 ..= len(a) {
		current[0] = i
		for j in 1 ..= len(b) {
			cost := 0 if a[i - 1] == b[j - 1] else 1
			current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + cost)
		}
		previous, current = current, previous
	}
	return previous[len(b)]
}

// display_type turns an engine type key back into the way a shader writes it: `matrix[4,4]f32` to `matrix[4, 4]f32`.
display_type :: proc(key: string) -> string {
	result, _ := strings.replace_all(key, ",", ", ")
	return result
}
