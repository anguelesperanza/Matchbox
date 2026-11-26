#+build freestanding arm32

package matchbox

/*
	Bottom screen on the 3DS
	========================
	The same procedures as on one surface (bottom_screen_one_surface.odin), but the 3DS has
	the screen itself, 320 x 240 under the top one, so both screens are always shown:

		.HIDDEN / .FULLSCREEN  change nothing: the layout is how a one-surface target fakes
		                       this screen, and the 3DS does not need to
		.CONSOLE               the bottom screen is ctru's text console instead: `print`
		                       writes to it the old way, and the bottom screen pass is
		                       thrown away. For debugging; any other layout gives the screen
		                       back to the game
		is_bottom_screen_visible  true unless .CONSOLE

	Nothing here throws away the world or the HUD: the 3DS shows them on the top screen
	whatever the layout.

	Its camera is the HUD's height in units and the bottom screen's own 4:3 shape. It has its
	own citro3d target (init), and bottom_screen_start points the frame at it, so the same
	queue and camera code draw here as on the top screen.

	`print` output is drawn here too, over whatever the game drew, at render_end: the last
	lines that fit, newest at the bottom, on a dark backdrop. It replaces ctru's text console,
	which took the whole screen and left the game none of it. The lines also still go to the
	emulator's log and Luma3DS's debugger (util_3ds_freestanding_arm32.odin).

	Inside `when !VITA` for the reason in backend_3ds_freestanding_arm32.odin
*/

import "core:strings"

import "o3dx/c3d"
import "o3dx/ctru"
import "o3dx/o3dx"

