#+build windows

package matchbox

import "base:intrinsics"
import "core:strings"
import "core:sync"
import "core:testing"
import win "core:sys/windows"

/*
	Keyboard input, close requests and typed text, driven by sending the window procedure the same messages Windows
	would (window_event_proc takes the window handle but only reads `mbi`, so a nil one is enough). They write to the one
	shared `mbi`, so each takes the lock from bottom_screen_windows_test.odin and puts back what it touched
*/

@(private = "file")
Saved_Input :: struct {
	keys_pressed:         #sparse [Key]bool,
	keys_released:        #sparse [Key]bool,
	keys_held:            #sparse [Key]bool,
	keys_repeated:        #sparse [Key]bool,
	typed_text:           [MAX_TEXT_INPUT]u8,
	typed_text_length:    int,
	typed_high_surrogate: u16,
	close_confirmation:   bool,
	close_requested:      bool,
	is_running:           bool,
	mouse_held:           [Mouse]bool,
	mouse_wheel_value:    i16,
	mouse_wheel_horizontal_value: i16,
	cursor_shape:         Cursor_Shape,
	cursors:              [Cursor_Shape]win.HCURSOR,
	window:               win.HWND,
}

@(private = "file")
save_input :: proc() -> Saved_Input {
	sync.mutex_lock(&mbi_lock)
	saved := Saved_Input{
		mbi.keys_pressed, mbi.keys_released, mbi.keys_held, mbi.keys_repeated, mbi.typed_text, mbi.typed_text_length,
		mbi.typed_high_surrogate, mbi.close_confirmation, mbi.close_requested, mbi.is_running,
		mbi.mouse_held, mbi.mouse_wheel_value, mbi.mouse_wheel_horizontal_value, mbi.cursor_shape, mbi.cursors, mbi.window,
	}
	mbi.keys_pressed = {}
	mbi.keys_released = {}
	mbi.keys_held = {}
	mbi.keys_repeated = {}
	mbi.typed_text_length = 0
	mbi.typed_high_surrogate = 0
	mbi.close_confirmation = false
	mbi.close_requested = false
	mbi.is_running = true
	mbi.mouse_held = {}
	mbi.mouse_wheel_value = 0
	mbi.mouse_wheel_horizontal_value = 0
	mbi.cursor_shape = .ARROW
	return saved
}

@(private = "file")
restore_input :: proc(saved: Saved_Input) {
	mbi.keys_pressed = saved.keys_pressed
	mbi.keys_released = saved.keys_released
	mbi.keys_held = saved.keys_held
	mbi.keys_repeated = saved.keys_repeated
	mbi.typed_text = saved.typed_text
	mbi.typed_text_length = saved.typed_text_length
	mbi.typed_high_surrogate = saved.typed_high_surrogate
	mbi.close_confirmation = saved.close_confirmation
	mbi.close_requested = saved.close_requested
	mbi.is_running = saved.is_running
	mbi.mouse_held = saved.mouse_held
	mbi.mouse_wheel_value = saved.mouse_wheel_value
	mbi.mouse_wheel_horizontal_value = saved.mouse_wheel_horizontal_value
	mbi.cursor_shape = saved.cursor_shape
	mbi.cursors = saved.cursors
	mbi.window = saved.window
	clear_dropped_files()
	sync.mutex_unlock(&mbi_lock)
}

// lParam bits: 30 is "the key was already down" (auto-repeat), 24 the extended-key flag
@(private = "file")
REPEAT_BIT :: win.LPARAM(1) << 30
@(private = "file")
EXTENDED_BIT :: win.LPARAM(1) << 24

@(private = "file")
send_key_down :: proc(virtual_key: int, lparam: win.LPARAM = 0) {
	window_event_proc(nil, win.WM_KEYDOWN, win.WPARAM(virtual_key), lparam)
}

@(private = "file")
send_key_up :: proc(virtual_key: int, lparam: win.LPARAM = 0) {
	window_event_proc(nil, win.WM_KEYUP, win.WPARAM(virtual_key), lparam)
}

@(private = "file")
send_character :: proc(unit: int) {
	window_event_proc(nil, win.WM_CHAR, win.WPARAM(unit), 0)
}

// What poll_events does at the start of a frame, without the window it also pumps
@(private = "file")
start_frame :: proc() {
	mbi.keys_pressed = {}
	mbi.keys_released = {}
	mbi.keys_repeated = {}
	mbi.typed_text_length = 0
	mbi.close_requested = false
}

