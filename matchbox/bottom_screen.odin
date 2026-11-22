package matchbox

/*
	Bottom screen
	=============
	The 3DS has a second screen under the main one, 320x240 and touch. PC and Vita have
	one surface, so what a game draws "on the bottom screen" has to go somewhere there.

	A game draws every pass every frame -- the world, the HUD, and the bottom screen -- and
	never chooses between them. Matchbox drops the passes the target cannot show, at
	camera_end, so nothing of theirs reaches the GPU:

		layout       PC and Vita                              3DS
		HIDDEN       world and HUD; bottom screen dropped     both screens
		FULLSCREEN   bottom screen fills the window;          both screens
		             world and HUD dropped
		CONSOLE      as HIDDEN                                world and HUD on top; the bottom
		                                                      screen is ctru's text console,
		                                                      `print` writes to it, and the
		                                                      bottom screen pass is dropped

	So an inventory on the bottom screen is opened on PC with set_bottom_screen(.FULLSCREEN),
	and sits on its own screen on the 3DS with no change to the game. Whether it is open is
	the game's own state; is_bottom_screen_visible only says whether the screen is shown.

	A fullscreen bottom screen fills the window with no letterbox: like the HUD, the view has a
	fixed height and its width follows the window, so lay it out with anchors.
	(Seeing both screens at once on one surface, an overlay or a stacked layout, is not offered
	at this time.)
*/

/*
	The HUD's and the bottom screen's fixed shapes. Lives in `mbi.screen_settings`, with its
	values set where `mbi` is declared, so they hold under `odin test` too
*/
Screen_Settings :: struct {
	default_height:f32, // HUD units tall until set_screen_height. A placeholder until the design aspect and fit policy are chosen (render_plan.md, B8)
	bottom_screen_aspect:f32, // the 3DS bottom screen's shape: 320 wide, 240 tall. The top screen is 400x240
}

Bottom_Screen_Layout :: enum {
	HIDDEN,
	FULLSCREEN,
	CONSOLE, // the 3DS's text console, for debugging; elsewhere the same as HIDDEN
}

/*
	How tall the bottom screen's view is, in world units, in a window `aspect` (width / height) wide.

	It is `height` tall, the same as the HUD, so the two screens share one set of units.
	A window narrower than the 3DS's 4:3 would cut the sides off, so there the width is held
	at 4:3 of `height` and the view grows taller instead
*/
calculate_bottom_screen_view_height :: proc(height:f32, aspect:f32) -> f32 {
	if aspect <= 0 do return height
	return max(height, height * mbi.screen_settings.bottom_screen_aspect / aspect)
}
