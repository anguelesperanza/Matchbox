package drawtext

import "../../matchbox"

main :: proc() {
	mbi := matchbox.init("Draw Text", 1920, 1080)
	for mbi.running {

		matchbox.poll_events(&mbi)
		
		matchbox.begin_drawing(&mbi)
		matchbox.clear_background(&mbi, matchbox.CORNFLOWER_BLUE)
		matchbox.draw_text(&mbi,&mbi.font, "THE QUICK BROWN FOX JUMPS OVER THE LAZY DOG", 100, 100, matchbox.BLACK)
		matchbox.draw_text(&mbi,&mbi.font, 4, 100, 200, matchbox.BLACK)
		matchbox.draw_text(&mbi,&mbi.font, 3.14, 100, 300, matchbox.BLACK)
		matchbox.end_drawing(&mbi)
	}

	matchbox.destroy_font(&mbi, &mbi.font)
	matchbox.wait_idle()
	matchbox.cleanup(&mbi)
}