when !VITA {

	// How many `print` lines are kept, and how long each may be. Constants because they size
	// Print_Log's arrays; a longer line is cut, and the oldest line goes when a new one comes
	PRINT_LOG_LINES :: 32
	PRINT_LOG_LINE_BYTES :: 160

	/*The last lines `print` wrote, oldest first from `first`. Lives in `mbi.print_log`*/
	Print_Log :: struct {
		lines:[PRINT_LOG_LINES][PRINT_LOG_LINE_BYTES]u8,
		lengths:[PRINT_LOG_LINES]int,
		first:int, // the oldest line's slot
		count:int,
		font:Font, // the system font at print_log_settings.pixel_size, made in init
	}

	/*How the print log looks. Lives in `mbi.print_log_settings`, set in BACKEND_DEFAULTS*/
	Print_Log_Settings :: struct {
		pixel_size:f32, // text height in screen pixels: 12 fits about 16 lines on the 240 pixel screen
		margin:f32, // screen pixels between the text and the screen's edges
		backdrop:[4]f32, // drawn behind the lines so they read over the game's own drawing
		color:[4]f32,
	}

	/*Adds `text` to the print log, a line per newline in it*/
	@(private)
	add_print_lines :: proc(text:string) {
		log := &mbi.print_log
		rest := text
		for line in strings.split_lines_iterator(&rest) {
			slot := (log.first + log.count) % PRINT_LOG_LINES
			if log.count == PRINT_LOG_LINES {
				log.first = (log.first + 1) % PRINT_LOG_LINES // full: the oldest makes room
			} else {
				log.count += 1
			}
			log.lengths[slot] = copy(log.lines[slot][:], line)
		}
	}

	/*
		Draws the print log on the bottom screen. Called by render_end, after the game's passes,
		so it lands on top. In screen pixels: a screen camera 240 units tall, 1 unit a pixel
	*/
	@(private)
	render_print_log :: proc() {
		log := &mbi.print_log
		settings := mbi.print_log_settings
		if log.count == 0 || log.font.pixels_per_unit == 0 do return
		if mbi.bottom_screen_layout == .CONSOLE do return // the lines went to the console as they were printed

		width := f32(mbi.window_size[2])
		height := f32(mbi.window_size[3])
		usable_width := width - 2 * settings.margin

		// Long lines wrap. Wrapped from the newest back, until the screen is full, so the lines
		// that are drawn are the newest ones whatever their lengths
		step := calculate_line_height(log.font)
		room := int((height - 2 * settings.margin) / step)
		shown := make([dynamic]string, 0, room, context.temp_allocator)
		for i := log.count - 1; i >= 0 && len(shown) < room; i -= 1 {
			slot := (log.first + i) % PRINT_LOG_LINES
			pieces := wrap_text(log.font, string(log.lines[slot][:log.lengths[slot]]), usable_width, context.temp_allocator)
			for j := len(pieces) - 1; j >= 0 && len(shown) < room; j -= 1 {
				inject_at(&shown, 0, pieces[j])
			}
			if len(pieces) == 0 do inject_at(&shown, 0, "") // an empty print is an empty line
		}
		if len(shown) > room do remove_range(&shown, 0, len(shown) - room)

		bottom_screen_target_start()
		camera_start(create_screen_camera(height))

		// The screen camera's origin is the screen's centre
		top_left := [3]f32{-width / 2 + settings.margin, height / 2 - settings.margin, 0}
		block := calculate_text_block_height(log.font, len(shown))
		render_rectangle({0, height / 2 - (block + 2 * settings.margin) / 2, 0}, {width, block + 2 * settings.margin}, settings.backdrop)
		render_text_lines(log.font, shown[:], top_left, settings.color)

		camera_end()
		bottom_screen_target_end()
	}

	/*Points the frame at the bottom screen's target, so camera_start sizes its view by it*/
	@(private)
	bottom_screen_target_start :: proc() {
		mbi.drawing_bottom_screen = true
		// The bottom screen is never scaled, so a render target being drawn (set_internal_resolution's) waits
		mbi.render_target_state.suspended = mbi.render_target_state.active
		mbi.render_target_state.suspended_active = mbi.render_target_state.is_active
		mbi.render_target_state.active = {}
		mbi.render_target_state.is_active = false
		c3d.C3D_FrameDrawOn(mbi.bottom_screen)
	}

	@(private)
	bottom_screen_target_end :: proc() {
		mbi.drawing_bottom_screen = false
		state := &mbi.render_target_state
		state.active = state.suspended
		state.is_active = state.suspended_active
		state.suspended = {}
		state.suspended_active = false
		c3d.C3D_FrameDrawOn(state.active.citro_target if state.is_active else mbi.top_screen)
	}

	/*
		Kept so a game can ask for it back. Only .CONSOLE changes anything on the 3DS: it hands
		the bottom screen to ctru's console, and any other layout hands it back to the game.
		Called before init, the layout is applied by init
	*/
	set_bottom_screen :: proc(layout:Bottom_Screen_Layout) {
		was_console := mbi.bottom_screen_layout == .CONSOLE
		mbi.bottom_screen_layout = layout
		if mbi.bottom_screen == nil do return // before init: init applies it

		if layout == .CONSOLE && was_console == false do start_bottom_screen_console()
		if layout != .CONSOLE && was_console == true do stop_bottom_screen_console()
	}

	get_bottom_screen_layout :: proc() -> Bottom_Screen_Layout {
		return mbi.bottom_screen_layout
	}

	/*True unless the bottom screen is the text console (.CONSOLE)*/
	is_bottom_screen_visible :: proc() -> bool {
		return mbi.bottom_screen_layout != .CONSOLE
	}

	/*
		Gives the bottom screen to ctru's console. citro3d's target is unlinked from it first, or
		every frame end would copy the game's (empty) bottom screen over the console's text
	*/
	@(private)
	start_bottom_screen_console :: proc() {
		c3d.C3D_RenderTargetSetOutput(nil, ctru.GFX_BOTTOM, ctru.GFX_LEFT, 0)
		ctru.consoleInit(ctru.GFX_BOTTOM, nil)
		o3dx.print_to_console = true
	}

	/*
		Gives the bottom screen back to citro3d. consoleInit switched it to 16-bit colour and
		single buffering; citro3d's display transfer writes 24-bit colour into double buffers
		(display_settings.transfer_flags), so both are put back before the target is linked again
	*/
	@(private)
	stop_bottom_screen_console :: proc() {
		o3dx.print_to_console = false
		ctru.gfxSetScreenFormat(.BOTTOM, .BGR8)
		ctru.gfxSetDoubleBuffering(.BOTTOM, true)
		c3d.C3D_RenderTargetSetOutput(mbi.bottom_screen, ctru.GFX_BOTTOM, ctru.GFX_LEFT, mbi.display_settings.transfer_flags)
	}

	// The bottom screen's camera: the HUD's height, the bottom screen's width
	@(private)
	get_bottom_screen_camera :: proc() -> Camera {
		return create_screen_camera(calculate_bottom_screen_view_height(mbi.screen_height, mbi.screen_settings.bottom_screen_aspect))
	}

	/*Everything drawn until bottom_screen_end is the bottom screen. Thrown away while the console has it*/
	bottom_screen_start :: proc() {
		if is_bottom_screen_visible() == false {
			camera_start(get_bottom_screen_camera())
			mbi.discard_pass = true
			return
		}
		bottom_screen_target_start()
		camera_start(get_bottom_screen_camera())
	}

	bottom_screen_end :: proc() {
		camera_end()
		if mbi.drawing_bottom_screen == true do bottom_screen_target_end()
	}

	/*The corners of the bottom screen's view, in its units: `min` bottom left, `max` top right*/
	calculate_bottom_screen_visible_rectangle :: proc() -> (min, max:[2]f32) {
		return calculate_camera_visible_rectangle(get_bottom_screen_camera(), mbi.screen_settings.bottom_screen_aspect)
	}

	/*A bottom screen position pinned to `anchor` and moved by `offset`. See calculate_camera_anchor_position*/
	calculate_bottom_screen_anchor_position :: proc(anchor:Anchor, offset:[2]f32 = {}) -> [3]f32 {
		return calculate_camera_anchor_position(get_bottom_screen_camera(), mbi.screen_settings.bottom_screen_aspect, anchor, offset)
	}

	/*
		Where the stylus is, in the bottom screen's units, and whether it is on the screen: while
		it is down, and on the frame it lifts, so a button that acts on release still knows where.
		A mouse is somewhere whether or not a button is down; a stylus in the air is nowhere, so
		`inside` is the 3DS's nearest match to the PC's mouse being over the window.
		False while the console has the screen: there is nothing of the game's there to touch
	*/
	calculate_mouse_bottom_screen_position :: proc() -> (position:[2]f32, inside:bool) {
		if is_bottom_screen_visible() == false do return {}, false

		touching := (mbi.gamepad_held | mbi.gamepad_released) & ctru.KEY_TOUCH != 0
		if touching == false do return {}, false

		bottom_screen_size := [2]f32{f32(mbi.window_size[2]), f32(mbi.window_size[3])}
		return calculate_screen_to_world_2d(get_bottom_screen_camera(), mbi.touch_position, bottom_screen_size), true
	}
}
