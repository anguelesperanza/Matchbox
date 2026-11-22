#+build freestanding arm32

package matchbox

/*
	Input -- handhelds
	==================
	The keyboard and mouse half of the input API, for the 3DS and the Vita alike. Neither
	has a keyboard or a mouse, so every query answers false or zero, and a game that reads
	them still compiles and runs.

	Not inside `when !VITA` / `when VITA` like the other handheld files: it is the same on
	both, and one copy cannot drift from a second
*/

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

/*Fake: neither handheld has a mouse, so this only stubs out the API*/
Mouse :: enum {
	LEFT,
	RIGHT,
	MIDDLE,
	SIDE_1, // Side button on some mice 
	SIDE_2, // Side button on some mice
}

/*Always {0, 0} on the handhelds*/
get_mouse_position :: proc() -> [2]i32 {
	return {} 
}
/*Always 0 on the handhelds*/
get_mouse_wheel_value :: proc() -> i16 {
	return 0
}

/*Always false on the handhelds*/
is_key_pressed :: proc(key:Key) -> bool {
	return false
}

/*Always false on the handhelds*/
is_key_held :: proc(key:Key) -> bool {
	return false
}

is_key_released :: proc(key:Key) -> bool {
	return false
}

/*Always false on the handhelds*/
is_mouse_pressed :: proc(mouse:Mouse) -> bool {
	return false
}

is_mouse_held :: proc(mouse:Mouse) -> bool {
	return false
}

is_mouse_released :: proc(mouse:Mouse) -> bool {
	return false
}


set_mouse_capture :: proc(){
}
