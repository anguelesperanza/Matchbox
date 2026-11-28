#+build windows

package ui

Status_Level :: enum {
	INFO, // what is happening
	GOOD, // it worked
	WARN, // it worked, but
	BAD, // it did not work
}

STATUS_COLOR :: [Status_Level][4]f32 {
	.INFO = {0.80, 0.82, 0.88, 1},
	.GOOD = {0.55, 0.80, 0.55, 1},
	.WARN = {0.90, 0.75, 0.40, 1},
	.BAD  = {0.90, 0.45, 0.45, 1},
}

// The longest message kept: it sizes an array, so a constant
STATUS_MAX_BYTES :: 160

/*
	A short message with a severity. **The text is copied in**: it is nearly always a `fmt.tprintf`, and keeping the pointer
	would show freed memory by the next frame
*/
Status_Line :: struct {
	buffer:  [STATUS_MAX_BYTES]u8,
	length:  int,
	level:   Status_Level,
	set_at:  f64,
	seconds: f32, // 0 stays until replaced
}

/*Puts a message on the line, cut at a character boundary if it is too long*/
set_status :: proc(status: ^Status_Line, text: string, level: Status_Level = .INFO, seconds: f32 = 0) {
	cut := min(len(text), STATUS_MAX_BYTES)
	for cut > 0 && cut < len(text) && text[cut] & 0xc0 == 0x80 do cut -= 1

	copy(status.buffer[:], text[:cut])
	status.length = cut
	status.level = level
	status.set_at = ui_state.time
	status.seconds = seconds
}

clear_status :: proc(status: ^Status_Line) {
	status.length = 0
}

get_status_text :: proc(status: ^Status_Line) -> string {
	return string(status.buffer[:status.length])
}

/*How visible the line is, 0 to 1: a timed message spends its last half second fading, so it expires rather than vanishing like a glitch*/
calculate_status_alpha :: proc(status: ^Status_Line) -> f32 {
	if status.length == 0 do return 0
	if status.seconds <= 0 do return 1

	left := status.seconds - f32(ui_state.time - status.set_at)
	if left <= 0 do return 0
	if left >= DEFAULTS.status_fade do return 1
	return left / DEFAULTS.status_fade
}

/*Draws the line from a top-left, and returns the room it took. Nothing when empty or faded*/
render_status :: proc(status: ^Status_Line, top_left: [2]f32, font: ^Font = nil) -> [2]f32 {
	alpha := calculate_status_alpha(status)
	if alpha <= 0 do return {}

	font := font if font != nil else default_font()
	colors := STATUS_COLOR
	color := colors[status.level]
	color.a *= alpha

	text := get_status_text(status)
	render_text(font, text, {top_left.x, top_left.y - font.ascent}, color)
	return calculate_text_size(font, text)
}
