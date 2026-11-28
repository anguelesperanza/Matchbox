#+build windows

package matchbox

/*
	Input
	=====
	Handles the input mapping

	On windows: Creates an enum of names based on the
	VK (Virtual Keys) that win32 supports, and assigs those
	VK Key values to each value in the enum

	--> Usage requires #sparse keyward as there are gaps in the index
	enum values index
*/

import win "core:sys/windows"

Button :: enum u32 {
	// Misc.
    START,
	SELECT,
	
	// Face Buttons
    FACE_DOWN,
    FACE_RIGHT,
    FACE_LEFT,
    FACE_UP,

    // DPAD
    DPAD_UP,
    DPAD_DOWN,
    DPAD_LEFT,
    DPAD_RIGHT,

	// Shoulder Buttons
    LEFT_SHOULDER,
    RIGHT_SHOULDER,

    // Thumstricks
    LEFT_THUMBSTICK,
    RIGHT_THUMBSTICK,

	// Triggers
    LEFT_TRIGGER,
    RIGHT_TRIGGER,
}

/*
	This doesn't use GameInput as Keyboard check logic was completed
	before GameInput was added to codebase
*/
Key :: enum {
	BACK = win.VK_BACK, 
	TAB = win.VK_TAB, 
	CLEAR = win.VK_CLEAR,
	RETURN = win.VK_RETURN,
	SHIFT = win.VK_SHIFT,
	CONTROL = win.VK_CONTROL,
	MENU = win.VK_MENU,
	PAUSE = win.VK_PAUSE,
	CAPITAL = win.VK_CAPITAL,
	KANA = win.VK_KANA,
	HANGUEL = win.VK_HANGEUL,
	HANGUL = win.VK_HANGUL,
	IME_ON = win.VK_IME_ON,
	JUNJA = win.VK_JUNJA,
	FINAL = win.VK_FINAL,
	HANJA = win.VK_HANJA,
	KANJI = win.VK_KANJI,
	IME_OFF = win.VK_IME_OFF,
	ESCAPE = win.VK_ESCAPE,
	CONVERT = win.VK_CONVERT,
	NONCONVERT = win.VK_NONCONVERT,
	ACCEPT = win.VK_ACCEPT,
	MODECHANGE = win.VK_MODECHANGE,
	SPACE = win.VK_SPACE,
	PRIOR = win.VK_PRIOR,
	NEXT = win.VK_NEXT,
	END = win.VK_END,
	HOME = win.VK_HOME,
	LEFT = win.VK_LEFT,
	UP = win.VK_UP,
	RIGHT = win.VK_RIGHT,
	DOWN = win.VK_DOWN,
	SELECT = win.VK_SELECT,
	PRINT = win.VK_PRINT,
	EXECUTE = win.VK_EXECUTE,
	SNAPSHOT = win.VK_SNAPSHOT,
	INSERT = win.VK_INSERT,
	DELETE = win.VK_DELETE,
	HELP = win.VK_HELP,
    _0 = win.VK_0,
    _1 = win.VK_1,
    _2 = win.VK_2,
    _3 = win.VK_3,
    _4 = win.VK_4,
    _5 = win.VK_5,
    _6 = win.VK_6,
    _7 = win.VK_7,
    _8 = win.VK_8,
    _9 = win.VK_9,
	A = win.VK_A,
	B = win.VK_B,
	C = win.VK_C,
	D = win.VK_D,
	E = win.VK_E,
	F = win.VK_F,
	G = win.VK_G,
	H = win.VK_H,
	I = win.VK_I,
	J = win.VK_J,
	K = win.VK_K,
	L = win.VK_L,
	M = win.VK_M,
	N = win.VK_N,
	O = win.VK_O,
	P = win.VK_P,
	Q = win.VK_Q,
	R = win.VK_R,
	S = win.VK_S,
	T = win.VK_T,
	U = win.VK_U,
	V = win.VK_V,
	W = win.VK_W,
	X = win.VK_X,
	Y = win.VK_Y,
	Z = win.VK_Z,

	// The keypad. Numbers only arrive with NumLock on; with it off Windows sends the arrows, Home, End and so on instead
	NUMPAD_0 = win.VK_NUMPAD0,
	NUMPAD_1 = win.VK_NUMPAD1,
	NUMPAD_2 = win.VK_NUMPAD2,
	NUMPAD_3 = win.VK_NUMPAD3,
	NUMPAD_4 = win.VK_NUMPAD4,
	NUMPAD_5 = win.VK_NUMPAD5,
	NUMPAD_6 = win.VK_NUMPAD6,
	NUMPAD_7 = win.VK_NUMPAD7,
	NUMPAD_8 = win.VK_NUMPAD8,
	NUMPAD_9 = win.VK_NUMPAD9,
	MULTIPLY = win.VK_MULTIPLY,
	ADD = win.VK_ADD,
	SEPARATOR = win.VK_SEPARATOR,
	SUBTRACT = win.VK_SUBTRACT,
	DECIMAL = win.VK_DECIMAL,
	DIVIDE = win.VK_DIVIDE,
	// Windows has no virtual key for the keypad's Enter: it is RETURN with the extended-key bit set. RETURN answers for both
	// Enter keys, and KEYPAD_ENTER only for the keypad's, so a game that cares which one can tell. The value is an unused one
	KEYPAD_ENTER = 0x0E,

	F1 = win.VK_F1,
	F2 = win.VK_F2,
	F3 = win.VK_F3,
	F4 = win.VK_F4,
	F5 = win.VK_F5,
	F6 = win.VK_F6,
	F7 = win.VK_F7,
	F8 = win.VK_F8,
	F9 = win.VK_F9,
	F10 = win.VK_F10,
	F11 = win.VK_F11,
	F12 = win.VK_F12,
	NUMLOCK = win.VK_NUMLOCK,
	SCROLL_LOCK = win.VK_SCROLL,

	// The punctuation keys, named for the character on a US layout. Windows reports the key's place, not what it types, so on
	// another layout these are the same physical keys with other characters (use the typed text for what was written)
	SEMICOLON = win.VK_OEM_1,
	EQUALS = win.VK_OEM_PLUS,
	COMMA = win.VK_OEM_COMMA,
	MINUS = win.VK_OEM_MINUS,
	PERIOD = win.VK_OEM_PERIOD,
	SLASH = win.VK_OEM_2,
	GRAVE = win.VK_OEM_3,
	LEFT_BRACKET = win.VK_OEM_4,
	BACKSLASH = win.VK_OEM_5,
	RIGHT_BRACKET = win.VK_OEM_6,
	APOSTROPHE = win.VK_OEM_7,
	
}

