package matchbox

/*
	Input
	=====
	Handles the input mapping

	On 3DS -> Mapes to u32 values

	The button layout for keyboard maps to the button layout
	used by the Citra Emulator

	What's not mapped at this time:
	circle pad
	Home
	Power
	Circle Mod
	GPIO14 --> Never noticed this before; not sure what this is
	Debub --> Probably don't need to map this
*/

import "o3dx/ctru"

Key :: enum u32 {

	// Face Buttons
    A = ctru.KEY_A,
    S = ctru.KEY_B,
    Z = ctru.KEY_X,
    X = ctru.KEY_Y,

    // DPAD
    F = ctru.KEY_DRIGHT,
    H = ctru.KEY_DLEFT,
    T = ctru.KEY_DDOWN,
    G = ctru.KEY_DUP,

	// Shoulder Buttons
    Q = ctru.KEY_L,
    W = ctru.KEY_R,
    _1 = ctru.KEY_ZL,
    _2  = ctru.KEY_ZR,

	// Misc.
	M = ctru.KEY_SELECT,
    N = ctru.KEY_START,
	// Circle Pad
		
	// C-Stick
}

/*Checks if a key is pressed -- :any is temporary using as stub*/
is_key_pressed :: proc(key:Key) -> bool {
	return false
	// return mbi.is_keys_pressed[key]
}

/*Checks if a key is held* -- :any is temporary using as stub*/
is_key_held :: proc(key:Key) -> bool {
	return false
}
