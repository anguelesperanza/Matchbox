package matchbox

import "core:fmt"
import "core:os"
import "core:strings"

import "vendor:directx/d3d11"

/*
	What a loaded game shader holds (PC). `Shader.data` points at one. The shader is up to two pipelines, as the built-ins
	are several: `plain` draws Vertex and Lit_Vertex meshes (name.pc.hlsl), `skinned` draws Skinned_Vertex ones
	(name_skinned.pc.hlsl). The two share the game's uniforms: one block, written by set_shader_value, so they must
	declare the same ones
*/
@(private)
Shader_Data :: struct {
	name:             string,
	plain:            Render_Pipeline,
	has_plain:        bool,
	reads_normal:     bool, // the plain pipeline needs a Lit_Vertex mesh; a plain Vertex one has no normal to give it
	skinned:          Render_Pipeline,
	has_skinned:      bool,
	reflection_texts: [2]string, // the reflections' strings point into these, so they live as long as the shader
	game_constants:   ^d3d11.IBuffer,
	game_shadow:      []byte,
	game_dirty:       bool,
}

/*
	Loads a game's shader by name, from `assets/pc/shaders/` and then `assets/shaders/`: `<name>.pc.hlsl` with its
	`<name>.pc.refl`, both written by tools/mbsc, and optionally `<name>_skinned.pc.hlsl` and `.pc.refl` for skinned
	models. Compiles at once, so call it between frames, as with `load_model`. Stops with a message if the files are not there
*/
load_shader :: proc(name: string) -> Shader {
	shader, ok := load_shader_checked(name)
	if ok == false do panic("Failed to load shader")
	return shader
}

/*
	The same as load_shader, but a file that is not there or a reflection that cannot be read is `ok` = false, with the
	reason printed, instead of a stop. A shader that does not compile still stops, with the compiler's message: that is a
	mistake in the shader, not in what the game asked for
*/
load_shader_checked :: proc(name: string) -> (shader: Shader, ok: bool) {
	data := new(Shader_Data)
	data.name = strings.clone(name)

	if load_shader_variant(data, name, false) == false {
		free_shader_data(data)
		return {}, false
	}
	// Optional: a shader that leaves it out draws skinned meshes with the built-in
	skinned_name := strings.concatenate({name, "_skinned"}, context.temp_allocator)
	if skinned_path, found := find_shader_file(skinned_name, ".pc.hlsl"); found {
		delete(skinned_path)
		if load_shader_variant(data, skinned_name, true) == false {
			free_shader_data(data)
			return {}, false
		}
	}

	if data.has_plain && data.has_skinned && data.plain.reflection.blocks[.GAME].size != data.skinned.reflection.blocks[.GAME].size {
		print("Shader", name, "and its _skinned variant declare different game uniforms; they have to match")
		free_shader_data(data)
		return {}, false
	}

	// The game's uniforms: one block, as big as the shader says, starting out as zeros
	reflection := &data.plain.reflection if data.has_plain else &data.skinned.reflection
	if reflection.blocks[.GAME].present && reflection.blocks[.GAME].size > 0 {
		data.game_shadow = make([]byte, reflection.blocks[.GAME].size)
		data.game_constants = create_constant_buffer(u32(len(data.game_shadow)))
		data.game_dirty = true
	}
	return Shader{data = data}, true
}

