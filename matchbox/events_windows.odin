#+build windows

package matchbox

/*
	Events
	======
	Handles the events that trigger window callback procedure in window.odin
*/

import win "core:sys/windows"

import gi "vendor:windows/GameInput"

import "core:fmt"


/*Process the events sent to the window (events/inputs/etc)*/
poll_events :: proc() {
	
	// Before processing messages clear the input for keys pressed
	mbi.is_keys_pressed = {}
	mbi.is_button_pressed = {}

	event_message:win.MSG

	for win.PeekMessageW(lpMsg = &event_message, hWnd = mbi.window, wMsgFilterMin = 0,wMsgFilterMax = 0,wRemoveMsg = win.PM_REMOVE){
		win.TranslateMessage(lpMsg = &event_message)
		win.DispatchMessageW(lpMsg = &event_message)
	}

	// GameInput Checking for controller/gampad
	result := mbi.input->GetCurrentReading({.Gamepad}, mbi.gamepad, &mbi.reading)

	if win.SUCCEEDED(result) {
		if mbi.gamepad == nil do mbi.reading->GetDevice(&mbi.gamepad)

		if mbi.gamepad != nil  {

			state:gi.GamepadState
			ok := mbi.reading->GetGamepadState(&state)
			mbi.reading->Release()

			if .A in state.buttons  {
				mbi.is_button_pressed[.FACE_DOWN] = true
			}

			if .X in state.buttons  {
				mbi.is_button_pressed[.FACE_LEFT] = true
			}
			if .Y in state.buttons  {
				mbi.is_button_pressed[.FACE_UP] = true
			}

			if .B in state.buttons  {
				mbi.is_button_pressed[.FACE_LEFT] = true
			}

			if .DPadUp in state.buttons {
				mbi.is_button_pressed[.DPAD_UP] = true
			}
			if .DPadDown in state.buttons {
				mbi.is_button_pressed[.DPAD_DOWN] = true
			}
			if .DPadLeft in state.buttons {
				mbi.is_button_pressed[.DPAD_LEFT] = true
			}
			if .DPadRight in state.buttons {
				mbi.is_button_pressed[.DPAD_RIGHT] = true
			}

			if .Menu in state.buttons {
				mbi.is_button_pressed[.START] = true
			}
			
			if .View in state.buttons {
				mbi.is_button_pressed[.SELECT] = true
			}
			
			// gamepad joysticks

			mbi.left_thumbstick_axis = {state.leftThumbstickX, state.leftThumbstickY}
			mbi.right_thumbstick_axis = {state.rightThumbstickX, state.rightThumbstickY}

			mbi.left_trigger_value = state.leftTrigger
			mbi.right_trigger_value = state.rightTrigger
	
		}

	}
	
}


