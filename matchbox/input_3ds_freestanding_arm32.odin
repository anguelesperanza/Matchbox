#+build freestanding arm32

package matchbox

/*
	Input
	=====
	Handles the input mapping

	On 3DS -> Mapes to u32 values

	There are two struct: Key and Button:
	
	Key -> does nothing. It's only there so the application
	doesn't crash when compiling. The related is_key_* procs
	all return false

	Button -> This is the struct that the 3DS uses
	This is where the buttons are mapped for the 3DS

*/

import "o3dx/ctru"

Button :: enum u32 {

	// Face Buttons
    FACE_UP = ctru.KEY_X,
    FACE_DOWN = ctru.KEY_B,
    FACE_LEFT = ctru.KEY_Y,
    FACE_RIGHT = ctru.KEY_A,

    // DPAD
    DPAD_UP = ctru.KEY_DUP,
    DPAD_DOWN = ctru.KEY_DDOWN,
    DPAD_LEFT = ctru.KEY_DLEFT,
    DPAD_RIGHT = ctru.KEY_DRIGHT,

	// Shoulder Buttons
    LEFT_SHOULDER = ctru.KEY_L,
    RIGHT_SHOULDER = ctru.KEY_R,
    LEFT_TRIGGER = ctru.KEY_ZL,
    RIGHT_TRIGGER  = ctru.KEY_ZR,

	// Misc.
    START = ctru.KEY_START,
	SELECT = ctru.KEY_SELECT,

	// Fake -- While these exist (circle pad and cstick), these are for buttons you can press in (R3/L3).
	// On the 3DS, that doesn't exist
	LEFT_THUMBSTICK = 101,
	RIGHT_THUMBSTICK = 102,

	
	// Circle Pad
		
	// C-Stick
}

Key :: enum {
	BACK, 
	TAB, 
	CLEAR,
	RETURN,
	SHIFT,
	CONTROL,
	MENU,
	PAUSE,
	CAPITAL,
	KANA,
	HANGUEL,
	HANGUL,
	IME_ON,
	JUNJA,
	FINAL,
	HANJA,
	KANJI,
	IME_OFF,
	ESCAPE,
	CONVERT,
	NONCONVERT,
	ACCEPT,
	MODECHANGE,
	SPACE,
	PRIOR,
	NEXT,
	END,
	HOME,
	LEFT,
	UP,
	RIGHT,
	DOWN,
	SELECT,
	PRINT,
	EXECUTE,
	SNAPSHOT,
	INSERT,
	DELETE,
	HELP,
    _0,
    _1,
    _2,
    _3,
    _4,
    _5,
    _6,
    _7,
    _8,
    _9,
	A,
	B,
	C,
	D,
	E,
	F,
	G,
	H,
	I,
	J,
	K,
	L,
	M,
	N,
	O,
	P,
	Q,
	R,
	S,
	T,
	U,
	V,
	W,
	X,
	Y,
	Z,
}

/*Fake: The 3DS does not have a mouse so this is just to stub out the api*/
Mouse :: enum {
	LEFT,
	RIGHT,
	MIDDLE,
	SIDE_1, // Side button on some mice 
	SIDE_2, // Side button on some mice
}

/*
	On the 3DS this will check if a gamepad button is pressed
	gb -> value from the Gamepad_Button enum
	id -> Useless; used to track the gamepad id however there's only
		  one gamepad on the 3DS, so it's default is 0
*/
is_gamepad_pressed :: proc (button:Button, id:i32 = 0) -> bool {
	return mbi.is_button_pressed[button]
}

/*Returns the x, y values on a range of 0-1 for a joystick*/
get_thumbstick_value :: proc(thumstick:Button) -> (axis:[2]f32) {

	#partial switch thumstick {
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
	if mbi.is_button_pressed[trigger] == true do return 1
	return 0
}

/*On the 3DS this will always return false*/
get_mouse_position :: proc() -> [2]i32 {
	return
}
/*On the 3DS this will always return false*/
get_mouse_wheel_value :: proc() -> [2]i16 {
	return
}

/*On the 3DS this will always return false*/
is_key_pressed :: proc(key:Key) -> bool {
	return false
}

/*On the 3DS this will always return false*/
is_key_held :: proc(key:Key) -> bool {
	return false
}

/*On the 3DS this will always return false*/
is_mouse_pressed :: proc(mouse:Mouse) -> bool {
	return false
}
