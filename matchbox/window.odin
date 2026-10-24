package matchbox


/*
	Window
	======
	This file handles the window creation events for D3D11
*/

import win "core:sys/windows"


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
}

mbi:Matchbox_Info


window_event_proc :: proc "stdcall" (window: win.HWND, message: win.UINT, wParam: win.WPARAM, lParam: win.LPARAM) -> win.LRESULT {
	switch message {
		case win.WM_PAINT:

		case win.WM_DESTROY:
			mbi.is_running = false
		case win.WM_KEYDOWN:
			// The event for handling key presses (like escape, shift, etc)
			switch wParam {
				case win.VK_ESCAPE:
					mbi.is_running = false
			}
		}
		
	return win.DefWindowProcW(window, message, wParam, lParam)
}

init :: proc(title:string, width:i32, height:i32) {

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
		return
	}
}

/*Returns the current value of wi.runing*/
is_running :: proc() -> bool {
	return mbi.is_running
}

get_delta_time :: proc() -> i64{
	/*In C, a LARGE_INTEGER is a struct, In Odin, it's a c_longlong --> an f64*/
	win.QueryPerformanceFrequency(lpFrequency = &timestamp.frequency)
	win.QueryPerformanceCounter(lpPerformanceCount = &timestamp.counter)
	current_time := timestamp.counter / timestamp.frequency
	return cast(i64)current_time
}


