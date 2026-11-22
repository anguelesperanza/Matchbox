#+build freestanding arm32

package matchbox

/*
	Events -- Vita
	==============
	Reads the controller once a frame. Inside `when VITA` for the reason in
	backend_vita_freestanding_arm32.odin
*/

import "vito/vito"

when VITA {

	/*Process the events for this frame: the controller, and the temp allocator's reset*/
	poll_events :: proc() {
		// The handhelds have no event loop that would free it, so the frame's start does
		free_all(context.temp_allocator)

		vito.input_update(&mbi.input)
	}
}
