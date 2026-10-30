#+build freestanding arm32

package matchbox

/*
	Events
	======
	Handles the events for the 3DS.

	What's not mapped yet:
	Held input
	repeated input
*/


import "core:math/linalg"
import "o3dx/ctru"




/*Process the events sent to the window (events/inputs/etc)*/
poll_events :: proc() {

	mbi.is_keys_pressed = {}

	left_thumbstick:ctru.circlePosition
	right_thumbstick:ctru.circlePosition
	
    ctru.hidScanInput()
    ctru.hidCircleRead(&left_thumbstick)
    
    ctru.irrstCstickRead(&right_thumbstick)
	pressed := ctru.hidKeysDown()


	/*
		This does two things: converts the input into a float and stores it, and then clamps the diagnals so they
		don't go over the max => 156
	*/
	mbi.left_thumbstick_axis = {f32(left_thumbstick.dx), f32(left_thumbstick.dy)} / mbi.left_thumbstick_max
	l := linalg.length(mbi.left_thumbstick_axis)
	if l > 1 do  mbi.left_thumbstick_axis = mbi.left_thumbstick_axis / l
	
	mbi.right_thumbstick_axis = {f32(right_thumbstick.dx), f32(right_thumbstick.dy)} / mbi.right_thumbstick_max
	l = linalg.length(mbi.right_thumbstick_axis)
	if l > 1 do  mbi.right_thumbstick_axis = mbi.right_thumbstick_axis / l

    // TODO == NEEDS REWORKING | USES OLD STYLE OF KEY BINDINGS FROM INPUT POC
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


