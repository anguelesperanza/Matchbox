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
	pipeline are in render_vita_freestanding_arm32.odin, textures in texture_vita_freestanding_arm32.odin.
*/

import "base:runtime"

import "vito/gfx"
import "vito/sce"
import "vito/vito"

when VITA {

	Backend_State :: struct {
		input:vito.Input, // buttons, sticks and touch panels for this frame, from vito.input_update
		touch:Touch_State, // the front panel's first finger, as the mouse (input_vita_freestanding_arm32.odin)
		// The three shaders, their programs and uniforms (render_vita_freestanding_arm32.odin): `pipeline` draws
		// everything unlit; while lighting is on, `lit_pipeline` draws lit meshes per pixel and `vertex_lit_pipeline`
		// per vertex, as each part's material says
		pipeline:Render_Pipeline,
		lit_pipeline:Render_Pipeline,
		vertex_lit_pipeline:Render_Pipeline,
		// GXM has no uniforms that outlive a draw: each draw gets a fresh default uniform buffer, so
		// the camera's matrix and lights are kept here and written into every one
		camera_view_projection:matrix[4, 4]f32,
		camera_lights:Lights_Block,
		print_log:Print_Log, // the file print writes to (util_vita_freestanding_arm32.odin)
	}

	/*The backend's fixed values, which matchbox_info.odin puts in `mbi` where it is declared*/
	BACKEND_DEFAULTS :: Backend_State {
		print_log = {path = "ux0:data/matchbox.log"},
	}

	/*The GXM texture, on the heap so every copy of a Texture names the same one (texture_vita_freestanding_arm32.odin)*/
	Backend_Texture :: struct {
		texture:^gfx.Texture,
	}

	/*
		Geometry in GPU-mapped memory: vertices, then indices, in one gfx.alloc block.
		`create_mesh` makes one, `destroy_mesh` frees it
	*/
	Mesh :: struct {
		vertices:rawptr,
		indices:rawptr, // inside the same block, just after the vertices
		index_count:u32,
		uid:sce.UID, // the block, for gfx.free
		lit:bool, // made by create_lit_mesh: Lit_Vertex, 48 bytes a vertex, with normals
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

	/*{width, height, 0, 0} in pixels: 960 x 544, and no second screen*/
	get_window_size :: proc() -> [4]i32 {
		return mbi.window_size
	}

	/*
		Where the finger on the front panel is, in `camera`'s world units, or where it last was.
		The panel covers the whole 960 x 544 screen, so this is the PC's sum with the touch in
		place of the mouse
	*/
	calculate_mouse_world_position :: proc(camera:Camera) -> [2]f32 {
		size := get_window_size()
		return calculate_screen_to_world_2d(camera, mbi.touch.position, {f32(size[0]), f32(size[1])})
	}
}
