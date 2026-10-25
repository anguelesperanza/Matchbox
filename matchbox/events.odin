package matchbox

import win "core:sys/windows"

import "vendor:directx/d3d11"
import "vendor:directx/dxgi"
import "vendor:directx/d3d_compiler"
import "vendor:directx/d3d_common"

/*Process the events sent to the window (events/inputs/etc)*/
poll_events :: proc() {
	
	// Before processing messages clear the input for keys pressed
	mbi.is_keys_pressed = {}

	event_message:win.MSG

	for win.PeekMessageW(lpMsg = &event_message, hWnd = mbi.window, wMsgFilterMin = 0,wMsgFilterMax = 0,wRemoveMsg = win.PM_REMOVE){
		win.TranslateMessage(lpMsg = &event_message)
		win.DispatchMessageW(lpMsg = &event_message)
	}
}