Mouse :: enum {
	LEFT,
	RIGHT,
	MIDDLE,
	SIDE_1, // Side button on some mice 
	SIDE_2, // Side button on some mice
}

/*

	gb -> value from the Gamepad_Button enum
	id -> This is supposed to track the gamepad ID;
		  however using GameInput so that functionality isn't implemented in
		  Matchbox yet -- Just grabbing first registered controller
*/
is_gamepad_pressed :: proc (button:Button, id:i32 = 0) -> bool {
	return button in mbi.gamepad_pressed
}
is_gamepad_held :: proc (button:Button, id:i32 = 0) -> bool {
	return button in mbi.gamepad_held
}
is_gamepad_released :: proc (button:Button, id:i32 = 0) -> bool {
	return button in mbi.gamepad_released
}

/*Returns the x, y values on a range of -1-1 for a joystick*/
get_thumbstick_value :: proc(thumbstick:Button) -> (axis:[2]f32) {

	#partial switch thumbstick {
		case .LEFT_THUMBSTICK:
			return mbi.left_thumbstick_axis
		case .RIGHT_THUMBSTICK:
			return mbi.right_thumbstick_axis
	}
	return {}
}


/*
	Behaves differenlty depending on the Platform
	On Windows: The value is tracked on a range of 0 - 1 (not pressed to full pressed)
	On 3DS: Value is tracked as either 0 or 1 (not pressed or pressed) as the 3DS does not have analoge triggers

	As such, this behavior is slightly different depending on the target platform
*/
get_trigger_value :: proc(trigger:Button) -> f32 {
	
	#partial switch trigger {
		case .LEFT_TRIGGER:
			return mbi.left_trigger_value
		case .RIGHT_TRIGGER:
			return mbi.right_trigger_value
	}
	return 0
}

