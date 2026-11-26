#+build freestanding arm32

package matchbox

/*
	Backend (3DS)
	=============
	What only the 3DS has: citro3d's render targets, the circle pad and C-stick, the HID
	button masks. Embedded in Matchbox_Info with `using`, like the PC's. See
	matchbox_info.odin for the contract this file fills in.

	Everything is inside `when !VITA` because the Vita is freestanding_arm32 too, so this
	file's suffix alone would compile it into the Vita build as well (target.odin). The
	imports stay outside: Odin does not allow `import` inside `when`, and an import whose
	procedures are never called adds nothing to the build.

	Meshes and the pipeline that draws them are in render_3ds_freestanding_arm32.odin, and
	textures in texture_3ds_freestanding_arm32.odin.
*/

import "base:runtime"
import "core:fmt"

import "o3dx/c3d"
import "o3dx/ctru"
import "o3dx/o3dx"

when !VITA {

	Backend_State :: struct {
		// citro3d render targets, as `rawptr` because that is how o3dx's c3d binds them
		top_screen:rawptr,
		bottom_screen:rawptr,
		drawing_bottom_screen:bool, // between bottom_screen_start and _end: the target camera_start sizes its view by

		// HID button masks for this frame (hidKeysDown / Held / Up)
		gamepad_pressed:u32,
		gamepad_held:u32,
		gamepad_released:u32,

		// The circle pad and C-stick, scaled to -1..1 by the largest value each reaches
		left_thumbstick_axis:[2]f32,
		right_thumbstick_axis:[2]f32,
		left_thumbstick_max:f32,
		right_thumbstick_max:f32,

		// Where the stylus is, in bottom screen pixels (top left, y down). Kept after the stylus
		// lifts: hidTouchRead reports 0, 0 by then, and the frame it lifted still needs the point
		// it lifted from
		touch_position:[2]f32,

		// The three shaders, their uniforms and TexEnv plans (render_3ds_freestanding_arm32.odin): `pipeline` draws
		// everything unlit; while lighting is on, `lit_pipeline` draws lit meshes per pixel with the lighting unit,
		// and `vertex_lit_pipeline` per vertex, as each part's material says
		pipeline:Render_Pipeline,
		lit_pipeline:Render_Pipeline,
		vertex_lit_pipeline:Render_Pipeline,
		// Skinned meshes (G6): `skinned_pipeline` unlit, `skinned_lit_pipeline` per pixel. A skinned part that asks for per-vertex
		// lighting is drawn per pixel (no per-vertex skinned shader), as on every target
		skinned_pipeline:Render_Pipeline,
		skinned_lit_pipeline:Render_Pipeline,
		bound_pipeline:^Render_Pipeline, // the one citro3d has now, so a draw only switches when it changes
		// The camera being drawn, set again after each switch: the programs' registers are shared
		camera_view_projection:matrix[4, 4]f32,
		camera_lights:Lights_Block, // this camera's lights, which the per-vertex program reads from its registers
		lighting_unit:Lighting_Unit, // the fragment lighting unit's state, for lit_pipeline

		print_log:Print_Log, // what `print` wrote, drawn on the bottom screen (bottom_screen_3ds_freestanding_arm32.odin)

		// Fixed values the 3DS backend works with
		display_settings:Display_Settings,
		print_log_settings:Print_Log_Settings,
		skin_settings:Skin_Settings,
	}

	/*
		The 3DS's half of `mbi`'s initial values. Same reason as the PC's BACKEND_DEFAULTS:
		a global's initial value must be known at compile time
	*/
	BACKEND_DEFAULTS :: Backend_State {
		// 96 vertex float registers hold the palette (3 a joint) beside the matrices, the lights' and the constants:
		// 22 joints leave 86 of 96 used (mesh_skinned_lit). **Revisit later:** a target's number, not the engine's
		skin_settings = {joint_limit = 22, layer_limit = 2},
		display_settings = {transfer_flags = 0x1000},
		print_log_settings = {
			pixel_size = 12,
			margin = 4,
			backdrop = {0, 0, 0, 0.6},
			color = {1, 1, 1, 1},
		},

		// The largest values the New 3DS LL used for testing reports. Not a setting: they
		// scale what the hardware gives, so they are right from the start
		left_thumbstick_max = 156,
		right_thumbstick_max = 146,
	}

	/*
		What only a 3DS texture has: citro3d's texture, on the heap so the copies a sprite and its
		clips make all point at one (its address must not move while the GPU reads it). nil
		for the zero Texture, which the renderer draws with its white texture
	*/
	Backend_Texture :: struct {
		texture:^c3d.C3D_Tex,
	}

	/*What only a 3DS render target has besides its texture: citro3d's target, drawn to through C3D_FrameDrawOn*/
	Backend_Render_Target :: struct {
		citro_target:rawptr,
	}

	/*
		Sets up the Odin runtime on the 3DS and returns the context the game runs in. Called
		from matchbox/handheld_entry, before the game's `main`: Matchbox can't run it
		itself, because `context` belongs to the caller and nothing calls Odin before odin_main.
		Failed asserts and panics go to report_crash, so their message is shown on the console
	*/
	start_runtime :: proc "contextless" () -> runtime.Context {
		context = o3dx.init()
		context.assertion_failure_proc = report_crash
		return context
	}

	/*
		Shows a failed assert's or a panic's message on the bottom screen, as ctru's console, and
		waits for START, then hands over to o3dx's handler, which appends it to the SD card log
		and traps (Luma3DS's exception screen on hardware). The console comes back for this even
		when the game had the bottom screen: on a console with no log window, the screen is the
		only place the message can be read.

		Before init there is no screen yet, and o3dx's handler alone reports it. Bounds-check and
		nil-dereference failures never come here: Odin's runtime traps on those by itself
	*/
	@(private)
	report_crash :: proc(prefix, message:string, location:runtime.Source_Code_Location) -> ! {
		if mbi.bottom_screen != nil {
			if mbi.bottom_screen_layout != .CONSOLE {
				c3d.C3D_RenderTargetSetOutput(nil, ctru.GFX_BOTTOM, ctru.GFX_LEFT, 0)
				ctru.consoleInit(ctru.GFX_BOTTOM, nil)
			}
			o3dx.print_to_console = true

			buffer:[512]u8
			line := fmt.bprintf(buffer[:], "%s(%d:%d) %s: %s%s%s", location.file_path, location.line, location.column,
				location.procedure, prefix, ": " if message != "" else "", message)
			o3dx.write("\n*** Crash ***\n\n")
			o3dx.write(line)
			o3dx.write("\n\nPress START to quit.\n")
			ctru.gfxFlushBuffers()
			ctru.gfxSwapBuffers()

			for ctru.aptMainLoop() {
				ctru.hidScanInput()
				if ctru.hidKeysDown() & ctru.KEY_START != 0 do break
				ctru.svcSleepThread(16_000_000) // a frame; nothing changes on screen while waiting
			}

			// Already on the screen and in the debug log: o3dx's handler only adds the SD card copy
			o3dx.print_to_console = false
			o3dx.print_to_debug = false
		}
		o3dx.assertion_failure_proc(prefix, message, location)
	}

	/*Undoes start_runtime. Called after `main` returns*/
	stop_runtime :: proc "contextless" () {
		o3dx.shutdown()
	}

	/*
		{top width, top height, bottom width, bottom height} in pixels, as the screens are held:
		400 x 240 on top, 320 x 240 below. citro3d's targets are 240 x 400 because the panels are
		mounted on their side; that is the backend's business, and the camera wants the size the
		player sees
	*/
	get_window_size :: proc() -> [4]i32 {
		return mbi.window_size
	}

	/*
		Always {0, 0}: the stylus is the 3DS's mouse, and it only reaches the bottom screen, never
		a camera on the top one. calculate_mouse_bottom_screen_position is where it is
	*/
	calculate_mouse_world_position :: proc(camera:Camera) -> [2]f32 {
		return {}
	}
}
