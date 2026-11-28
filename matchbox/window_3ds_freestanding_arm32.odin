#+build freestanding arm32

package matchbox


/*
	Window -- 3DS
	======
	This file handles the window creation events

	On the 3DS this sets the intial Ctru and Citro3D Defaults

	Inside `when !VITA` for the reason in backend_3ds_freestanding_arm32.odin
*/

// Core
import "base:runtime"

import "o3dx/ctru"
import "o3dx/c3d"
import "o3dx/o3dx"

when !VITA {

	// How the frame is copied to the screen. Lives in `mbi.display_settings`, set in BACKEND_DEFAULTS
	Display_Settings :: struct {
		transfer_flags:u32,
	}


	/*Initialize the core of Matchbox for the target platform*/
	init :: proc(title:string, width:i32, height:i32) {

		mbi.is_running = true
		mbi.asset_path = "romfs:/"
		mbi.screen_height = mbi.screen_settings.default_height // the HUD's height until set_screen_height

		romfs_rc := ctru.romfsInit()
		ctru.irrstInit()

		ctru.gfxInitDefault()
		c3d.Init(c3d.DEFAULT_CMDBUF_SIZE)

		// No ctru console: the bottom screen is the game's to draw on, and `print` draws its lines
		// there itself (bottom_screen_3ds_freestanding_arm32.odin). o3dx's own printf to that
		// console would go nowhere, so it is switched off; its debug-log copy stays. The console
		// comes back for set_bottom_screen(.CONSOLE), and for a crash (report_crash)
		o3dx.print_to_console = false

		// As the player holds it (see get_window_size). The render target below is the
		// panel's own way round, 240 x 400
		mbi.window_size = {400, 240, 320, 240}

		mbi.top_screen = c3d.RenderTargetCreate(
			width = 240,
			height = 400,
			colorFmt = .RGBA8,
			depthFmt = c3d.DEPTHTYPE_DEPTH24_STENCIL8
		)

		c3d.RenderTargetSetOutput(
			target = mbi.top_screen,
			screen = ctru.GFX_TOP,
			side = ctru.GFX_LEFT,
			transferFlags = mbi.display_settings.transfer_flags
		)

		// The bottom screen's panel is on its side too: 240 x 320
		mbi.bottom_screen = c3d.RenderTargetCreate(
			width = 240,
			height = 320,
			colorFmt = .RGBA8,
			depthFmt = c3d.DEPTHTYPE_DEPTH24_STENCIL8
		)

		c3d.RenderTargetSetOutput(
			target = mbi.bottom_screen,
			screen = ctru.GFX_BOTTOM,
			side = ctru.GFX_LEFT,
			transferFlags = mbi.display_settings.transfer_flags
		)


		create_render_pipeline()

		// The meshes every sprite and shape is drawn with, as on PC
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

		// The print log's text: the system font, 1 unit a screen pixel (render_print_log)
		mbi.print_log.font = create_font(DEFAULT_FONT_BYTES, mbi.print_log_settings.pixel_size, 1)

		// A game that asked for the console before init gets it now, once the screens exist
		if mbi.bottom_screen_layout == .CONSOLE do start_bottom_screen_console()

		// svcGetSystemTick rather than osGetTime: osGetTime counts whole milliseconds, so a
		// 16.67 ms frame read as 16 or 17 and delta time alternated between them. The system
		// tick runs at SYSCLOCK_ARM11 on every model, New 3DS included, whatever the CPU clock
		start_clock(&mbi.clock, ctru.svcGetSystemTick(), ctru.SYSCLOCK_ARM11)

		// Odin's random generator seeds itself from the system's entropy the first time it is
		// used, and freestanding has none: the runtime traps ("no runtime entropy source"), past
		// report_crash, so a game's first rand call stopped it dead. Seeded here instead, from the
		// date and the tick, which differ every boot. Not cryptographic; a game that wants that,
		// or a repeatable run, calls rand.reset itself after init
		runtime.random_generator_reset_u64(context.random_generator, ctru.osGetTime() ~ ctru.svcGetSystemTick())
	}

	/*Returns true if the window is running; other returns fale -> Almost always will return true*/
	is_running :: proc() -> bool {
		return mbi.is_running && ctru.aptMainLoop()
	}

	/*Stops running the application*/
	stop_running :: proc() {
		mbi.is_running = false
	}

	/*Cleans up resources created by Matchbox*/
	cleanup :: proc() {
		// The last frame may still be executing on the GPU, and the frees below hand its meshes and shader programs back. The Vita
		// waits (gfx.finish); without this the heavier scenes froze or crashed the 3DS on quit
		c3d.FrameSync()
		destroy_font(mbi.print_log.font)
		mbi.print_log.font = {}
		destroy_mesh(mbi.triangle_mesh)
		destroy_mesh(mbi.circle_mesh)
		destroy_mesh(mbi.sprite_mesh)
		destroy_render_pipeline()
		c3d.RenderTargetDelete(mbi.bottom_screen)
		c3d.RenderTargetDelete(mbi.top_screen)

		c3d.Fini()
		ctru.gfxExit()
		ctru.romfsExit()
	}
}
