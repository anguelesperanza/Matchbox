package matchbox

/*
	Reflection probe capture -- the shape of a face
	-----------------------------------------------
	A capture draws into one face of a cube: square, at the capture cube's own
	size. Its projection used to take the window's shape instead, so each
	90-degree face was squeezed sideways and the six faces did not meet at
	their edges.

	No GPU here, so no capture is opened. The test sets the field
	`begin_probe_capture` sets, and reads what every projection reads.

	**The other tests are part of the check.** A zeroed `mbi` -- which every
	test has, since `init` never runs -- has to read as "no capture open", or
	every projection in the suite comes out square. That broke the cascade
	test the first time this fix was written, and is why `capturing` is a
	`Maybe`. The
	expected numbers come from the definition of a perspective matrix -- m[1,1]
	is 1 / tan(fov / 2), which is exactly 1 at 90 degrees, and m[0,0] is that
	divided by the aspect -- not from running this code.

	What this cannot check is the order inside `begin_probe_capture`, which
	has to mark the capture before building the projection. That is read, not
	tested.
*/

import "core:math"
import "core:testing"

@(test)
test_probe_capture_is_projected_square :: proc(t: ^testing.T) {
	p := &mbi.renderer.lighting.reflection

	mbi.window_width  = 1280
	mbi.window_height = 720
	p.settings.prefilter_resolution = 32

	camera := probe_capture_camera({1, 2, 3}, 0)

	// Not capturing: the window's shape, which is what a capture used to get.
	// Asserted so the test is known to tell the two cases apart.
	p.capturing = nil
	outside := camera3d_projection(camera)
	testing.expectf(t, math.abs(outside[0, 0] - 720.0 / 1280.0) < 1e-4 && math.abs(outside[1, 1] - 1) < 1e-4,
		"outside a capture the projection should follow the window: m00 %.5f (want 0.5625) m11 %.5f (want 1)",
		outside[0, 0], outside[1, 1])

	p.capturing = Probe_Capture{probe = 0, face = 0}
	defer p.capturing = nil

	testing.expect_value(t, get_current_target_size(), [2]f32{32, 32})

	inside := camera3d_projection(camera)
	testing.expectf(t, math.abs(inside[0, 0] - 1) < 1e-4 && math.abs(inside[1, 1] - 1) < 1e-4,
		"a capture face should project square, m00 = m11 = 1 at 90 degrees: got m00 %.5f m11 %.5f",
		inside[0, 0], inside[1, 1])
}