@(test)
a_held_key_is_pressed_once_and_repeated_every_time :: proc(t: ^testing.T) {
	saved := save_input()
	defer restore_input(saved)

	send_key_down(win.VK_Z)
	testing.expect(t, is_key_pressed(.Z))
	testing.expect(t, is_key_repeated(.Z))
	testing.expect(t, is_key_held(.Z))

	// The keyboard's auto-repeat: bit 30 says the key was already down
	start_frame()
	send_key_down(win.VK_Z, REPEAT_BIT)
	testing.expect(t, is_key_pressed(.Z) == false, "an auto-repeat must not count as a new press")
	testing.expect(t, is_key_repeated(.Z))
	testing.expect(t, is_key_held(.Z))

	start_frame()
	send_key_up(win.VK_Z)
	testing.expect(t, is_key_released(.Z))
	testing.expect(t, is_key_held(.Z) == false)
	testing.expect(t, is_key_repeated(.Z) == false)
}

@(test)
the_keys_the_editor_needs_are_there :: proc(t: ^testing.T) {
	saved := save_input()
	defer restore_input(saved)

	Case :: struct {
		virtual_key: int,
		key:         Key,
	}
	cases := [?]Case {
		{win.VK_OEM_PLUS, .EQUALS},
		{win.VK_OEM_MINUS, .MINUS},
		{win.VK_NUMPAD0, .NUMPAD_0},
		{win.VK_NUMPAD9, .NUMPAD_9},
		{win.VK_ADD, .ADD},
		{win.VK_SUBTRACT, .SUBTRACT},
		{win.VK_F1, .F1},
		{win.VK_F12, .F12},
		{win.VK_OEM_3, .GRAVE},
		{win.VK_CONTROL, .CONTROL},
		{win.VK_SHIFT, .SHIFT},
	}
	for entry in cases {
		start_frame()
		send_key_down(entry.virtual_key)
		testing.expectf(t, is_key_pressed(entry.key), "virtual key 0x%X did not press %v", entry.virtual_key, entry.key)
		send_key_up(entry.virtual_key)
	}
}

@(test)
a_virtual_key_with_no_name_is_ignored :: proc(t: ^testing.T) {
	saved := save_input()
	defer restore_input(saved)

	// 0xE7 is VK_PACKET, which Windows sends for synthesised Unicode input: Key has no name for it
	send_key_down(0xE7)
	for key in Key {
		testing.expectf(t, is_key_pressed(key) == false, "%v pressed by an unnamed key", key)
	}
}

@(test)
the_keypads_enter_is_told_from_the_main_one :: proc(t: ^testing.T) {
	saved := save_input()
	defer restore_input(saved)

	send_key_down(win.VK_RETURN)
	testing.expect(t, is_key_pressed(.RETURN))
	testing.expect(t, is_key_pressed(.KEYPAD_ENTER) == false)
	send_key_up(win.VK_RETURN)

	start_frame()
	send_key_down(win.VK_RETURN, EXTENDED_BIT)
	testing.expect(t, is_key_pressed(.KEYPAD_ENTER))
	testing.expect(t, is_key_pressed(.RETURN), "RETURN answers for both Enter keys")
	testing.expect(t, is_key_held(.RETURN))
	send_key_up(win.VK_RETURN, EXTENDED_BIT)
	testing.expect(t, is_key_held(.RETURN) == false)
	testing.expect(t, is_key_held(.KEYPAD_ENTER) == false)
}

@(test)
typed_text_is_what_the_layout_produced :: proc(t: ^testing.T) {
	saved := save_input()
	defer restore_input(saved)

	for unit in "aB 7é" {
		send_character(int(unit))
	}
	testing.expect_value(t, get_typed_text(), "aB 7é")

	// A new frame starts empty
	start_frame()
	testing.expect_value(t, get_typed_text(), "")
}

@(test)
control_characters_are_not_text :: proc(t: ^testing.T) {
	saved := save_input()
	defer restore_input(saved)

	// Backspace, Tab, Enter, Escape, Ctrl+Z and Delete all come through WM_CHAR too; they are keys, not text
	controls := [?]int{0x08, 0x09, 0x0D, 0x1B, 0x1A, 0x7F}
	for unit in controls {
		send_character(unit)
	}
	send_character('x')
	testing.expect_value(t, get_typed_text(), "x")
}

@(test)
a_character_outside_the_basic_plane_arrives_as_two_units_and_leaves_as_one :: proc(t: ^testing.T) {
	saved := save_input()
	defer restore_input(saved)

	// U+1F600 is the UTF-16 pair D83D DE00
	send_character(0xD83D)
	testing.expect_value(t, get_typed_text(), "")
	send_character(0xDE00)
	testing.expect_value(t, get_typed_text(), "\U0001F600")

	// A first half that is never finished does not leak into the next character, and a second half on its own is dropped
	start_frame()
	send_character(0xD83D)
	send_character('a')
	send_character(0xDE00)
	testing.expect_value(t, get_typed_text(), "a")
}

