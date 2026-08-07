package createwindow

import "../../matchbox"

main :: proc() {

	matchbox.init("Create Window", 1080, 720)

	for matchbox.mbi.running {

		matchbox.poll_events()
		
		matchbox.begin_drawing()
		matchbox.clear_background(matchbox.CORNFLOWER_BLUE)
		matchbox.end_drawing()
	}
	
	matchbox.wait_idle()
	matchbox.cleanup()
	
}
