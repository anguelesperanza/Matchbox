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

	mbi.is_button_pressed = {}

	left_thumbstick:ctru.circlePosition
	right_thumbstick:ctru.circlePosition
	
    ctru.hidScanInput()
    ctru.irrstScanInput()
    ctru.hidCircleRead(&left_thumbstick)
    
    ctru.irrstCstickRead(&right_thumbstick)
	pressed := ctru.hidKeysDown()


    // TODO == NEEDS REWORKING | USES OLD STYLE OF KEY BINDINGS FROM INPUT POC

	if pressed & cast(u32)Button.SELECT != 0 do mbi.is_button_pressed[.START] = true
	if pressed & cast(u32)Button.START != 0 do mbi.is_button_pressed[.START] = true

	// FACE buttons
	if pressed & cast(u32)Button.FACE_UP != 0 do mbi.is_button_pressed[.FACE_UP] = true
	if pressed & cast(u32)Button.FACE_DOWN != 0 do mbi.is_button_pressed[.FACE_DOWN] = true
	if pressed & cast(u32)Button.FACE_LEFT != 0 do mbi.is_button_pressed[.FACE_LEFT] = true
	if pressed & cast(u32)Button.FACE_RIGHT != 0 do mbi.is_button_pressed[.FACE_RIGHT] = true

	// DPAD
	if pressed & cast(u32)Button.DPAD_UP != 0 do mbi.is_button_pressed[.DPAD_UP] = true
	if pressed & cast(u32)Button.DPAD_DOWN != 0 do mbi.is_button_pressed[.DPAD_DOWN] = true
	if pressed & cast(u32)Button.DPAD_LEFT != 0 do mbi.is_button_pressed[.DPAD_LEFT] = true
	if pressed & cast(u32)Button.DPAD_RIGHT != 0 do mbi.is_button_pressed[.DPAD_RIGHT] = true

	// Shoulder Buttons
	if pressed & cast(u32)Button.LEFT_SHOULDER != 0 do mbi.is_button_pressed[.LEFT_SHOULDER] = true
	if pressed & cast(u32)Button.RIGHT_SHOULDER != 0 do mbi.is_button_pressed[.RIGHT_SHOULDER] = true
	
	if pressed & cast(u32)Button.LEFT_TRIGGER != 0 do mbi.is_button_pressed[.LEFT_TRIGGER] = true
	if pressed & cast(u32)Button.RIGHT_TRIGGER != 0 do mbi.is_button_pressed[.RIGHT_TRIGGER] = true

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