@(test)
a_full_buffer_drops_whole_characters :: proc(t: ^testing.T) {
	saved := save_input()
	defer restore_input(saved)

	for _ in 0 ..< MAX_TEXT_INPUT - 1 {
		send_character('a')
	}
	// One byte of room is left: a two-byte character must be dropped whole, not cut in the middle
	send_character(0x00E9)
	testing.expect_value(t, len(get_typed_text()), MAX_TEXT_INPUT - 1)
	testing.expect(t, strings.count(get_typed_text(), "a") == MAX_TEXT_INPUT - 1)
	send_character('b')
	testing.expect_value(t, len(get_typed_text()), MAX_TEXT_INPUT)
}

@(test)
the_close_button_is_held_back_only_when_asked :: proc(t: ^testing.T) {
	saved := save_input()
	defer restore_input(saved)

	// Not asked: nothing to report (the default procedure then destroys the window, as it always did)
	window_event_proc(nil, win.WM_CLOSE, 0, 0)
	testing.expect(t, is_close_requested() == false)

	set_close_confirmation()
	result := window_event_proc(nil, win.WM_CLOSE, 0, 0)
	testing.expect(t, is_close_requested())
	testing.expect_value(t, result, 0)
	testing.expect(t, is_running(), "asking must not stop the game by itself")

	start_frame()
	testing.expect(t, is_close_requested() == false, "the request lasts one frame")
}

// A window that exists only so the calls that need one (SetCapture, GetDpiForWindow) have something real to talk to
@(private = "file")
create_test_window :: proc() -> win.HWND {
	return win.CreateWindowExW(0, win.L("STATIC"), nil, 0, 0, 0, 16, 16, nil, nil, nil, nil)
}

// The wheel's delta is the high word of wParam, signed
@(private = "file")
wheel_wparam :: proc(delta: i16) -> win.WPARAM {
	return win.WPARAM(u32(transmute(u16)delta) << 16)
}

@(test)
a_frames_wheel_turns_add_up_and_stop_at_the_ends :: proc(t: ^testing.T) {
	saved := save_input()
	defer restore_input(saved)

	// The wheel's delta is the high word of wParam: one notch is 120, signed
	notch := wheel_wparam(120)
	back := wheel_wparam(-120)
	window_event_proc(nil, win.WM_MOUSEWHEEL, notch, 0)
	window_event_proc(nil, win.WM_MOUSEWHEEL, notch, 0)
	window_event_proc(nil, win.WM_MOUSEWHEEL, back, 0)
	testing.expect_value(t, get_mouse_wheel_value(), 120)

	window_event_proc(nil, win.WM_MOUSEHWHEEL, notch, 0)
	window_event_proc(nil, win.WM_MOUSEHWHEEL, notch, 0)
	testing.expect_value(t, get_mouse_wheel_horizontal_value(), 240)

	// A very long spin stops at the top of an i16 and does not wrap round to a large turn the other way
	mbi.mouse_wheel_value = max(i16) - 50
	window_event_proc(nil, win.WM_MOUSEWHEEL, notch, 0)
	testing.expect_value(t, get_mouse_wheel_value(), max(i16))
}

@(test)
the_window_holds_the_pointer_while_a_button_is_down :: proc(t: ^testing.T) {
	saved := save_input()
	defer restore_input(saved)
	window := create_test_window()
	defer win.DestroyWindow(window)

	// A drag that leaves the window keeps getting its moves and its release only if the window has the pointer
	window_event_proc(window, win.WM_LBUTTONDOWN, 0, 0)
	testing.expect(t, win.GetCapture() == window, "a button down should capture the pointer")

	// A second button joins the first, and letting go of one of them is not the end of the drag
	window_event_proc(window, win.WM_RBUTTONDOWN, 0, 0)
	window_event_proc(window, win.WM_LBUTTONUP, 0, 0)
	testing.expect(t, win.GetCapture() == window, "one button still down: the pointer is still held")

	window_event_proc(window, win.WM_RBUTTONUP, 0, 0)
	testing.expect(t, win.GetCapture() == nil, "the last release gives the pointer back")
	testing.expect(t, is_mouse_held(.LEFT) == false && is_mouse_held(.RIGHT) == false)
}

@(test)
losing_focus_gives_the_pointer_back :: proc(t: ^testing.T) {
	saved := save_input()
	defer restore_input(saved)
	window := create_test_window()
	defer win.DestroyWindow(window)

	window_event_proc(window, win.WM_LBUTTONDOWN, 0, 0)
	window_event_proc(window, win.WM_KILLFOCUS, 0, 0)
	testing.expect(t, win.GetCapture() == nil)
	testing.expect(t, is_mouse_held(.LEFT) == false, "a button held when focus left must not stay held")
}

