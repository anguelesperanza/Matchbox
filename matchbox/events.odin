package matchbox

import win "core:sys/windows"

/*Process the events sent to the window (events/inputs/etc)*/
poll_events :: proc() {
	
	// Before processing messages clear the input for keys pressed
	mbi.is_keys_pressed = {}

	event_message:win.MSG

	if win.PeekMessageW(lpMsg = &event_message, hWnd = mbi.window, wMsgFilterMin = 0,wMsgFilterMax = 0,wRemoveMsg = win.PM_REMOVE){
		win.TranslateMessage(lpMsg = &event_message)
		win.DispatchMessageW(lpMsg = &event_message)
	} else {
		win.InvalidateRect(hWnd = mbi.window, lpRect = nil, bErase = win.FALSE)
		win.UpdateWindow(hWnd = mbi.window)
	}
}


