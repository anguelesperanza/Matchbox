#+build freestanding arm32

package matchbox

/*
	Window -- Vita
	==============
	Starts vito's input and gfx, and owns the frame clock.

	Inside `when VITA` for the reason in backend_vita_freestanding_arm32.odin
*/

import "vito/gfx"
import "vito/sce"
import "vito/vito"

when VITA {

	Timestamp :: struct {
		last_time:u64, // microseconds since the program started
	}

	/*
		Initialize the core of Matchbox for the target platform. `width` and `height` are the
		PC window's: the Vita's screen is always 960 x 544
	*/
	init :: proc(title:string, width:i32, height:i32) {
		mbi.is_running = true
		mbi.asset_path = "app0:/assets/" // vita_build.bat packs assets\ there
		mbi.screen_height = mbi.screen_settings.default_height // the HUD's height until set_screen_height

		vito.input_init({}) // the touch panels and motion are off until input is ported

		// A failed gfx.init leaves nothing to draw with, and the screen is not up to show why,
		// so the step and the error code go to the log before stopping
		if !gfx.init() {
			print("gfx.init failed at", gfx.init_step, "error", gfx.init_error)
			panic("gfx.init failed")
		}

		mbi.window_size = {gfx.WIDTH, gfx.HEIGHT, 0, 0}
		mbi.timestamp.last_time = vito.time_us()
	}

	/*Returns true while the game runs. Only stop_running ends it on the Vita: the PS button suspends, it doesn't quit*/
	is_running :: proc() -> bool {
		return mbi.is_running
	}

	/*Stops running the application*/
	stop_running :: proc() {
		mbi.is_running = false
	}

	/*Returns the delta time value, in seconds*/
	get_delta_time :: proc() -> (delta_time:f32) {
		now := vito.time_us()
		delta_time = f32(f64(now - mbi.timestamp.last_time) / 1_000_000.0)
		mbi.timestamp.last_time = now
		return delta_time
	}

	/*
		Cleans up resources created by Matchbox. The GPU and the display queue have to be idle
		before gfx frees the memory they read, so both are waited on first
	*/
	cleanup :: proc() {
		gfx.finish()
		sce.sceGxmDisplayQueueFinish()
		gfx.shutdown()
		vito.input_shutdown()
	}
}