/*Checks if a key is pressed*/
is_key_pressed :: proc(key:Key) -> bool {
	return mbi.keys_pressed[key]
}

/*Checks if a key is held*/
is_key_held :: proc(key:Key) -> bool {
	return mbi.keys_held[key]
}

is_key_released :: proc(key:Key) -> bool {
	return mbi.keys_released[key]
}

/*
	Checks if a key went down this frame or is auto-repeating while it is held. `is_key_pressed` is true once per press (a
	shortcut such as Ctrl+Z fires once however long it is held); this one also fires at the keyboard's repeat rate, which is
	what moving a text caret or deleting with backspace wants
*/
is_key_repeated :: proc(key:Key) -> bool {
	return mbi.keys_repeated[key]
}

/*
	The text typed this frame, as UTF-8, for filling a text field. It is what the keyboard layout produced (so shifted
	letters, other layouts and dead keys come out right), not key presses. Control characters are left out: Backspace,
	Tab and Enter arrive as keys. Valid until the next poll_events. If more than MAX_TEXT_INPUT bytes are typed in one
	frame the rest are dropped
*/
get_typed_text :: proc() -> string {
	return string(mbi.typed_text[:mbi.typed_text_length])
}

/*
	When on, the window's close button (and Alt+F4, the taskbar) no longer closes the window: it is reported by
	is_close_requested and the game decides, usually by asking "save changes?" and then calling stop_running. Off by
	default, which is how every game closed before this existed
*/
set_close_confirmation :: proc(enabled:bool = true) {
	mbi.close_confirmation = enabled
}

/*
	Whether the user asked to close the window this frame (its close button, Alt+F4, the taskbar). Only ever true after
	set_close_confirmation, and then the window is not closed until the game calls stop_running. Resets every frame
*/
is_close_requested :: proc() -> bool {
	return mbi.close_requested
}

get_mouse_position :: proc() -> [2]i32 {
	return mbi.mouse_position
}
/*
	The wheel's turn this frame, in steps of 120 (one notch), positive away from the player. Every message of the frame is
	added up, so a quick spin is not lost to the last one
*/
get_mouse_wheel_value :: proc() -> i16 {
	return mbi.mouse_wheel_value
}

/*The tilt wheel's or touchpad's sideways scroll this frame, in the same steps, positive to the right. Zero on most mice*/
get_mouse_wheel_horizontal_value :: proc() -> i16 {
	return mbi.mouse_wheel_horizontal_value
}

/*
	Sets the picture the pointer has over the window, and keeps it until it is set again (set .ARROW to put it back). Only
	over the window's own area: the title bar and borders are Windows'. Leaves a locked mouse (set_mouse_capture) that has
	hidden the pointer alone
*/
set_cursor_shape :: proc(shape:Cursor_Shape) {
	mbi.cursor_shape = shape
	cursor := mbi.cursors[shape]
	// Now, and not only at the next WM_SETCURSOR, which only comes when the pointer moves
	if cursor != nil && mbi.mouse_capture.applied == false do win.SetCursor(cursor)
}

