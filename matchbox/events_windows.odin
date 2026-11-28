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
import "core:reflect"
import "core:unicode/utf8"

/*The window callback procedure for processing events (a win32 requirement)*/
window_event_proc :: proc "stdcall" (window: win.HWND, message: win.UINT, wParam: win.WPARAM, lParam: win.LPARAM) -> win.LRESULT {
	context = runtime.default_context()
	switch message {
		// Off by default, so a game that never heard of this still closes: DefWindowProc destroys the window. With
		// set_close_confirmation on, nothing is destroyed here and the game decides (is_close_requested, stop_running)
		case win.WM_CLOSE:
			if mbi.close_confirmation {
				mbi.close_requested = true
				return 0
			}
		case win.WM_QUIT:
			stop_running()
		case win.WM_DESTROY:
			stop_running()
		case win.WM_KILLFOCUS:
			mbi.keys_pressed = {}
			mbi.keys_released = {}
			mbi.keys_held = {}
			mbi.keys_repeated = {}
			mbi.typed_high_surrogate = 0
			if win.GetCapture() == window do win.ReleaseCapture()
	
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
			if key, ok := get_key_from_message(wParam, lParam); ok {
				// Bit 30 of lParam is the key's state before this message: set means it was already down, so this is the
				// keyboard's auto-repeat. Only a first press counts as pressed, so a shortcut fires once however long it is held
				is_repeat := (lParam & (1 << 30)) != 0
				if is_repeat == false do mbi.keys_pressed[key] = true
				mbi.keys_repeated[key] = true
				mbi.keys_held[key] = true
				// The keypad's Enter is RETURN to Windows, so it answers as RETURN as well as KEYPAD_ENTER
				if key == .KEYPAD_ENTER {
					if is_repeat == false do mbi.keys_pressed[.RETURN] = true
					mbi.keys_repeated[.RETURN] = true
					mbi.keys_held[.RETURN] = true
				}
			}
		case win.WM_KEYUP:
			if key, ok := get_key_from_message(wParam, lParam); ok {
				mbi.keys_held[key] = false
				mbi.keys_released[key] = true
				if key == .KEYPAD_ENTER {
					mbi.keys_held[.RETURN] = false
					mbi.keys_released[.RETURN] = true
				}
			}

		// The text the layout made of the keys, one UTF-16 unit at a time: a character outside the BMP arrives as two
		case win.WM_CHAR:
			add_typed_unit(u16(wParam))

		case win.WM_MOUSEMOVE:
			mbi.mouse_position = {win.GET_X_LPARAM(lParam),win.GET_Y_LPARAM(lParam)}
			
		// Added, not assigned: two wheel messages in one frame are both the player's, and the sum saturates rather than wraps
		case win.WM_MOUSEWHEEL:
			mbi.mouse_wheel_value = add_wheel_delta(mbi.mouse_wheel_value, win.GET_WHEEL_DELTA_WPARAM(wParam))
		case win.WM_MOUSEHWHEEL:
			mbi.mouse_wheel_horizontal_value = add_wheel_delta(mbi.mouse_wheel_horizontal_value, win.GET_WHEEL_DELTA_WPARAM(wParam))

		// The cursor over the window's own area is the one the game chose. Elsewhere (the title bar, the borders) Windows chooses
		case win.WM_SETCURSOR:
			if win.LOWORD(lParam) == win.HTCLIENT && mbi.mouse_capture.applied == false {
				cursor := mbi.cursors[mbi.cursor_shape]
				if cursor != nil {
					win.SetCursor(cursor)
					return 1
				}
			}

		case win.WM_DROPFILES:
			add_dropped_files(win.HDROP(wParam))

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

	// A drag that leaves the window still has to end in the window's hands: while any button is down the window owns the
	// pointer (SetCapture), so the move and the release are seen however far outside it goes, and `held` cannot stick
	switch message {
	case win.WM_LBUTTONDOWN, win.WM_RBUTTONDOWN, win.WM_MBUTTONDOWN, win.WM_XBUTTONDOWN,
	     win.WM_LBUTTONUP, win.WM_RBUTTONUP, win.WM_MBUTTONUP, win.WM_XBUTTONUP:
		update_pointer_capture(window)
	}

	return win.DefWindowProcW(window, message, wParam, lParam)
}

/*Holds the pointer for the window while a mouse button is down and gives it back when the last one is released*/
@(private)
update_pointer_capture :: proc(window: win.HWND) {
	any_held := false
	for held in mbi.mouse_held do any_held ||= held
	if any_held {
		if win.GetCapture() != window do win.SetCapture(window)
	} else if win.GetCapture() == window {
		win.ReleaseCapture()
	}
}

// One wheel step is 120; the sum of a frame's steps stays inside an i16 by stopping at its ends
@(private)
add_wheel_delta :: proc(total: i16, delta: i16) -> i16 {
	return i16(clamp(i32(total) + i32(delta), i32(min(i16)), i32(max(i16))))
}

/*Reads the files of a drop into this frame's list, with the window position they landed at, and gives the drop back to the shell*/
@(private)
add_dropped_files :: proc(drop: win.HDROP) {
	defer win.DragFinish(drop)
	heap := runtime.heap_allocator()

	point: win.POINT
	win.DragQueryPoint(drop, &point)

	count := win.DragQueryFileW(drop, 0xFFFFFFFF, nil, 0)
	for index in 0 ..< count {
		length := win.DragQueryFileW(drop, index, nil, 0)
		units := make([]u16, length + 1, heap)
		defer delete(units, heap)
		win.DragQueryFileW(drop, index, raw_data(units), length + 1)
		path, error := win.utf16_to_utf8(units[:length], heap)
		if error != nil do continue
		append(&mbi.dropped_files, Dropped_File{path = path, position = {point.x, point.y}})
	}
}

@(private)
clear_dropped_files :: proc() {
	heap := runtime.heap_allocator()
	for file in mbi.dropped_files do delete(file.path, heap)
	clear(&mbi.dropped_files)
}

/*
	The Key a key message is for. Windows' virtual keys are what Key is made of, so most pass straight through; the keypad's
	Enter is the one a virtual key cannot tell from the main Enter, and is told by the extended-key bit (lParam bit 24).
	`ok` is false for a key Key has no name for
*/
@(private)
get_key_from_message :: proc(wParam: win.WPARAM, lParam: win.LPARAM) -> (key: Key, ok: bool) {
	if wParam == win.VK_RETURN && (lParam & (1 << 24)) != 0 do return .KEYPAD_ENTER, true
	key = Key(wParam)
	return key, reflect.enum_value_has_name(key)
}

/*
	Adds one UTF-16 unit from WM_CHAR to this frame's typed text. Control characters are skipped (Backspace, Tab and Enter
	come in as keys). The first half of a surrogate pair is held until its second arrives; a lone half is dropped
*/
@(private)
add_typed_unit :: proc(unit: u16) {
	character: rune
	switch {
	case unit < 0x20 || unit == 0x7F:
		return
	case unit >= 0xD800 && unit <= 0xDBFF:
		mbi.typed_high_surrogate = unit
		return
	case unit >= 0xDC00 && unit <= 0xDFFF:
		high := mbi.typed_high_surrogate
		mbi.typed_high_surrogate = 0
		if high == 0 do return
		character = rune(0x10000) + (rune(high - 0xD800) << 10) + rune(unit - 0xDC00)
	case:
		mbi.typed_high_surrogate = 0
		character = rune(unit)
	}

	encoded, width := utf8.encode_rune(character)
	// A character that does not fit is dropped whole, never cut in the middle
	if mbi.typed_text_length + width > MAX_TEXT_INPUT do return
	copy(mbi.typed_text[mbi.typed_text_length:], encoded[:width])
	mbi.typed_text_length += width
}

/*Process the events sent to the window (events/inputs/etc)*/
poll_events :: proc() {

	counter:win.LARGE_INTEGER
	win.QueryPerformanceCounter(&counter)
	tick_clock(&mbi.clock, u64(counter))

	free_all(context.allocator)
	
	// Before processing messages clear the input for keys pressed
	mbi.keys_pressed = {}
	mbi.keys_released = {}
	mbi.keys_repeated = {}
	mbi.typed_text_length = 0
	mbi.close_requested = false
	
	mbi.mouse_pressed = {}
	mbi.mouse_released = {}

	
	mbi.mouse_wheel_value = 0
	mbi.mouse_wheel_horizontal_value = 0
	clear_dropped_files()

	event_message:win.MSG

	for win.PeekMessageW(lpMsg = &event_message, hWnd = mbi.window, wMsgFilterMin = 0,wMsgFilterMax = 0,wRemoveMsg = win.PM_REMOVE){
		win.TranslateMessage(lpMsg = &event_message)
		win.DispatchMessageW(lpMsg = &event_message)
	}

	if update_mouse_capture() == false {
		update_mouse_motion(&mbi.mouse_motion, {f32(mbi.mouse_position.x), f32(mbi.mouse_position.y)}, true)
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
