package renderrectangle

import "../../matchbox"


main :: proc() {

	mbi := matchbox.init("Render Triangle", 1920, 1080)

	default_triangle := matchbox.create_default_triangle()

	for mbi.running {
		matchbox.poll_events(&mbi)
	
		matchbox.begin_render(&mbi)
		matchbox.render_shape(&mbi, default_triangle)
		matchbox.end_render(&mbi)
	}

	matchbox.destroy_shape(&default_triangle)

	matchbox.cleanup(&mbi)
	
}
