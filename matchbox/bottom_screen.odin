package matchbox

/*
	Bottom screen
	=============
	The 3DS has a second screen under the main one, 320x240 and touch. PC and Vita have
	one surface, so what a game draws "on the bottom screen" has to go somewhere there.
	On PC the game chooses:

		HIDDEN      nothing is drawn, for a game where the bottom screen is optional
		FULLSCREEN  the bottom screen takes over the whole window, until the game switches back

	While FULLSCREEN the game draws the bottom screen's content and skips the world.
	It fills the window with no letterbox: like the HUD, the view has a fixed height and
	its width follows the window, so lay it out with anchors.
	(Seeing both screens at once, an overlay or a stacked layout, is not offered at this time.)
*/

// The 3DS bottom screen's shape: 320 wide, 240 tall. The top screen is 400x240
BOTTOM_SCREEN_ASPECT :: f32(320.0 / 240.0)

Bottom_Screen_Layout :: enum {
	HIDDEN,
	FULLSCREEN,
}

/*
	How tall the bottom screen's view is, in world units, in a window `aspect` (width / height) wide.

	It is `height` tall, the same as the HUD, so the two screens share one set of units.
	A window narrower than the 3DS's 4:3 would cut the sides off, so there the width is held
	at 4:3 of `height` and the view grows taller instead
*/
bottom_screen_view_height :: proc(height:f32, aspect:f32) -> f32 {
	if aspect <= 0 do return height
	return max(height, height * BOTTOM_SCREEN_ASPECT / aspect)
}
