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
    L = ctru.KEY_L,
    R = ctru.KEY_R,
    ZL = ctru.KEY_ZL,
    ZR  = ctru.KEY_ZR,

	// Misc.
    START = ctru.KEY_START,
	SELECT = ctru.KEY_SELECT,
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


/*
	On the 3DS this will check if a gamepad button is pressed
	gb -> value from the Gamepad_Button enum
	id -> Useless; used to track the gamepad id however there's only
		  one gamepad on the 3DS, so it's default is 0
*/
is_gamepad_pressed :: proc (button:Button, id:i32 = 0) -> bool {
	return mbi.is_button_pressed[button]
}

/*On the 3DS this will always return false*/
is_key_pressed :: proc(key:Key) -> bool {
	return false
}

/*On the 3DS this will always return false*/
is_key_held :: proc(key:Key) -> bool {
	return false
}
