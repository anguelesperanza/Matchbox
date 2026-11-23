#+build freestanding arm32

package matchbox

/*
	Backend (Vita)
	==============
	What only the Vita has: vito's input state and the frame clock. Embedded in Matchbox_Info
	with `using`, like the PC's and the 3DS's. See matchbox_info.odin for the contract this
	file fills in.

	Everything is inside `when VITA`: the 3DS is freestanding_arm32 too, so the file suffix
	alone would compile it into the 3DS build as well (target.odin). The imports stay outside,
	because Odin does not allow `import` inside `when`, and an import whose procedures are
	never called adds nothing to the build.

	The GPU's context and display queue are not here: vito's gfx package keeps its own, and the
	backend calls it. The shader and its programs are (mbi.pipeline), and meshes and the
	pipeline are in render_vita_freestanding_arm32.odin. Textures are empty until V5.
*/

import "base:runtime"

import "vito/sce"
import "vito/vito"

when VITA {

	Backend_State :: struct {
		input:vito.Input, // buttons and sticks for this frame, from vito.input_update
		pipeline:Render_Pipeline, // the shader, its programs and uniforms (render_vita_freestanding_arm32.odin)
	}

	/*Nothing to set yet. Declared so matchbox_info.odin's `backend = BACKEND_DEFAULTS` works on every target*/
	BACKEND_DEFAULTS :: Backend_State {}

	/*Empty until Phase V uploads textures with GXM*/
	Backend_Texture :: struct {}

	/*
		Geometry in GPU-mapped memory: vertices, then indices, in one gfx.alloc block.
		`create_mesh` makes one, `destroy_mesh` frees it
	*/
	Mesh :: struct {
		vertices:rawptr,
		indices:rawptr, // inside the same block, just after the vertices
		index_count:u32,
		uid:sce.UID, // the block, for gfx.free
	}

	/*
		Sets up the Odin runtime on the Vita and returns the context the game runs in. Called
		from matchbox/handheld_entry, before the game's `main`: Matchbox can't run it
		itself, because `context` belongs to the caller and nothing calls Odin before odin_main
	*/
	start_runtime :: proc "contextless" () -> runtime.Context {
		return vito.init()
	}

	/*Undoes start_runtime. Called after `main` returns*/
	stop_runtime :: proc "contextless" () {
		vito.shutdown()
	}

	/*
		Not loaded yet: returns a Texture of the right size once Phase V uploads it. Until then
		an empty Texture, so a game that loads images still runs and draws nothing
	*/
	load_texture :: proc(filename:string, filter:Filter_Mode = .LINEAR) -> (texture:Texture) {
		texture.filter = filter
		return
	}

	/*
		A texture from RGBA8 pixels already in memory: what create_font uploads its atlas with.
		Records the size and uploads nothing until Phase V, so the sizes a game reads are right
	*/
	create_texture_from_pixels :: proc(pixels:rawptr, width, height:i32, filter:Filter_Mode = .LINEAR) -> (texture:Texture) {
		texture.width = width
		texture.height = height
		texture.filter = filter
		return
	}

	/*Nothing to free until load_texture uploads something*/
	destroy_texture :: proc(texture:Texture) {
	}

	/*{width, height, 0, 0} in pixels: 960 x 544, and no second screen*/
	get_window_size :: proc() -> [4]i32 {
		return mbi.window_size
	}

	/*The Vita has no mouse. The touch panels get their own procedures when input is ported*/
	calculate_mouse_world_position :: proc(camera:Camera) -> [2]f32 {
		return {}
	}
}
