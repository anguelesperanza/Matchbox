#+build freestanding arm32

package matchbox

/*
	Util -- both handhelds
	======================
	Path helpers the 3DS and the Vita share. Outside `when`, unlike the rest of the handheld
	files: they touch nothing of either console, so one copy serves both.
	core:strings is not used for them because a path is wanted as a cstring in a buffer the
	caller already has, with no allocation for something used once and dropped
*/

/*Joins the parts into buffer and returns a null-terminated path. The caller owns buffer, so it must outlive the returned cstring*/
build_path :: proc(buffer: []u8, parts: ..string) -> (path: cstring, ok: bool) {
	n := 0
	for part in parts {
		if n + len(part) >= len(buffer) do return nil, false // leave room for the terminator
		for i in 0..<len(part) do buffer[n + i] = part[i]
		n += len(part)
	}
	buffer[n] = 0
	return cstring(raw_data(buffer)), true
}

/* "toyota.png" -> "toyota". Cuts at the LAST '.', and a name without a dot is returned unchanged */
strip_extension :: proc(name: string) -> string {
	for i := len(name) - 1; i >= 0; i -= 1 {
		if name[i] == '.' do return name[:i]
	}
	return name
}
