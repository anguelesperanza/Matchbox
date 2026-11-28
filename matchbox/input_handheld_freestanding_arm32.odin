#+build freestanding arm32

package matchbox

/*
	Input -- handhelds
	==================
	The keyboard and mouse half of the input API, for the 3DS and the Vita alike. Neither
	has a keyboard or a mouse, so every query answers false or zero, and a game that reads
	them still compiles and runs. The mouse's position and buttons are the exception: the
	3DS answers them from the stylus, so each target has its own (input_3ds_ and input_vita_).

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

	// The same names as the PC's keypad, function and punctuation keys, so a game written for the PC builds
	NUMPAD_0,
	NUMPAD_1,
	NUMPAD_2,
	NUMPAD_3,
	NUMPAD_4,
	NUMPAD_5,
	NUMPAD_6,
	NUMPAD_7,
	NUMPAD_8,
	NUMPAD_9,
	MULTIPLY,
	ADD,
	SEPARATOR,
	SUBTRACT,
	DECIMAL,
	DIVIDE,
	KEYPAD_ENTER,
	F1,
	F2,
	F3,
	F4,
	F5,
	F6,
	F7,
	F8,
	F9,
	F10,
	F11,
	F12,
	NUMLOCK,
	SCROLL_LOCK,
	SEMICOLON,
	EQUALS,
	COMMA,
	MINUS,
	PERIOD,
	SLASH,
	GRAVE,
	LEFT_BRACKET,
	BACKSLASH,
	RIGHT_BRACKET,
	APOSTROPHE,
}

/*
	Neither handheld has a mouse. The touch screen is LEFT: the 3DS's stylus and the Vita's front
	panel (input_3ds_ and input_vita_freestanding_arm32.odin). The rest are never down
*/
Mouse :: enum {
	LEFT,
	RIGHT,
	MIDDLE,
	SIDE_1, // Side button on some mice
	SIDE_2, // Side button on some mice
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
is_key_repeated :: proc(key:Key) -> bool {
	return false
}

/*Always empty on the handhelds: there is no keyboard to type on*/
get_typed_text :: proc() -> string {
	return ""
}

/*Always zero on the handhelds*/
get_mouse_wheel_horizontal_value :: proc() -> i16 {
	return 0
}

/*Does nothing on the handhelds: there is no pointer to change*/
set_cursor_shape :: proc(shape:Cursor_Shape) {
}

/*Always "" on the handhelds*/
get_clipboard_text :: proc(allocator := context.temp_allocator) -> string {
	return ""
}

/*Always false on the handhelds*/
set_clipboard_text :: proc(text:string) -> bool {
	return false
}

/*Always empty on the handhelds: nothing can be dropped on a console's screen*/
get_dropped_files :: proc() -> []Dropped_File {
	return nil
}

/*Always 1 on the handhelds: the screen is the screen*/
get_display_scale :: proc() -> f32 {
	return 1
}

/*Always false on the handhelds: there is no window to close (a game quits on START)*/
is_close_requested :: proc() -> bool {
	return false
}

/*Does nothing on the handhelds, so that a game written for the PC builds*/
set_close_confirmation :: proc(enabled:bool = true) {
}

/*Does nothing on the handhelds: the screen has one size*/
set_minimum_window_size :: proc(width:i32, height:i32) {
}

/*There is no window to read on a handheld: no pixels and a zero size, so that a game written for the PC builds*/
read_window_pixels :: proc(allocator := context.allocator) -> (pixels:[]u8, size:[2]i32) {
	return nil, {}
}

/*There is no mouse on a handheld; so that a game written for the PC builds, this does nothing*/
set_mouse_capture :: proc() {
}

release_mouse_capture :: proc() {
}

/*Always false on a handheld*/
is_mouse_captured :: proc() -> bool {
	return false
}
