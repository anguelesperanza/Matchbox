package loadttf


import "../../matchbox"
main :: proc() {

	matchbox.init("Load TTF Font", 1280, 720)

	font := matchbox.load_font(#load("new_hiscore.ttf"), 64)

	for matchbox.mbi.running {
		matchbox.poll_events()
		
		matchbox.begin_drawing()
		matchbox.clear_background(matchbox.CORNFLOWER_BLUE)
		matchbox.draw_text(&font, "Hello World", 100, 100, matchbox.BLACK)
		matchbox.end_drawing()
	}


	matchbox.destroy_font(&font)

	matchbox.wait_idle()
	matchbox.cleanup()
	
}
