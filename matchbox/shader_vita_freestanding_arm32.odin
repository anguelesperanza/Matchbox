#+build freestanding arm32

package matchbox

/*
	Game shaders (Vita)
	===================
	`load_shader("hologram")` reads `<name>_v.gxp`, `<name>_f.gxp` and `<name>.vita.refl` from app0:/assets/shaders/ at run time
	(vita_build.bat packs a game's `assets\vita\shaders` there; build_shaders.bat in the shader's project writes them with
	mbsc and psp2cgc), and, if they are there, the same three for `<name>_skinned`. They are read at run time rather than
	`#load`ed so a game that names no shader carries none of them in its binary, as on PC.

	The shader is up to two pipelines, as on PC (shader_windows.odin): `plain` draws Vertex and Lit_Vertex meshes, `skinned`
	draws Skinned_Vertex ones. Which of them draws an item is `choose_shader_variant` (shader_pica.odin), shared with PC and the
	3DS. The game's uniforms are one CPU copy (shader_vita.odin, Vita_Game_Uniforms) that `set_shader_value` writes, and that
	every draw writes into the draw's own uniform buffers (render_vita_freestanding_arm32.odin, render_game_item).

	Inside `when VITA` for the reason in backend_vita_freestanding_arm32.odin
*/

import "core:fmt"
import "core:strings"

import "vito/gfx"

