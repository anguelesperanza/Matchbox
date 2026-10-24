package matchbox

import win "core:sys/windows"


render_start :: proc() {
	// TODO: Implement
}

render_end :: proc() {
	win.InvalidateRect(hWnd = mbi.window, lpRect = nil, bErase = win.TRUE)
	win.UpdateWindow(hWnd = mbi.window)

}

render_sprite :: proc(sprite:Sprite) {
	// TODO: Implement
}

clear_background :: proc() {
	// TODO: Implement
}
