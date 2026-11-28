package matchbox

/*
	Input that only a desktop has, but whose types a game written for the PC still has to compile against on the 3DS and the
	Vita (where the procedures that use them answer nothing). Shared and untagged, so the two copies cannot drift apart
*/

// The mouse pointer's picture over the window. Set with set_cursor_shape
Cursor_Shape :: enum {
	ARROW, // the zero value, what a window has when nothing has asked for another
	TEXT, // the I-beam over a text field
	RESIZE_HORIZONTAL, // east-west, over a vertical splitter
	RESIZE_VERTICAL, // north-south, over a horizontal splitter
	HAND, // over something clickable
	CROSSHAIR,
}

// A file dropped on the window from Explorer, and where in the window it landed (pixels, as get_mouse_position gives them)
Dropped_File :: struct {
	path:     string,
	position: [2]i32,
}