/*Reads one `.pc.hlsl` and `.pc.refl` pair and makes its pipeline in `data`*/
@(private = "file")
load_shader_variant :: proc(data: ^Shader_Data, name: string, skinned: bool) -> bool {
	hlsl_path, hlsl_found := find_shader_file(name, ".pc.hlsl")
	if hlsl_found == false {
		print("No such shader file:", name)
		return false
	}
	defer delete(hlsl_path)
	refl_path, refl_found := find_shader_file(name, ".pc.refl")
	if refl_found == false {
		print("No reflection file for shader (build it with mbsc --emit-reflection):", name)
		return false
	}
	defer delete(refl_path)

	source, source_error := os.read_entire_file(hlsl_path, context.allocator)
	if source_error != nil {
		print("Could not read shader", hlsl_path)
		return false
	}
	defer delete(source)
	refl_bytes, refl_error := os.read_entire_file(refl_path, context.allocator)
	if refl_error != nil {
		print("Could not read shader reflection", refl_path)
		return false
	}
	// Kept: the pipeline's reflection points into it
	refl_text := string(refl_bytes)
	data.reflection_texts[1 if skinned else 0] = refl_text

	// create_render_pipeline parses it again and stops on a bad one; this way a bad file is `ok` = false instead
	checked, parse_ok, parse_message := parse_reflection(refl_text)
	if parse_ok == false {
		print("Shader", name, ":", parse_message)
		return false
	}
	destroy_reflection(&checked)

	label := strings.clone_to_cstring(hlsl_path, context.temp_allocator)
	pipeline := create_render_pipeline(source, refl_text, label, lit = true, skinned = skinned)
	if skinned {
		data.skinned = pipeline
		data.has_skinned = true
	} else {
		data.plain = pipeline
		data.has_plain = true
		for attribute in pipeline.reflection.attributes {
			if attribute.name == "normal" do data.reads_normal = true
		}
	}
	return true
}

/*Finds `<name><extension>` in assets/pc/shaders and then assets/shaders. The caller deletes the path*/
@(private = "file")
find_shader_file :: proc(name, extension: string) -> (path: string, found: bool) {
	file := strings.concatenate({name, extension}, context.temp_allocator)
	return find_asset(file, .SHADER)
}

@(private = "file")
free_shader_data :: proc(data: ^Shader_Data) {
	if data.has_plain do destroy_render_pipeline(&data.plain)
	if data.has_skinned do destroy_render_pipeline(&data.skinned)
	if data.game_constants != nil do data.game_constants->Release()
	for text in data.reflection_texts do delete(text)
	delete(data.game_shadow)
	delete(data.name)
	free(data)
}

/*Frees a shader. Anything still queued with it must not be drawn afterwards*/
destroy_shader :: proc(shader: Shader) {
	if shader.data == nil do return
	if mbi.shader_state.current.data == shader.data do mbi.shader_state.current = {}
	free_shader_data((^Shader_Data)(shader.data))
}

/*
	The game shader that draws this item, or nil when the built-in does: no shader set, or the shader has no pipeline for
	this kind of mesh
*/
@(private)
choose_shader :: proc(item: Render_Item) -> ^Shader_Data {
	data := (^Shader_Data)(item.shader.data)
	if data == nil do return nil
	if item.mesh.skinned do return data if data.has_skinned else nil
	if data.has_plain == false do return nil
	if data.reads_normal && item.mesh.lit == false do return nil
	return data
}

/*Copies a game shader's uniforms to the GPU if one was set since the last draw*/
@(private)
upload_shader_constants :: proc(data: ^Shader_Data) {
	if data.game_dirty == false || data.game_constants == nil do return
	update_buffer(data.game_constants, raw_data(data.game_shadow), len(data.game_shadow))
	data.game_dirty = false
}

/*
	Sets a uniform the shader declares with `@(uniform)`, by its name. The value stays until it is set again.
	`shader` is the game shader whose uniform it is; left out, it is mesh.mbs's, the built-in's. `value` has the
	uniform's type: 0.5 for an f32, a [3]f32 for a [3]f32, a matrix[4, 4]f32 for a matrix, and a slice or array with
	every element for an array uniform. A struct's field is named as in the shader: "key_light.strength"
*/
set_shader_value :: proc(name: string, value: any, shader := Shader{}) {
	if shader.data == nil {
		ok, message := write_shader_value(&mbi.pipeline.reflection, mbi.game_shadow, name, value)
		ensure(ok, message)
		mbi.game_dirty = true
		return
	}

	data := (^Shader_Data)(shader.data)
	reflection := &data.plain.reflection if data.has_plain else &data.skinned.reflection
	ok, message := write_shader_value(reflection, data.game_shadow, name, value)
	ensure(ok, fmt.tprintf("shader `%s`: %s", data.name, message))
	data.game_dirty = true
}
