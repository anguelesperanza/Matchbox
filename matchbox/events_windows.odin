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
		case win.WM_KILLFOCUS:
			mbi.keys_pressed = {}
			mbi.keys_released = {}
			mbi.keys_held = {}
	
			mbi.gamepad_pressed = {}
			mbi.gamepad_released = {}
			mbi.gamepad_held = {}
	
			mbi.mouse_pressed = {}
			mbi.mouse_released = {}
			mbi.mouse_held = {}

		case win.WM_SIZE:
			mbi.did_resize = true
			if wParam != win.SIZE_MINIMIZED {
				mbi.window_size[0] = i32(win.LOWORD(lParam))
				mbi.window_size[1] = i32(win.HIWORD(lParam))
			}
		case win.WM_KEYDOWN:
			switch wParam {
				case win.VK_A..=win.VK_Z:
					mbi.keys_pressed[cast(Key)wParam] = true
					mbi.keys_held[cast(Key)wParam] = true
				case win.VK_0 ..= win.VK_9:
					mbi.keys_pressed[cast(Key)wParam] = true
					mbi.keys_held[cast(Key)wParam] = true
				case win.VK_BACK ..= win.VK_HELP:
					mbi.keys_pressed[cast(Key)wParam] = true
					mbi.keys_held[cast(Key)wParam] = true
			}
		case win.WM_KEYUP:
			switch wParam {
				case win.VK_A..=win.VK_Z:
					mbi.keys_held[cast(Key)wParam] = false
					mbi.keys_released[cast(Key)wParam] = true
				case win.VK_0 ..= win.VK_9:
					mbi.keys_held[cast(Key)wParam] = false
					mbi.keys_released[cast(Key)wParam] = true
				case win.VK_BACK ..= win.VK_HELP:
					mbi.keys_held[cast(Key)wParam] = false
					mbi.keys_released[cast(Key)wParam] = true
			}

		case win.WM_MOUSEMOVE:
			mbi.mouse_position = {win.GET_X_LPARAM(lParam),win.GET_Y_LPARAM(lParam)}
			
		case win.WM_MOUSEWHEEL:
			mbi.mouse_wheel_value = win.GET_WHEEL_DELTA_WPARAM(wParam)

		case win.WM_LBUTTONDOWN:
			mbi.mouse_pressed[.LEFT] = true
			mbi.mouse_held[.LEFT] = true
		case win.WM_RBUTTONDOWN:
			mbi.mouse_pressed[.RIGHT] = true
			mbi.mouse_held[.RIGHT] = true
		case win.WM_MBUTTONDOWN:
			mbi.mouse_pressed[.MIDDLE] = true
			mbi.mouse_held[.MIDDLE] = true
		
		case win.WM_XBUTTONDOWN: // The two side buttons on some mice
			switch win.GET_XBUTTON_WPARAM(wParam) {
				case win.XBUTTON1:
					mbi.mouse_pressed[.SIDE_1] = true
					mbi.mouse_held[.SIDE_1] = true
				case win.XBUTTON2:
					mbi.mouse_pressed[.SIDE_2] = true
					mbi.mouse_held[.SIDE_2] = true
					
			}

		case win.WM_LBUTTONUP:
			mbi.mouse_held[.LEFT] = false
			mbi.mouse_released[.LEFT] = true
		case win.WM_RBUTTONUP:
			mbi.mouse_held[.RIGHT] = false
			mbi.mouse_released[.RIGHT] = true
		case win.WM_MBUTTONUP:
			mbi.mouse_held[.MIDDLE] = false
			mbi.mouse_released[.MIDDLE] = true
		
		case win.WM_XBUTTONUP: // The two side buttons on some mice
			switch win.GET_XBUTTON_WPARAM(wParam){
				case win.XBUTTON1:
					mbi.mouse_held[.SIDE_1] = false
					mbi.mouse_released[.SIDE_1] = true
				case win.XBUTTON2:
					mbi.mouse_held[.SIDE_2] = false
					mbi.mouse_released[.SIDE_2] = true
			}
		}

	return win.DefWindowProcW(window, message, wParam, lParam)
}

/*Process the events sent to the window (events/inputs/etc)*/
poll_events :: proc() {
	
	// Before processing messages clear the input for keys pressed
	mbi.keys_pressed = {}
	mbi.keys_released = {}
	
	mbi.mouse_pressed = {}
	mbi.mouse_released = {}

	
	mbi.mouse_wheel_value = 0

	event_message:win.MSG

	for win.PeekMessageW(lpMsg = &event_message, hWnd = mbi.window, wMsgFilterMin = 0,wMsgFilterMax = 0,wRemoveMsg = win.PM_REMOVE){
		win.TranslateMessage(lpMsg = &event_message)
		win.DispatchMessageW(lpMsg = &event_message)
	}

	// GameInput Checking for controller/gampad
	connected:bool = false
	result := mbi.input->GetCurrentReading({.Gamepad}, mbi.gamepad, &mbi.reading)

	if win.SUCCEEDED(result) {
		if mbi.gamepad == nil do mbi.reading->GetDevice(&mbi.gamepad)

		state:gi.GamepadState
		connected = mbi.reading->GetGamepadState(&state)
		mbi.reading->Release()

		if connected {
			previous := mbi.gamepad_held
			current: bit_set[Button]

			if .A in state.buttons do current += {.FACE_DOWN}
			if .X in state.buttons do current += {.FACE_LEFT}
			if .Y in state.buttons do current += {.FACE_UP}
			if .B in state.buttons do current += {.FACE_RIGHT}
			if .DPadUp in state.buttons do current += {.DPAD_UP}
			if .DPadDown in state.buttons do current += {.DPAD_DOWN}
			if .DPadLeft in state.buttons do current += {.DPAD_LEFT}
			if .DPadRight in state.buttons do current += {.DPAD_RIGHT}
			if .LeftShoulder in state.buttons do current += {.LEFT_SHOULDER}
			if .RightShoulder in state.buttons do current += {.RIGHT_SHOULDER}
			if .LeftThumbstick in state.buttons do current += {.LEFT_THUMBSTICK}
			if .RightThumbstick in state.buttons do current += {.RIGHT_THUMBSTICK}
			if .Menu in state.buttons do current += {.START}
			if .View in state.buttons do current += {.SELECT}
			
			// gamepad joysticks

			mbi.left_thumbstick_axis = {state.leftThumbstickX, state.leftThumbstickY}
			mbi.right_thumbstick_axis = {state.rightThumbstickX, state.rightThumbstickY}

			mbi.left_trigger_value = state.leftTrigger
			mbi.right_trigger_value = state.rightTrigger


			if state.leftTrigger  > mbi.left_trigger_as_button_value  do current += {.LEFT_TRIGGER}
			if state.rightTrigger > mbi.right_trigger_as_button_value do current += {.RIGHT_TRIGGER}


			mbi.gamepad_held = current
			mbi.gamepad_pressed = current - previous
			mbi.gamepad_released = previous - current
		}
	}

	// No valid reading this frame (unplugged, read failed, etc.): treat as everything released
	if connected == false {
		mbi.gamepad_released = mbi.gamepad_held
		mbi.gamepad_held = {}
		mbi.gamepad_pressed = {}
		
		mbi.left_thumbstick_axis = {}
		mbi.right_thumbstick_axis = {}
		
		mbi.left_trigger_value = 0
		mbi.right_trigger_value = 0

		// Drop the stale device so the next call can pick up whichever pad is plugged in
		if mbi.gamepad != nil {
			mbi.gamepad->Release()
			mbi.gamepad = nil
		}
	}
}
