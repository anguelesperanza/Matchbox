#+build freestanding arm32

package matchbox

/*
	Game shaders (3DS)
	==================
	The same model as PC (shader.odin, shader_windows.odin): `load_shader("toon")` reads `toon.3ds.shbin`, `.3ds.tev` and
	`.3ds.refl` (all written by tools/mbsc and picasso, copied into romfs/shaders by 3ds_build.bat), and optionally the
	`toon_skinned.*` three beside them. The files are read at run time, not `#load`ed, so a game that names no shader carries
	none of them. A shader is one or two Render_Pipelines, built by the same code as the built-ins
	(create_game_render_pipeline in render_3ds_freestanding_arm32.odin), and choose_game_pipeline picks between them per draw.

	Inside `when !VITA` for the reason in backend_3ds_freestanding_arm32.odin
*/

import "core:fmt"
import "core:strings"

import "o3dx/c3d"

when !VITA {

	/*
		What a loaded game shader holds (3DS). `Shader.data` points at one. `plain` draws Vertex and Lit_Vertex meshes
		(name.3ds.*), `skinned` draws Skinned_Vertex ones (name_skinned.3ds.*). Each pipeline keeps its own copy of the game's
		uniforms, since each is a separate vertex program; set_shader_value writes both, which is why the two must declare the
		same ones. Heap-allocated: the render queue and the bound pipeline hold pointers to the pipelines inside
	*/
	@(private)
	Shader_Data :: struct {
		name:        string,
		plain:       Render_Pipeline,
		has_plain:   bool,
		skinned:     Render_Pipeline,
		has_skinned: bool,
	}

	/*
		Loads a game's shader by name from romfs/shaders: `<name>.3ds.shbin` with its `.3ds.tev` and `.3ds.refl`, and
		optionally `<name>_skinned.*` for skinned models. Call it between frames, as with `load_model`: making GPU objects
		in the middle of one is fatal on a real console. Stops with a message if the files are not there
	*/
	load_shader :: proc(name: string) -> Shader {
		shader, ok := load_shader_checked(name)
		if ok == false do panic("Failed to load shader")
		return shader
	}

	/*
		The same as load_shader, but a file that is not there is `ok` = false, with the reason printed, instead of a stop.
		A shader the engine cannot honour (a TexEnv plan or reflection it does not support, a uniform it does not know)
		still stops with a message naming it: that is a fault in the shader, not in what the game asked for
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
		if is_shader_file_present(skinned_name, ".3ds.shbin") {
			if load_shader_variant(data, skinned_name, true) == false {
				free_shader_data(data)
				return {}, false
			}
			if has_same_game_uniforms(&data.plain, &data.skinned) == false {
				print("Shader", name, "and its _skinned variant declare different game uniforms; they have to match")
				free_shader_data(data)
				return {}, false
			}
		}
		return Shader{data = data}, true
	}

	/*
		Both variants are written by set_shader_value, so they must hold the same uniforms under the same names and types.
		PC compares the block sizes; here a uniform's register is the .shbin's own, so what has to agree is the list
	*/
	@(private = "file")
	has_same_game_uniforms :: proc(a, b: ^Render_Pipeline) -> bool {
		if len(a.game.entries) != len(b.game.entries) do return false
		for entry, index in a.game.entries {
			other := b.game.entries[index]
			if entry.name != other.name || entry.type != other.type do return false
		}
		return true
	}

	@(private = "file")
	is_shader_file_present :: proc(name, extension: string) -> bool {
		path_buffer: [256]u8
		path, path_ok := build_path(path_buffer[:], mbi.asset_path, "shaders/", name, extension)
		return path_ok && file_exists(path)
	}

	/*Reads one variant's three files and makes its pipeline in `data`. A missing file is false; one the engine cannot honour stops*/
	@(private = "file")
	load_shader_variant :: proc(data: ^Shader_Data, name: string, skinned: bool) -> bool {
		path_buffer: [256]u8
		path, path_ok := build_path(path_buffer[:], mbi.asset_path, "shaders/", name, ".3ds.shbin")
		if path_ok == false {
			print("Shader name is too long:", name)
			return false
		}
		shader_words := read_file_words(path)
		if len(shader_words) == 0 {
			print("No such shader file:", name)
			return false
		}

		tev_path, tev_ok := build_path(path_buffer[:], mbi.asset_path, "shaders/", name, ".3ds.tev")
		tev_bytes: []u8
		if tev_ok do tev_bytes = read_file_bytes(tev_path)
		if len(tev_bytes) == 0 {
			print("No TexEnv plan for shader (build it with mbsc --emit-pica):", name)
			delete(shader_words)
			return false
		}
		defer delete(tev_bytes)

		reflection_path, reflection_ok := build_path(path_buffer[:], mbi.asset_path, "shaders/", name, ".3ds.refl")
		reflection_bytes: []u8
		if reflection_ok do reflection_bytes = read_file_bytes(reflection_path)
		if len(reflection_bytes) == 0 {
			print("No reflection file for shader (build it with mbsc --emit-reflection):", name)
			delete(shader_words)
			return false
		}
		defer delete(reflection_bytes)

		// Takes the words (and frees them if it fails); copies the two texts, so they are freed here either way
		pipeline := &data.skinned if skinned else &data.plain
		message := create_game_render_pipeline(pipeline, shader_words, string(tev_bytes), string(reflection_bytes), skinned)
		if message != "" {
			print("Shader", name, ":", message)
			panic("A game shader could not be loaded: the engine cannot honour what its files ask for")
		}
		if skinned {
			data.has_skinned = true
		} else {
			data.has_plain = true
		}
		return true
	}

	@(private = "file")
	free_shader_data :: proc(data: ^Shader_Data) {
		if data.has_plain do destroy_game_render_pipeline(&data.plain)
		if data.has_skinned do destroy_game_render_pipeline(&data.skinned)
		delete(data.name)
		free(data)
	}

	/*
		Frees a shader. Anything still queued with it must not be drawn afterwards. Safe while one of its pipelines is the
		one bound: the bound pointer is cleared, so the next draw binds afresh instead of trusting a program that is gone
	*/
	destroy_shader :: proc(shader: Shader) {
		if shader.data == nil do return
		// The GPU may still be drawing with this program (the Vita waits with gfx.finish)
		c3d.FrameSync()
		if mbi.shader_state.current.data == shader.data do mbi.shader_state.current = {}
		free_shader_data((^Shader_Data)(shader.data))
	}

	/*
		The game pipeline that draws this item, or nil when a built-in does: no shader set, or the shader has no variant
		for this kind of mesh (the rule is shared with PC, choose_shader_variant)
	*/
	@(private)
	choose_game_pipeline :: proc(item: Render_Item) -> ^Render_Pipeline {
		data := (^Shader_Data)(item.shader.data)
		if data == nil do return nil
		facts := Shader_Facts{has_plain = data.has_plain, has_skinned = data.has_skinned, reads_normal = data.plain.reads_normal}
		pipeline: ^Render_Pipeline
		switch choose_shader_variant(facts, item.mesh.skinned, item.mesh.lit) {
		case .NONE:
			return nil
		case .PLAIN:
			pipeline = &data.plain
		case .SKINNED:
			pipeline = &data.skinned
		}
		// The lighting unit's lights and material are only set up while lighting is enabled (camera_end), so a shader that
		// reads the unit would draw with whatever it was last given. As on PC, where a shader that cannot draw a mesh gives
		// way to the built-in, this one does too: the built-in draws it unlit, which is what disabled lighting means
		if pipeline.lighting == .PER_PIXEL && mbi.lighting.settings.enabled == false do return nil
		return pipeline
	}

	/*
		Sets a uniform the shader declares with `@(uniform)`, by its name. The value stays until it is set again.
		`shader` is the game shader whose uniform it is; the built-ins have none to set on the 3DS. `value` has the
		uniform's type: 0.5 for an f32, a [3]f32 for a [3]f32, a matrix[4, 4]f32 for a matrix. Arrays and structs are not
		supported yet: each element or field would be its own uniform
	*/
	set_shader_value :: proc(name: string, value: any, shader := Shader{}) {
		ensure(shader.data != nil, "On the 3DS the built-in shaders have no uniforms to set: pass the game shader")
		data := (^Shader_Data)(shader.data)
		// Plain first: a name it lacks is the game's mistake and is reported with the shader named, as on PC
		ok, message := set_pica_game_value(&data.plain.game, name, value)
		ensure(ok, fmt.tprintf("shader `%s`: %s", data.name, message))
		if data.has_skinned {
			// Identical lists were checked at load, so this cannot fail where the plain one did not
			skinned_ok, skinned_message := set_pica_game_value(&data.skinned.game, name, value)
			ensure(skinned_ok, fmt.tprintf("shader `%s` (skinned): %s", data.name, skinned_message))
		}
	}
}
