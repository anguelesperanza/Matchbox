#+build freestanding arm32

package matchbox


/*
	Window -- 3DS
	======
	This file handles the window creation events

	On the 3DS this sets the intial Ctru and Citro3D Defaults
	
*/

// Core
import "o3dx/ctru"
import "o3dx/c3d"


// Constants
DISPLAY_TRANSFER_FLAGS :: u32(0x1000)


Timestamp :: struct {
	last_time:u64,
}
timestamp:Timestamp


Matchbox_Info :: struct {

	// General values
	is_running:bool,
	asset_path:string,
	window_size:[4]i32,

	
	did_resize:bool,
	top_screen:rawptr,
	bottom_screen:rawptr,
	left_thumbstick_axis:[2]f32,
	right_thumbstick_axis:[2]f32,
	left_thumbstick_max:f32,
	right_thumbstick_max:f32,
	gamepad_pressed:u32,
	gamepad_held:u32,
	gamepad_released:u32,
}

mbi:Matchbox_Info


/*Initialize the core of Matchbox for the target platform*/
init :: proc(title:string, width:i32, height:i32) {

	mbi.is_running = true
	mbi.asset_path = "romfs:/"

	/*Based on my New 3DS LL values*/
	mbi.left_thumbstick_max = 156
	mbi.right_thumbstick_max = 146
	
    romfs_rc := ctru.romfsInit()
    ctru.irrstInit()
    
    ctru.gfxInitDefault()
    c3d.Init(c3d.DEFAULT_CMDBUF_SIZE)
    ctru.consoleInit(ctru.GFX_BOTTOM, nil)

	mbi.window_size[0] = 240
	mbi.window_size[1] = 400

	
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
		transferFlags = DISPLAY_TRANSFER_FLAGS
	)


	// Delta time
	timestamp.last_time = ctru.osGetTime()
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
get_delta_time :: proc() -> (dt:f32) {
	now := ctru.osGetTime() // u64, milliseconds
	dt = f32(f64(now - timestamp.last_time) / 1000.0)
	timestamp.last_time = now
	return dt
}

/*Cleans up resources created by Matchbox*/
cleanup :: proc() {

    c3d.Fini()
    ctru.gfxExit()
    ctru.romfsExit()
	
	// log.destroy_console_logger(mbi.logger)
}
