package matchbox


/*
	Window
	======
	This file handles the window creation events for D3D11
*/

import "core:log"
import win "core:sys/windows"

import "base:runtime"

Timestamp :: struct {
	fixed_timestamp:f64,
	accumulator:f64,
	deltatime:f64,
	current_time:win.LARGE_INTEGER,
	last_time: win.LARGE_INTEGER,
	frequency: win.LARGE_INTEGER,
	counter: win.LARGE_INTEGER,
}
timestamp:Timestamp

Matchbox_Info :: struct {
	window:win.HWND,
	is_running:bool,
	is_keys_pressed: #sparse [Key]bool,
	logger:log.Logger,
	event_message:^win.MSG,
}

mbi:Matchbox_Info


window_event_proc :: proc "stdcall" (window: win.HWND, message: win.UINT, wParam: win.WPARAM, lParam: win.LPARAM) -> win.LRESULT {
	context = runtime.default_context()
	log.info("Processing Events")
	switch message {
		case win.WM_QUIT:
			stop_running()
		case win.WM_DESTROY:
			stop_running()
			// mbi.is_running = false
			
		case win.WM_KEYDOWN:
			switch wParam {
				case win.VK_A..=win.VK_Z:
					mbi.is_keys_pressed[cast(Key)wParam] = true
				case win.VK_0 ..= win.VK_9:
					mbi.is_keys_pressed[cast(Key)wParam] = true
				case win.VK_BACK ..= win.VK_HELP:
					mbi.is_keys_pressed[cast(Key)wParam] = true
			}
		case win.WM_KEYUP:
			switch wParam {
				case win.VK_A..=win.VK_Z:
					mbi.is_keys_pressed[cast(Key)wParam] = false
				case win.VK_0 ..= win.VK_9:
					mbi.is_keys_pressed[cast(Key)wParam] = false
				case win.VK_BACK ..= win.VK_HELP:
					mbi.is_keys_pressed[cast(Key)wParam] = false
			}
		
		}
		
	return win.DefWindowProcW(window, message, wParam, lParam)
}

init :: proc(title:string, width:i32, height:i32) {

	mbi.is_running = true

	mbi.logger = log.create_console_logger()
	context.logger = mbi.logger
	// log.info("Init")
	
	rect:win.RECT = {left = 0, top = 0, right = width, bottom = height}

	// Create a handle to the instance of the application - The thing the OS uses to ID the executable
	instance := win.HINSTANCE(win.GetModuleHandleW(nil)) // Create Instance

	// Create the attributes that the window will use when it's registered
	window_class: win.WNDCLASSEXW = {
		cbSize = size_of(win.WNDCLASSEXW),
		style = win.CS_OWNDC | win.CS_HREDRAW | win.CS_VREDRAW,
		lpfnWndProc = window_event_proc,
		cbClsExtra = 0,
		cbWndExtra = 0,
		hInstance = instance,
		hIcon = nil,
		hCursor = nil,
		hbrBackground = nil,
		lpszMenuName = nil,
		lpszClassName = win.L("Basic_Game_Class"),
		hIconSm = nil,
	}
	
	win.RegisterClassExW(&window_class)
	win.AdjustWindowRect(lpRect = &rect, dwStyle = win.WS_OVERLAPPEDWINDOW, bMenu = win.FALSE) // Adjust window

	mbi.window = win.CreateWindowExW(
		dwExStyle = 0,
		lpClassName = window_class.lpszClassName,
		lpWindowName = win.utf8_to_wstring(title),  //win.L("Basic Window"),
		dwStyle = win.WS_OVERLAPPEDWINDOW | win.WS_VISIBLE | win.WS_SYSMENU,
		X = win.CW_USEDEFAULT,
		Y = win.CW_USEDEFAULT,
		nWidth = rect.right - rect.left,
		nHeight = rect.bottom - rect.top,
		hWndParent = nil,
		hMenu = nil,
		hInstance = instance,
		lpParam = nil,
	)
	
	if mbi.window == nil {
		log.error("Could not create window")
		return
	}

	// // Setup the initial frequency and counter for delta time
	win.QueryPerformanceFrequency(&timestamp.frequency)
	win.QueryPerformanceCounter(&timestamp.last_time)
}

/*Returns the current value of wi.runing*/
is_running :: proc() -> bool {
	return mbi.is_running
}

stop_running :: proc() {
	mbi.is_running = false
}

get_delta_time :: proc() -> (dt:f64) {
	/*In C, a LARGE_INTEGER is a struct, In Odin, it's a c_longlong --> an f64*/
	now:win.LARGE_INTEGER
	win.QueryPerformanceCounter(lpPerformanceCount = &now)
	current_time := f64(now - timestamp.last_time) / cast(f64)timestamp.frequency
	return dt
}

cleanup :: proc() {
	log.destroy_console_logger(mbi.logger)
}

