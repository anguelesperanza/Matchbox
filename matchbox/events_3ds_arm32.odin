package matchbox

/*
	Events
	======
	Handles the events for the 3DS.

	What's not mapped yet:
	Held input
	repeated input
*/


import "o3dx/ctru"

/*Process the events sent to the window (events/inputs/etc)*/
poll_events :: proc() {

	mbi.is_keys_pressed = {}
	
    ctru.hidScanInput()
	pressed := ctru.hidKeysDown()
    
    if pressed & cast(u32)Key.M != 0 do mbi.is_running = false
    if pressed & cast(u32)Key.A != 0 do mbi.is_keys_pressed[.A] = true
    if pressed & cast(u32)Key.S != 0 do mbi.is_keys_pressed[.S] = true
    if pressed & cast(u32)Key.Z != 0 do mbi.is_keys_pressed[.Z] = true
    if pressed & cast(u32)Key.X != 0 do mbi.is_keys_pressed[.X] = true
    if pressed & cast(u32)Key.F != 0 do mbi.is_keys_pressed[.F] = true
    if pressed & cast(u32)Key.H != 0 do mbi.is_keys_pressed[.H] = true
    if pressed & cast(u32)Key.T != 0 do mbi.is_keys_pressed[.T] = true
    if pressed & cast(u32)Key.G != 0 do mbi.is_keys_pressed[.G] = true
    if pressed & cast(u32)Key.Q != 0 do mbi.is_keys_pressed[.Q] = true
    if pressed & cast(u32)Key.W != 0 do mbi.is_keys_pressed[.W] = true
    if pressed & cast(u32)Key.M != 0 do mbi.is_keys_pressed[.M] = true
    if pressed & cast(u32)Key.N != 0 do mbi.is_keys_pressed[.N] = true
    if pressed & cast(u32)Key._1 != 0 do mbi.is_keys_pressed[._1] = true
    if pressed & cast(u32)Key._2 != 0 do mbi.is_keys_pressed[._2] = true
}


