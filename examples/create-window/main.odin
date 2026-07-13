package createwindow

import "../../matchbox"

main :: proc() {

	mbi := matchbox.init("Create Window", 1080, 720)

	for mbi.running {

		matchbox.poll_events(&mbi)
		
		matchbox.begin_drawing(&mbi)
		matchbox.clear_background(&mbi, matchbox.CORNFLOWER_BLUE)
		matchbox.end_drawing(&mbi)
	}
	
	matchbox.wait_idle()
	matchbox.cleanup(&mbi)
	
}
