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
	
}

/*Checks if a key is pressed*/
is_key_pressed :: proc(key:Key) -> bool {
	return mbi.is_keys_pressed[key]
}

/*Checks if a key is held*/
is_key_held :: proc(key:Key) -> bool {
	return false
}
