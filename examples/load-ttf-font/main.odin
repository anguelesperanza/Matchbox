package loadttf


import "../../matchbox"
main :: proc() {

	mbi := matchbox.init("Load TTF Font", 1280, 720)

	font := matchbox.load_font(&mbi, #load("new_hiscore.ttf"), 64)

	for mbi.running {
		matchbox.poll_events(&mbi)
		
		matchbox.begin_drawing(&mbi)
		matchbox.clear_background(&mbi, matchbox.CORNFLOWER_BLUE)
		matchbox.draw_text(&mbi, &font, "Hello World", 100, 100, matchbox.BLACK)
		matchbox.end_drawing(&mbi)
	}


	matchbox.destroy_font(&mbi, &font)

	matchbox.wait_idle()
	matchbox.cleanup(&mbi)
	
}