@(test)
the_chosen_cursor_shows_over_the_window_only :: proc(t: ^testing.T) {
	saved := save_input()
	defer restore_input(saved)
	load_cursors()

	set_cursor_shape(.TEXT)
	testing.expect(t, win.GetCursor() == mbi.cursors[.TEXT], "the pointer should change at once, not on the next move")
	testing.expect(t, mbi.cursors[.TEXT] != mbi.cursors[.ARROW], "the shapes should be different pointers")

	// Windows asks which cursor to show for every move; over the client area the answer is the chosen one and "handled"
	set_cursor_shape(.RESIZE_HORIZONTAL)
	client := win.LPARAM(win.HTCLIENT)
	win.SetCursor(mbi.cursors[.ARROW]) // as if Windows had put the default back, so only the message can set it
	testing.expect_value(t, window_event_proc(nil, win.WM_SETCURSOR, 0, client), 1)
	testing.expect(t, win.GetCursor() == mbi.cursors[.RESIZE_HORIZONTAL])

	// With no pointers loaded (before init) the message is left to Windows and nothing is set
	mbi.cursors = {}
	testing.expect(t, window_event_proc(nil, win.WM_SETCURSOR, 0, client) != 1)
	set_cursor_shape(.ARROW)
}

@(test)
text_goes_to_the_clipboard_and_comes_back :: proc(t: ^testing.T) {
	saved := save_input()
	defer restore_input(saved)
	window := create_test_window()
	defer win.DestroyWindow(window)
	mbi.window = window

	// Keep what the person had copied (text only: another kind of clipboard content is not put back)
	before := strings.clone(get_clipboard_text(), context.temp_allocator)
	defer if before != "" do set_clipboard_text(before)

	words := "caf\u00e9 \U0001F600 and a second line\r\nof text"
	if !testing.expect(t, set_clipboard_text(words), "the clipboard would not take the text (another program may have it open)") do return
	testing.expect_value(t, get_clipboard_text(), words)

	testing.expect(t, set_clipboard_text(""))
	testing.expect_value(t, get_clipboard_text(), "")
}

// What Explorer hands a window on a drop: a header, then the names as UTF-16, each ended by a zero and the list by another
@(private = "file")
Drop_Header :: struct #packed {
	files_offset: u32,
	point:        [2]i32,
	non_client:   win.BOOL,
	wide:         win.BOOL,
}

@(private = "file")
make_drop :: proc(position: [2]i32, names: []string) -> win.HDROP {
	units: [dynamic]u16
	defer delete(units)
	for name in names {
		append(&units, ..win.utf8_to_utf16(name, context.temp_allocator))
		append(&units, 0)
	}
	append(&units, 0)

	header := Drop_Header{files_offset = size_of(Drop_Header), point = position, wide = true}
	memory := win.GlobalAlloc(win.GMEM_MOVEABLE | win.GMEM_ZEROINIT, uint(size_of(Drop_Header) + len(units) * 2))
	bytes := ([^]byte)(win.GlobalLock(win.HGLOBAL(memory)))
	intrinsics.mem_copy(bytes, &header, size_of(Drop_Header))
	intrinsics.mem_copy(bytes[size_of(Drop_Header):], raw_data(units), len(units) * 2)
	win.GlobalUnlock(win.HGLOBAL(memory))
	return win.HDROP(memory)
}

@(test)
dropped_files_come_with_the_place_they_landed :: proc(t: ^testing.T) {
	saved := save_input()
	defer restore_input(saved)

	drop := make_drop({310, 220}, {`C:\assets\models\crate.glb`, `D:\caf\u00e9\tree.glb`})
	window_event_proc(nil, win.WM_DROPFILES, win.WPARAM(drop), 0)

	files := get_dropped_files()
	if !testing.expect_value(t, len(files), 2) do return
	testing.expect_value(t, files[0].path, `C:\assets\models\crate.glb`)
	testing.expect_value(t, files[1].path, `D:\caf\u00e9\tree.glb`)
	testing.expect_value(t, files[0].position, [2]i32{310, 220})

	// A new frame has none
	clear_dropped_files()
	testing.expect_value(t, len(get_dropped_files()), 0)
}

@(test)
the_display_scale_is_the_monitors_dpi_over_96 :: proc(t: ^testing.T) {
	saved := save_input()
	defer restore_input(saved)
	window := create_test_window()
	defer win.DestroyWindow(window)

	// No window yet (before init): 100%, not zero, which a UI would divide by
	mbi.window = nil
	testing.expect_value(t, get_display_scale(), 1)

	mbi.window = window
	testing.expect_value(t, get_display_scale(), f32(win.GetDpiForWindow(window)) / 96)
	testing.expect(t, get_display_scale() >= 1)
}
