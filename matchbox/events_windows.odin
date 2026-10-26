package matchbox

/*
	Events
	======
	Handles the events that trigger window callback procedure in window.odin
*/

import win "core:sys/windows"



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


