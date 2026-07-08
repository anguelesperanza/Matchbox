package renderrectangle

import "../../matchbox"

main :: proc() {

	mbi := matchbox.init("Render Rectangle", 1920, 1080)

	default_rectangle := matchbox.create_default_rectangle()

	for mbi.running {
		matchbox.poll_events(&mbi)
	
		matchbox.begin_render(&mbi)
		matchbox.render_shape(&mbi, default_rectangle)
		matchbox.end_render(&mbi)
	}

	/*WIP*/matchbox.destroy_shape(&default_rectangle)

	matchbox.cleanup(&mbi)
	
}
