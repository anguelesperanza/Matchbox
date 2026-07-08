package texturedrectangle

import "../../matchbox"


main :: proc() {

	mbi := matchbox.init("Render Textured Rectangle", 1920, 1080)

	/*WIP*/default_rectangle := matchbox.create_textured_rectangle()

	for mbi.running {
		matchbox.poll_events(&mbi)
	
		matchbox.begin_render(&mbi)
		/*WIP*/matchbox.render_rectangle(&mbi, default_rectangle)
		matchbox.end_render(&mbi)
	}

	/*WIP*/matchbox.destroy_rectangle(&default_rectangle)

	matchbox.cleanup(&mbi)
	
}
