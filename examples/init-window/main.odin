package initwindow

import "../../matchbox"


main :: proc() {

	mbi := matchbox.init("Init Window", 1920, 1080)

	for mbi.running {
		matchbox.poll_events(&mbi)
	
		matchbox.begin_render(&mbi)
		matchbox.end_render(&mbi)
	}

	matchbox.cleanup(&mbi)
}
