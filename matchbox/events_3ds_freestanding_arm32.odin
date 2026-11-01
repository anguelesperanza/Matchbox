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

	left_thumbstick:ctru.circlePosition
	right_thumbstick:ctru.circlePosition
	
    ctru.hidScanInput()
    ctru.irrstScanInput()
    ctru.hidCircleRead(&left_thumbstick)
    
    ctru.irrstCstickRead(&right_thumbstick)
	mbi.gamepad_pressed = ctru.hidKeysDown()
	mbi.gamepad_held = ctru.hidKeysHeld()
	mbi.gamepad_released = ctru.hidKeysUp()

	/*
		Circle Pad and CStick / Circle Pad Pro
		This does two things: converts the input into a float and stores it, and then clamps the diagnals so they
		don't go over the max => 156
	*/
	mbi.left_thumbstick_axis = {f32(left_thumbstick.dx), f32(left_thumbstick.dy)} / mbi.left_thumbstick_max
	l := linalg.length(mbi.left_thumbstick_axis)
	if l > 1 do  mbi.left_thumbstick_axis = mbi.left_thumbstick_axis / l
	
	mbi.right_thumbstick_axis = {f32(right_thumbstick.dx), f32(right_thumbstick.dy)} / mbi.right_thumbstick_max
	l = linalg.length(mbi.right_thumbstick_axis)
	if l > 1 do  mbi.right_thumbstick_axis = mbi.right_thumbstick_axis / l
}