/*Loads the system pointers set_cursor_shape picks from; once, at init*/
@(private)
load_cursors :: proc() {
	mbi.cursors[.ARROW] = win.LoadCursorA(nil, win.IDC_ARROW)
	mbi.cursors[.TEXT] = win.LoadCursorA(nil, win.IDC_IBEAM)
	mbi.cursors[.RESIZE_HORIZONTAL] = win.LoadCursorA(nil, win.IDC_SIZEWE)
	mbi.cursors[.RESIZE_VERTICAL] = win.LoadCursorA(nil, win.IDC_SIZENS)
	mbi.cursors[.HAND] = win.LoadCursorA(nil, win.IDC_HAND)
	mbi.cursors[.CROSSHAIR] = win.LoadCursorA(nil, win.IDC_CROSS)
}

/*
	The text on the clipboard, or "" when there is none (or it is not text). UTF-8, in `allocator`, which is the temp
	allocator unless given another, so use it this frame or copy it
*/
get_clipboard_text :: proc(allocator := context.temp_allocator) -> string {
	if win.OpenClipboard(mbi.window) == false do return ""
	defer win.CloseClipboard()

	handle := win.GetClipboardData(win.CF_UNICODETEXT)
	if handle == nil do return ""
	memory := win.GlobalLock(win.HGLOBAL(handle))
	if memory == nil do return ""
	defer win.GlobalUnlock(win.HGLOBAL(handle))

	text, error := win.wstring_to_utf8(win.wstring(memory), -1, allocator)
	if error != nil do return ""
	return text
}

/*Puts text on the clipboard, replacing what was there. False if Windows would not take it (another program has it open)*/
set_clipboard_text :: proc(text:string) -> bool {
	units := win.utf8_to_utf16(text, context.temp_allocator)
	bytes := (len(units) + 1) * size_of(u16) // the terminating zero the format wants
	memory := win.GlobalAlloc(win.GMEM_MOVEABLE, uint(bytes))
	if memory == nil do return false

	destination := ([^]u16)(win.GlobalLock(win.HGLOBAL(memory)))
	if destination == nil {
		win.GlobalFree(memory)
		return false
	}
	copy(destination[:len(units)], units)
	destination[len(units)] = 0
	win.GlobalUnlock(win.HGLOBAL(memory))

	if win.OpenClipboard(mbi.window) == false {
		win.GlobalFree(memory)
		return false
	}
	defer win.CloseClipboard()
	win.EmptyClipboard()
	// On success the clipboard owns the memory; on failure it is still ours to free
	if win.SetClipboardData(win.CF_UNICODETEXT, win.HANDLE(memory)) == nil {
		win.GlobalFree(memory)
		return false
	}
	return true
}

/*
	The files dropped on the window this frame, each with where in the window it landed (pixels, top left, as
	get_mouse_position). Empty on most frames. The paths are valid until the next poll_events: copy one to keep it
*/
get_dropped_files :: proc() -> []Dropped_File {
	return mbi.dropped_files[:]
}

/*
	How much bigger than 100% the window's monitor is scaled: 1 at 100%, 1.25 at 125%, 2 at 200%. Matchbox draws in real
	pixels, so a UI that wants to stay the same physical size multiplies its sizes by this
*/
get_display_scale :: proc() -> f32 {
	dots_per_inch := win.GetDpiForWindow(mbi.window)
	if dots_per_inch == 0 do return 1
	return f32(dots_per_inch) / 96
}

is_mouse_pressed :: proc(mouse:Mouse) -> bool {
	return mbi.mouse_pressed[mouse]
}
is_mouse_held :: proc(mouse:Mouse) -> bool {
	return mbi.mouse_held[mouse]
}
is_mouse_released :: proc(mouse:Mouse) -> bool {
	return mbi.mouse_released[mouse]
}

/*
	What set_mouse_capture has done. `active` is what the game asked for; `applied` is whether the OS has the cursor
	confined and hidden right now, which it does not while the window is in the background: the cursor is the player's
	to take back, and it is locked again by itself when the window returns
*/
Mouse_Capture :: struct {
	active:bool,
	applied:bool,
}

