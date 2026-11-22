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
import "o3dx/ctru"
import "o3dx/c3d"

when !VITA {

	// How the frame is copied to the screen. Lives in `mbi.display_settings`, set in BACKEND_DEFAULTS
	Display_Settings :: struct {
		transfer_flags:u32,
	}


	Timestamp :: struct {
		last_time:u64,
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
		ctru.consoleInit(ctru.GFX_BOTTOM, nil)

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


		create_render_pipeline()

		// The meshes every sprite and shape is drawn with, as on PC
		sprite_vertices, sprite_indices := mesh_quad()
		mbi.sprite_mesh = create_mesh(sprite_vertices, sprite_indices)
		delete(sprite_vertices)
		delete(sprite_indices)

		triangle_vertices, triangle_indices := mesh_triangle()
		mbi.triangle_mesh = create_mesh(triangle_vertices, triangle_indices)
		delete(triangle_vertices)
		delete(triangle_indices)

		circle_vertices, circle_indices := mesh_circle()
		mbi.circle_mesh = create_mesh(circle_vertices, circle_indices)
		delete(circle_vertices)
		delete(circle_indices)

		// Delta time
		mbi.timestamp.last_time = ctru.osGetTime()
	}

	/*Returns true if the window is running; other returns fale -> Almost always will return true*/
	is_running :: proc() -> bool {
		return mbi.is_running && ctru.aptMainLoop()
	}

	/*Stops running the application*/
	stop_running :: proc() {
		mbi.is_running = false
	}

	/*Returns the delta time value*/
	get_delta_time :: proc() -> (delta_time:f32) {
		now := ctru.osGetTime() // u64, milliseconds
		delta_time = f32(f64(now - mbi.timestamp.last_time) / 1000.0)
		mbi.timestamp.last_time = now
		return delta_time
	}

	/*Cleans up resources created by Matchbox*/
	cleanup :: proc() {
		destroy_mesh(mbi.triangle_mesh)
		destroy_mesh(mbi.circle_mesh)
		destroy_mesh(mbi.sprite_mesh)
		destroy_render_pipeline()

		c3d.Fini()
		ctru.gfxExit()
		ctru.romfsExit()
	}
}
