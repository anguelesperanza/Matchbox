#+build windows

package matchbox

/*
	Events
	======
	Handles the events that trigger window callback procedure in window.odin
*/

import win "core:sys/windows"
import gi "vendor:windows/GameInput"
import "base:runtime"

/*The window callback procedure for processing events (a win32 requirement)*/
window_event_proc :: proc "stdcall" (window: win.HWND, message: win.UINT, wParam: win.WPARAM, lParam: win.LPARAM) -> win.LRESULT {
	context = runtime.default_context()
	switch message {
		case win.WM_QUIT:
			stop_running()
		case win.WM_DESTROY:
			stop_running()

		case win.WM_SIZE:
			mbi.did_resize = true
		case win.WM_KEYDOWN:
			switch wParam {
				case win.VK_A..=win.VK_Z:
					mbi.is_keys_pressed[cast(Key)wParam] = true
					mbi.is_keys_held[cast(Key)wParam] = true
				case win.VK_0 ..= win.VK_9:
					mbi.is_keys_pressed[cast(Key)wParam] = true
					mbi.is_keys_held[cast(Key)wParam] = true
				case win.VK_BACK ..= win.VK_HELP:
					mbi.is_keys_pressed[cast(Key)wParam] = true
					mbi.is_keys_held[cast(Key)wParam] = true
			}
		case win.WM_KEYUP:
			switch wParam {
				case win.VK_A..=win.VK_Z:
					mbi.is_keys_held[cast(Key)wParam] = false
					mbi.is_keys_released[cast(Key)wParam] = true
				case win.VK_0 ..= win.VK_9:
					mbi.is_keys_held[cast(Key)wParam] = false
					mbi.is_keys_released[cast(Key)wParam] = true
				case win.VK_BACK ..= win.VK_HELP:
					mbi.is_keys_held[cast(Key)wParam] = false
					mbi.is_keys_released[cast(Key)wParam] = true
			}

		case win.WM_MOUSEMOVE:
			mbi.mouse_position = {win.GET_X_LPARAM(lParam),win.GET_Y_LPARAM(lParam)}
			
		case win.WM_MOUSEWHEEL:
			mbi.mouse_wheel_value = win.GET_WHEEL_DELTA_WPARAM(wParam)

		case win.WM_LBUTTONDOWN:
			mbi.is_mouse_pressed[.LEFT] = true
			mbi.is_mouse_held[.LEFT] = true
		case win.WM_RBUTTONDOWN:
			mbi.is_mouse_pressed[.RIGHT] = true
			mbi.is_mouse_held[.RIGHT] = true
		case win.WM_MBUTTONDOWN:
			mbi.is_mouse_pressed[.MIDDLE] = true
			mbi.is_mouse_held[.MIDDLE] = true
		
		case win.WM_XBUTTONDOWN: // The two side buttons on some mice
			button := win.GET_KEYSTATE_WPARAM(wParam)

			switch button {
				case 32:
					mbi.is_mouse_pressed[.SIDE_1] = true
					mbi.is_mouse_held[.SIDE_1] = true
				case 64:
					mbi.is_mouse_pressed[.SIDE_2] = true
					mbi.is_mouse_held[.SIDE_2] = true
					
			}

		case win.WM_LBUTTONUP:
			mbi.is_mouse_held[.LEFT] = false
			mbi.is_mouse_released[.LEFT] = true
		case win.WM_RBUTTONUP:
			mbi.is_mouse_held[.RIGHT] = false
			mbi.is_mouse_released[.RIGHT] = true
		case win.WM_MBUTTONUP:
			mbi.is_mouse_held[.MIDDLE] = false
			mbi.is_mouse_released[.MIDDLE] = true
		
		case win.WM_XBUTTONUP: // The two side buttons on some mice
			button := win.GET_KEYSTATE_WPARAM(wParam)

			switch button {
				case 32:
					mbi.is_mouse_held[.SIDE_1] = false
					mbi.is_mouse_pressed[.SIDE_1] = true
				case 64:
					mbi.is_mouse_held[.SIDE_2] = false
					mbi.is_mouse_pressed[.SIDE_2] = true
			}
		}

	return win.DefWindowProcW(window, message, wParam, lParam)
}

/*Process the events sent to the window (events/inputs/etc)*/
poll_events :: proc() {
	
	// Before processing messages clear the input for keys pressed
	mbi.is_keys_pressed = {}
	mbi.is_keys_released = {}
	
	mbi.is_button_pressed = {}
	mbi.is_button_released = {}
	
	mbi.is_mouse_pressed = {}
	mbi.is_mouse_released = {}

	
	mbi.mouse_wheel_value = 0

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
				mbi.is_button_pressed[.FACE_RIGHT] = true
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


