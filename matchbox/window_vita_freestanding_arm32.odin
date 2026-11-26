#+build freestanding arm32

package matchbox

/*
	Window -- Vita
	==============
	Starts vito's input and gfx, and owns the frame clock.

	Inside `when VITA` for the reason in backend_vita_freestanding_arm32.odin
*/

import "base:runtime"

import "vito/gfx"
import "vito/sce"
import "vito/vito"

when VITA {

	/*
		Initialize the core of Matchbox for the target platform. `width` and `height` are the
		PC window's: the Vita's screen is always 960 x 544
	*/
	init :: proc(title:string, width:i32, height:i32) {
		mbi.is_running = true
		mbi.asset_path = "app0:/assets/" // vita_build.bat packs assets\ there
		mbi.screen_height = mbi.screen_settings.default_height // the HUD's height until set_screen_height

		// Emptied before anything can fail, and vito's crash report pointed at the same file, so a
		// crash's message lands after the prints that led to it, in this run's log
		start_print_log(&mbi.print_log)
		vito.panic_log_path = mbi.print_log.path

		// The front panel is the mouse (input_vita_freestanding_arm32.odin). The back panel and
		// motion stay off: Matchbox has no API for them, and sampling them costs every frame
		vito.input_init({.Front_Touch})

		// A failed gfx.init leaves nothing to draw with, and the screen is not up to show why,
		// so the step and the error code go to the log before stopping
		if !gfx.init() {
			print("gfx.init failed at", gfx.init_step, "error", gfx.init_error)
			panic("gfx.init failed")
		}

		mbi.window_size = {gfx.WIDTH, gfx.HEIGHT, 0, 0}

		create_render_pipeline()

		// The meshes every sprite and shape is drawn with, as on PC and 3DS
		sprite_vertices, sprite_indices := create_quad_geometry()
		mbi.sprite_mesh = create_mesh(sprite_vertices, sprite_indices)
		delete(sprite_vertices)
		delete(sprite_indices)

		triangle_vertices, triangle_indices := create_triangle_geometry()
		mbi.triangle_mesh = create_mesh(triangle_vertices, triangle_indices)
		delete(triangle_vertices)
		delete(triangle_indices)

		circle_vertices, circle_indices := create_circle_geometry()
		mbi.circle_mesh = create_mesh(circle_vertices, circle_indices)
		delete(circle_vertices)
		delete(circle_indices)

		start_clock(&mbi.clock, vito.time_us(), 1_000_000) // microseconds

		// Odin's random generator seeds itself from the system's entropy the first time it is
		// used, and freestanding has none: the runtime traps ("no runtime entropy source"), so a
		// game's first rand call stopped it dead. Seeded here instead, from the microseconds since
		// the process started, which vary with how long loading took: weaker than the 3DS's date,
		// since the Vita's clock is not bound yet (sceRtcGetCurrentTick). Not cryptographic; a game
		// that wants that, or a repeatable run, calls rand.reset itself after init
		runtime.random_generator_reset_u64(context.random_generator, vito.time_us())
	}

	/*Returns true while the game runs. Only stop_running ends it on the Vita: the PS button suspends, it doesn't quit*/
	is_running :: proc() -> bool {
		return mbi.is_running
	}

	/*Stops running the application*/
	stop_running :: proc() {
		mbi.is_running = false
	}

	/*
		Cleans up resources created by Matchbox. The GPU and the display queue have to be idle
		before anything they read is freed, so both are waited on first
	*/
	cleanup :: proc() {
		gfx.finish()
		sce.sceGxmDisplayQueueFinish()
		destroy_mesh(mbi.triangle_mesh)
		destroy_mesh(mbi.circle_mesh)
		destroy_mesh(mbi.sprite_mesh)
		destroy_render_pipeline()
		gfx.shutdown()
		vito.input_shutdown()
	}
}