when VITA {

	/*What a loaded game shader holds (Vita). `Shader.data` points at one*/
	@(private)
	Shader_Data :: struct {
		name:            string,
		plain:           Render_Pipeline,
		has_plain:       bool,
		reads_normal:    bool, // the plain pipeline needs a Lit_Vertex mesh; a plain Vertex one has no normal to give it
		skinned:         Render_Pipeline,
		has_skinned:     bool,
		reflection_text: string, // the plain variant's: `game`'s entry names point into it, so it lives as long as the shader
		game:            Vita_Game_Uniforms, // shared by both variants: the skinned one may declare fewer, never others
	}

	/*
		Loads a game's shader by name from app0:/assets/shaders/. Reads three files, so call it between frames, as with
		`load_model`. Stops with a message if the files are not there or the engine cannot honour what is in them
	*/
	load_shader :: proc(name: string) -> Shader {
		shader, ok := load_shader_checked(name)
		if ok == false do panic("Failed to load shader")
		return shader
	}

	/*
		The same as load_shader, but a file that is not there or a reflection that cannot be read is `ok` = false, with the
		reason printed, instead of a stop. A .gxp the GPU refuses, or one that reads a vertex input the engine's meshes do not
		have, still stops: that is a mistake in the shader, not in what the game asked for
	*/
	load_shader_checked :: proc(name: string) -> (shader: Shader, ok: bool) {
		data := new(Shader_Data)
		data.name = strings.clone(name)

		if _, variant_ok := load_shader_variant(data, name, false); variant_ok == false {
			free_shader_data(data)
			return {}, false
		}
		// Optional: a shader that leaves it out draws skinned meshes with the built-in
		skinned_name := strings.concatenate({name, "_skinned"}, context.temp_allocator)
		if present, variant_ok := load_shader_variant(data, skinned_name, true); present && variant_ok == false {
			free_shader_data(data)
			return {}, false
		}
		print("shader loaded:", name, "; skinned variant", data.has_skinned, "; reads normal", data.reads_normal)
		return Shader{data = data}, true
	}

	/*
		Reads one variant's three files and makes its pipeline in `data`. `present` is false only for an optional variant with no
		reflection file at all, which is not a failure
	*/
	@(private = "file")
	load_shader_variant :: proc(data: ^Shader_Data, name: string, skinned: bool) -> (present: bool, ok: bool) {
		reflection_bytes := read_shader_file(name, ".vita.refl", report_missing = !skinned)
		if reflection_bytes == nil do return !skinned, false
		reflection_text := string(reflection_bytes)
		// The plain variant's text is kept for the shader's life; the skinned one's is only needed while its pipeline is made
		if skinned == false do data.reflection_text = reflection_text
		defer if skinned do delete(reflection_bytes)

		reflection, parsed, message := parse_vita_reflection(reflection_text)
		if parsed == false {
			print("Shader", name, ":", message)
			return true, false
		}
		defer destroy_vita_reflection(&reflection)

		vertex_gxp := read_shader_file(name, "_v.gxp", report_missing = true)
		if vertex_gxp == nil do return true, false
		defer delete(vertex_gxp)
		fragment_gxp := read_shader_file(name, "_f.gxp", report_missing = true)
		if fragment_gxp == nil do return true, false
		defer delete(fragment_gxp)

		if skinned {
			// Every game uniform the skinned shader declares must be one the plain shader has, of the same type: the one
			// copy that set_shader_value writes is the plain one's
			own := create_vita_game_uniforms(&reflection)
			defer destroy_vita_game_uniforms(&own)
			for entry in own.entries {
				if has_game_entry(&data.game, entry) == false {
					print("Shader", name, "declares the game uniform", entry.name, "which", data.name, "does not, or declares it as another type")
					return true, false
				}
			}
			data.skinned = create_game_render_pipeline(vertex_gxp, fragment_gxp, &reflection, data.game.entries[:], true)
			data.has_skinned = true
		} else {
			data.game = create_vita_game_uniforms(&reflection)
			data.reads_normal = vita_reads_normal(&reflection)
			data.plain = create_game_render_pipeline(vertex_gxp, fragment_gxp, &reflection, data.game.entries[:], false)
			data.has_plain = true
		}
		return true, true
	}

	/*Whether `game` has a uniform of this name, type and count*/
	@(private = "file")
	has_game_entry :: proc(game: ^Vita_Game_Uniforms, wanted: Vita_Game_Entry) -> bool {
		for entry in game.entries {
			if entry.name == wanted.name do return entry.type == wanted.type && entry.count == wanted.count
		}
		return false
	}

	/*
		Reads `assets/shaders/<name><suffix>` from the .vpk. The caller deletes what it gets. nil when the file is not there; the
		reason is printed unless `report_missing` is off (an optional variant's absence is not worth a line)
	*/
	@(private = "file")
	read_shader_file :: proc(name: string, suffix: string, report_missing: bool) -> []u8 {
		buffer: [256]u8
		path, path_ok := build_path(buffer[:], mbi.asset_path, "shaders/", name, suffix)
		if path_ok == false {
			if report_missing do print("Shader file name too long:", name)
			return nil
		}
		bytes := read_file_bytes(path)
		if bytes == nil && report_missing do print("No such shader file:", string(path), "(build it with the project's build_shaders.bat)")
		return bytes
	}

	@(private = "file")
	free_shader_data :: proc(data: ^Shader_Data) {
		if data.has_plain do destroy_game_render_pipeline(&data.plain)
		if data.has_skinned do destroy_game_render_pipeline(&data.skinned)
		destroy_vita_game_uniforms(&data.game)
		delete(data.reflection_text)
		delete(data.name)
		free(data)
	}

	/*
		Frees a shader. Anything still queued with it must not be drawn afterwards. Waits for the GPU first, as destroy_mesh does:
		the programs may be in the frame that was just drawn
	*/
	destroy_shader :: proc(shader: Shader) {
		if shader.data == nil do return
		if mbi.shader_state.current.data == shader.data do mbi.shader_state.current = {}
		gfx.finish()
		free_shader_data((^Shader_Data)(shader.data))
	}

	/*
		Sets a uniform the shader declares with `@(uniform)`, by its name. The value stays until it is set again. `value` has the
		uniform's type: 0.5 for an f32, a [3]f32 for a [3]f32, a matrix[4, 4]f32 for a matrix, and a slice or array with every
		element for an array uniform. A struct's field is named as in the shader: "key_light.strength". `shader` is the game
		shader whose uniform it is; the built-in has none
	*/
	set_shader_value :: proc(name: string, value: any, shader := Shader{}) {
		if shader.data == nil {
			panic(fmt.tprintf("`%s`: the built-in shader has no game uniforms; give set_shader_value the shader the uniform belongs to", name))
		}
		data := (^Shader_Data)(shader.data)
		ok, message := set_vita_game_value(&data.game, name, value)
		ensure(ok, fmt.tprintf("shader `%s`: %s", data.name, message))
	}

	/*
		The game shader and pipeline that draw this item, or nil when the built-in does: no shader set, the shader has no pipeline
		for this kind of mesh (choose_shader_variant), or the shader reads the lights while lighting is off.

		That last one falls back to the built-in, as the built-in's own lit meshes do when lighting is off (they are drawn unlit
		rather than shaded). The lights block is filled at camera_end only while lighting is on, so a shader that reads it would
		run on zeros and draw black, and "lighting is off" is the game saying it wants no shading
	*/
	@(private)
	choose_game_shader :: proc(item: Render_Item) -> (data: ^Shader_Data, pipeline: ^Render_Pipeline) {
		data = (^Shader_Data)(item.shader.data)
		if data == nil do return nil, nil
		facts := Shader_Facts{has_plain = data.has_plain, has_skinned = data.has_skinned, reads_normal = data.reads_normal}
		switch choose_shader_variant(facts, item.mesh.skinned, item.mesh.lit) {
		case .NONE:    return nil, nil
		case .PLAIN:   pipeline = &data.plain
		case .SKINNED: pipeline = &data.skinned
		}
		if pipeline.game.reads_lights && mbi.lighting.settings.enabled == false do return nil, nil
		return data, pipeline
	}
}
