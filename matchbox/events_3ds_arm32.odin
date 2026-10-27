package matchbox

/*
	Events
	======
	Handles the events that trigger window callback procedure in window.odin
*/


import "o3dx/ctru"

/*Process the events sent to the window (events/inputs/etc)*/
poll_events :: proc() {
    ctru.hidScanInput()
    if ctru.hidKeysDown() & ctru.KEY_START != 0 do mbi.is_running = false
}


