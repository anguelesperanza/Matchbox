package drawtext

import "../../matchbox"

main :: proc() {
	matchbox.init("Draw Text", 1920, 1080)
	for matchbox.mbi.running {

		matchbox.poll_events()
		
		matchbox.begin_drawing()
		matchbox.clear_background(matchbox.CORNFLOWER_BLUE)
		matchbox.draw_text(&matchbox.mbi.font, "THE QUICK BROWN FOX JUMPS OVER THE LAZY DOG", 100, 100, matchbox.BLACK)
		matchbox.draw_text(&matchbox.mbi.font, 4, 100, 200, matchbox.BLACK)
		matchbox.draw_text(&matchbox.mbi.font, 3.14, 100, 300, matchbox.BLACK)
		matchbox.end_drawing()
	}

	matchbox.wait_idle()
	matchbox.cleanup()
}