/*
	Locks the mouse to the window for looking around: the cursor is hidden, kept inside the window and put back in the
	middle every frame, so `get_mouse_delta` keeps measuring however far the hand moves and a camera never runs out of
	desk or screen. While captured, get_camera_look_input turns the view without a button held. Leaving the window (alt-tab)
	gives the cursor back and capturing again is automatic when it returns. release_mouse_capture undoes this, and a menu
	should call it. Handhelds have no mouse, so this does nothing there
*/
set_mouse_capture :: proc() {
	mbi.mouse_capture.active = true
	apply_mouse_capture()
}

/*Gives the cursor back: visible, free to leave the window*/
release_mouse_capture :: proc() {
	mbi.mouse_capture.active = false
	undo_mouse_capture()
}

/*Whether the game has asked for the mouse to be locked and not yet released*/
is_mouse_captured :: proc() -> bool {
	return mbi.mouse_capture.active
}

/*Confines the cursor to the window's drawing area and returns the middle of it in screen pixels, where it is kept*/
@(private)
confine_cursor_to_window :: proc() -> win.POINT {
	client:win.RECT
	win.GetClientRect(mbi.window, &client)

	top_left := win.POINT{client.left, client.top}
	bottom_right := win.POINT{client.right, client.bottom}
	win.ClientToScreen(mbi.window, &top_left)
	win.ClientToScreen(mbi.window, &bottom_right)
	area := win.RECT{top_left.x, top_left.y, bottom_right.x, bottom_right.y}
	win.ClipCursor(&area)

	return win.POINT{(top_left.x + bottom_right.x) / 2, (top_left.y + bottom_right.y) / 2}
}

@(private)
apply_mouse_capture :: proc() {
	capture := &mbi.mouse_capture
	if capture.active == false || capture.applied do return
	if win.GetForegroundWindow() != mbi.window do return

	centre := confine_cursor_to_window()
	win.SetCursorPos(centre.x, centre.y)
	win.ShowCursor(win.FALSE) // a counter, not a switch: balanced by the one in undo_mouse_capture
	capture.applied = true
	mbi.mouse_motion.tracking = false // the cursor was just moved by us: that is not a look
}

@(private)
undo_mouse_capture :: proc() {
	capture := &mbi.mouse_capture
	if capture.applied == false do return

	win.ClipCursor(nil)
	win.ShowCursor(win.TRUE)
	capture.applied = false
	mbi.mouse_motion.tracking = false
}

/*
	Called by poll_events. While captured the look is how far the cursor is from the middle of the window, which is then put
	back, rather than the difference between two positions: a position stops changing at the edge of the screen and this
	does not. Returns true when it has set `mbi.mouse_motion` itself
*/
@(private)
update_mouse_capture :: proc() -> bool {
	capture := &mbi.mouse_capture
	if capture.active == false || win.GetForegroundWindow() != mbi.window {
		undo_mouse_capture()
		return false
	}
	if capture.applied == false {
		apply_mouse_capture()
		mbi.mouse_motion = {}
		return true
	}

	centre := confine_cursor_to_window() // again each frame: the window may have moved or been resized
	cursor:win.POINT
	win.GetCursorPos(&cursor)
	mbi.mouse_motion.delta = {f32(cursor.x - centre.x), f32(cursor.y - centre.y)}
	mbi.mouse_motion.tracking = true
	win.SetCursorPos(centre.x, centre.y)
	return true
}

/*Where the mouse is pointing in world units, as seen by `camera`. Use for clicking things in the world*/
calculate_mouse_world_position :: proc(camera:Camera) -> [2]f32 {
	mouse := get_mouse_position()
	// In the pixels the game draws in: the window's, or the internal resolution's (set_internal_resolution)
	return calculate_screen_to_world_2d(camera, calculate_pointer_draw_position({f32(mouse.x), f32(mouse.y)}), get_pointer_draw_size())
}
