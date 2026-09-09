package cube_example

/*
	The first 3D in Matchbox, and a test of the three things stage 1 had to get
	right. Each is something that fails quietly rather than loudly, so each one
	is on screen as something you can point at.

	**Depth.** The orange cube orbits the white one. Watch it go round the back:
	it must disappear behind the white cube and come out the other side. Without
	a depth buffer it would draw over the top of it for half the orbit, because
	draw order would be the only thing deciding and draw order never changes.

	**The projection's depth range.** The green cube is placed 0.15 units from
	the eye -- just past the near plane at 0.1 -- and worked out from the camera
	rather than hard-coded, so it stays put if the camera moves. It must be
	visible, and it is the near end of the depth range that proves it.

	Matchbox writes its own projections because `linalg.matrix4_perspective`
	maps the frustum to clip z in [-1, 1], the OpenGL convention, and SDL3_GPU
	wants [0, 1]. **This was tried, not assumed.** Swapping linalg's matrix in
	makes the green cube vanish and leaves the other three looking entirely
	reasonable. No error, no warning, nothing in a log -- just a scene missing
	whatever was close to the camera, which is a thing you would go looking for
	in the model loader.

	Trying it also turned up something the plan had not: with `enable_depth_clip`
	left at its zero value the green cube survived a projection that should have
	killed it, because SDL3 reads that field as *clamp* when it is false and
	squashes out-of-range geometry onto the planes instead of discarding it. A
	near plane that does not cut hides the bug this example exists to catch, so
	the pipeline now sets it. That is two silent failures stacked on each other,
	and neither was visible without running the thing.

	**The pass switch.** Every line of text here is 2D, drawn after
	`end_drawing_3d`. 3D runs in a render pass of its own because it needs a
	depth attachment and the 2D pipelines were built without one, so text on top
	of a scene means the frame closes one pass and opens another. If that were
	wrong there would be a scene and no words, or words and no scene.

	The lighting is one directional light and an ambient term, set below. It is
	here so the faces of a cube come out at different brightnesses, because a
	cube in one flat colour is a hexagon and you cannot see it turn -- not
	because this example is about lighting. `examples/lighting` is.

	It used to be a fixed direction hard-coded in mesh_flat.frag, applied to
	any scene that had set no lights of its own. That fallback is gone, and
	deliberately: `lighting_rework.md` section 1 has why an implicit "the
	lighting is on" was worth removing.
*/

import "core:fmt"
import "core:math"

import mb "../../matchbox"

main :: proc() {
	mb.init("Cube", 1280, 720)
	defer mb.cleanup()

	/*
		The sun this example is lit by. It used not to need saying: a scene that set
		no lights got a hard-coded direction inside the shader, and that implicit
		fallback is gone -- see `lighting_rework.md` section 1 for why an
		emergent "lighting is on" was worth removing. Stating it is the
		replacement, and it is two lines.

		The direction is the way the light travels, so a sun overhead points
		down. Ambient is divided by ten inside `brdf/blinn_phong.hlsli` -- 3.5
		here is 0.35 reaching the surface -- which is what keeps the faces
		turned away from the sun off pure black.
	*/
	mb.set_lighting({enabled = true, ambient = {color = {3.5, 3.5, 3.5, 1}}})
	mb.set_lights({mb.create_directional_light({0.4, -1, -0.7}, {0.65, 0.65, 0.65, 1})})

	// One cube on the GPU, drawn four times. A model is geometry, not a thing
	// in the world -- where it goes is the Transform's business, which is what
	// lets one buffer serve every cube on screen.
	cube, cube_err := mb.create_cube_model(1)
	if cube_err != nil do return
	defer mb.destroy(&cube)

	// Wide enough to see the orbit go all the way round, high enough to look
	// slightly down on it so the top faces catch the light.
	camera := mb.create_camera3d(position = {0, 2.5, 7}, target = {0, 0, 0})

	spin: f32

	for mb.is_running() {
		mb.poll_events()
		spin += mb.get_delta_time()

		mb.begin_drawing()
		mb.clear_background(mb.CORNFLOWER_BLUE)

		mb.begin_drawing_3d(camera)

		// Turning about a diagonal, so no face stays square to the light and
		// all three visible faces change brightness as it goes.
		mb.draw_model(cube, mb.Transform{
			position = {0, 0, 0},
			rotation = mb.transform_rotation({0.3, 1, 0.15}, spin),
			scale    = {1.6, 1.6, 1.6},
		}, mb.WHITE)

		// The depth test, made visible. Behind for half the orbit, in front for
		// the other half, and never both at once.
		orbit := f32(3.0)
		mb.draw_model_at(cube,
			position = {math.cos(spin * 0.8) * orbit, 0, math.sin(spin * 0.8) * orbit},
			scale    = 0.7,
			tint     = mb.PUMPKIN_ORANGE)

		// The near plane test. Off the camera's own basis rather than in world
		// coordinates: 0.15 units along the view direction is a fixed distance
		// from the eye whatever the camera does, where a hard-coded point stops
		// being near the moment somebody moves the camera -- which is exactly
		// what happened the first time this was written.
		forward := mb.camera3d_forward(camera)
		right   := mb.camera3d_right(camera)
		mb.draw_model_at(cube,
			position = camera.position + forward * 0.15 - right * 0.09,
			scale    = 0.05,
			tint     = mb.LIME_GREEN)

		// Far enough back to be small but not clipped, so the far end of the
		// range is doing something too.
		mb.draw_model_at(cube, position = {2, -0.5, -40}, scale = 6, tint = mb.RED)

		mb.end_drawing_3d()

		// 2D again, on top. Anything drawn here goes through the pipelines that
		// have always existed, into a pass with no depth attachment.
		font := &mb.mbi.font
		mb.draw_text(font, "orange goes behind white -- that is the depth buffer", 20, 40, mb.WHITE)
		mb.draw_text(font, "green sits 0.15 from the eye -- that is the near plane", 20, 70, mb.WHITE)
		mb.draw_text(font, "this line is 2D over 3D -- that is the second pass", 20, 100, mb.WHITE)

		// Read straight off the renderer because it is the one number that will
		// differ on Android, and stage 1 wants it visible rather than guessed.
		mb.draw_text(font, fmt.tprintf("depth format: %v", mb.mbi.renderer.depth_format),
			20, 140, mb.WHITE)

		mb.end_drawing()
	}

	mb.wait_idle()
}
