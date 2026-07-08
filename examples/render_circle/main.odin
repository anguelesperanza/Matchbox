package renderrectangle

import "../../matchbox"

main :: proc() {

	mbi := matchbox.init("Render Circle", 1920, 1080)

	default_circle := matchbox.create_default_circle()

	for mbi.running {
		matchbox.poll_events(&mbi)
	
		matchbox.begin_render(&mbi)
		matchbox.render_shape(&mbi, default_circle)
		matchbox.end_render(&mbi)
	}

	/*WIP*/matchbox.destroy_shape(&default_circle)

	matchbox.cleanup(&mbi)
	
}
