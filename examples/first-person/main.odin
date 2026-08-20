package first_person_example

/*
	Walking around, with the mouse locked to the window.

	Stage 2 of the 3D work, and the point of it is the split. There is one
	procedure here that does everything -- `camera3d_first_person` -- and it is
	the one a real game will not use, because a real game has collision and
	wants the solver to decide where the player ends up. What it will use is the
	three pieces underneath: `camera3d_look` for the angles, `walk_direction`
	for which way the keys are asking to go, and `camera3d_aim` to point the
	camera after something else has moved it. Both are shown below; the second
	is commented, because there is no physics library in this example to hand
	the velocity to.

	Things to try:

	  - **look around.** The cursor is locked, which is what makes this work at
	    all: an unlocked pointer stops reporting motion the moment it reaches
	    the edge of the screen, so you could turn right exactly once
	  - **walk into a cube.** You go straight through it. Matchbox has no
	    collision and is not getting any -- that is Box3D's job, and this is
	    what its absence looks like
	  - **look straight up.** It stops just short of vertical. Exactly vertical
	    is where the forward direction lines up with the up vector, the view
	    matrix collapses, and the world rolls over
	  - **press ESC.** The pointer comes back and the window keeps running.
	    Press it again to quit. `set_escape_key` is what makes that possible --
	    Matchbox closes on ESC by default, which is wrong for a game where ESC
	    is how you get your mouse back
	  - **click.** Locks the pointer again

	The ground is a cube scaled to {60, 0.2, 60}. There is no plane primitive
	until stage 3, and a very flat cube is a plane with more triangles than it
	needs.
*/

import "core:fmt"

import mb "../../matchbox"

EYE_HEIGHT :: 1.7
WALK_SPEED :: 6.0

Block :: struct {
	position: [3]f32,
	scale:    f32,
	color:    [4]f32,
}

blocks := []Block{
	{{  0, 0.5,  -6}, 1.0, mb.PUMPKIN_ORANGE},
	{{  4, 1.0,  -9}, 2.0, mb.LIME_GREEN},
	{{ -5, 0.5,  -4}, 1.0, mb.RED},
	{{ -3, 1.5, -12}, 3.0, mb.WHITE},
	{{  7, 0.5,  -2}, 1.0, mb.LIME_GREEN},
	{{ -8, 1.0, -10}, 2.0, mb.PUMPKIN_ORANGE},
	{{  2, 0.5,   3}, 1.0, mb.WHITE},
	{{ 10, 2.0, -14}, 4.0, mb.RED},
}

main :: proc() {
	mb.init("First Person", 1280, 720)
	defer mb.cleanup()

	// ESC is how you get the pointer back here, so it must not also close the
	// window. .UNKNOWN is a scancode no key produces, which turns the built-in
	// behaviour off without needing a flag for it.
	mb.set_escape_key(.UNKNOWN)

	cube := mb.cube_model(1)
	defer mb.destroy(&cube)

	camera := mb.camera3d_at(position = {0, EYE_HEIGHT, 4}, target = {0, EYE_HEIGHT, 0})

	// Seeded from the camera rather than left at zero. Yaw 0 looks along +x,
	// so starting from zero would spin the view a quarter turn on the first
	// frame -- which is a small thing that looks like a bug.
	yaw, pitch := mb.camera3d_angles(camera)

	mb.set_cursor_locked(true)

	for mb.is_running() {
		mb.poll_events()
		dt := mb.delta_time()

		if mb.is_key_pressed(.ESCAPE) {
			if mb.cursor_locked() {
				mb.set_cursor_locked(false)
			} else {
				mb.mbi.running = false
			}
		}

		// Clicking in the window takes the pointer back. Only when it is loose
		// already, so a click while playing is a click in the game.
		if !mb.cursor_locked() && mb.is_mouse_pressed(.LEFT) {
			mb.set_cursor_locked(true)
		}

		// Only while the pointer belongs to us. Without the check, the frame
		// after ESC still carries the motion that reached the window before it
		// was released, and the view jumps as you go for the menu.
		if mb.cursor_locked() {
			mb.camera3d_first_person(&camera, &yaw, &pitch, WALK_SPEED, dt)
		}

		/*
			What the same thing looks like with physics, which is what both
			games will do:

				mb.camera3d_look(&yaw, &pitch)

				velocity := mb.walk_direction(yaw) * WALK_SPEED
				b3.Body_SetLinearVelocity(body, {velocity.x, 0, velocity.z})
				b3.World_Step(world, 1.0 / 60.0, 4)

				body_pos := b3.Body_GetPosition(body)
				camera.position = {body_pos.x, EYE_HEIGHT, body_pos.z}
				mb.camera3d_aim(&camera, yaw, pitch)

			Matchbox moves nothing. It says which way you are facing and which
			way the keys point; the solver decides where that gets you.
		*/

		mb.begin_drawing()
		mb.clear_background(mb.CORNFLOWER_BLUE)

		mb.begin_drawing_3d(camera)

		// Non-uniform scale, which is the case the normal matrix exists for:
		// the model matrix alone would leave this lit as though it were still a
		// cube.
		mb.draw_model(cube, mb.Transform{
			position = {0, -0.1, 0},
			rotation = mb.transform_rotation({0, 1, 0}, 0),
			scale    = {60, 0.2, 60},
		}, {0.45, 0.5, 0.42, 1})

		for block in blocks {
			mb.draw_model_at(cube, block.position, block.scale, block.color)
		}

		mb.end_drawing_3d()

		font := &mb.mbi.font
		mb.draw_text(font, "WASD to walk, mouse to look", 20, 40, mb.WHITE)

		if mb.cursor_locked() {
			mb.draw_text(font, "ESC releases the pointer", 20, 70, mb.WHITE)
		} else {
			mb.draw_text(font, "click to look again, ESC again to quit", 20, 70, mb.WHITE)
		}

		mb.draw_text(font, fmt.tprintf("yaw %.2f  pitch %.2f", yaw, pitch), 20, 110, mb.WHITE)
		mb.draw_text(font, fmt.tprintf("at %.1f, %.1f, %.1f",
			camera.position.x, camera.position.y, camera.position.z), 20, 140, mb.WHITE)

		// Crosshair, which is also the reminder that 2D still works over 3D.
		//
		// The pivot is left at its zero value on purpose. Matchbox measures it
		// the opposite way round from most engines: {0, 0} means `position`
		// already is the centre, and {0.5, 0.5} would offset the bar by half its
		// own size -- which turns a cross into a corner, as it did the first
		// time this was written.
		cx := f32(mb.mbi.width) * 0.5
		cy := f32(mb.mbi.height) * 0.5
		mb.draw_rect({position = {cx, cy}, size = {14, 2}, color = mb.WHITE})
		mb.draw_rect({position = {cx, cy}, size = {2, 14}, color = mb.WHITE})

		mb.end_drawing()
	}

	mb.wait_idle()
}
