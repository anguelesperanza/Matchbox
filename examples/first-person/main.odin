package first_person_example

/*
	Walking around, with the mouse locked to the window.

	Stage 2 of the 3D work, and the point of it is the split. The camera, the
	two angles and the eye height all have to agree every frame, so they live in
	a `First_Person_Camera` -- one struct, one call to set it up, one call a
	frame. The same shape as `Third_Person_Camera` in `examples/third-person`,
	and for the same reason.

	Underneath it are the pieces a game with collision wants, because such a
	game needs the solver to decide where the player ends up rather than having
	the camera moved for it: `first_person_input` for the angles and which way
	the keys point, and `first_person_aim` to seat the eye after something else
	has moved the body. `first_person_walk` is those two with the move between
	them, for a camera nothing else is driving. Both are shown below; the second
	is commented, because there is no physics library in this example to hand
	the velocity to.

	Note what the rig does **not** hold: the body's position. That stays the
	game's, which is what lets a solver have the last word on it.

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
import "core:math"

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
	mb.set_lighting({enabled = true, ambient = {color = {3.5, 3.5, 3.5, 1}}, exposure = 1})
	mb.set_lights({mb.create_directional_light({0.4, -1, -0.7}, {0.65, 0.65, 0.65, 1})})

	// ESC is how you get the pointer back here, so it must not also close the
	// window. .UNKNOWN is a scancode no key produces, which turns the built-in
	// behaviour off without needing a flag for it.
	mb.set_escape_key(.UNKNOWN)

	cube, cube_err := mb.create_cube_model(1)
	if cube_err != nil do return
	defer mb.destroy(&cube)

	// Where the player is standing. The rig follows it and never writes it,
	// which is the whole of why the physics version below is four lines.
	player := [3]f32{0, 0, 4}

	// Facing along -z rather than the +x that yaw 0 would give, so the cubes
	// are in front of the player on the first frame. The eye sits EYE_HEIGHT
	// above `player`, and the rig adds that itself from here on.
	rig := mb.create_first_person_camera(
		position   = player,
		facing     = -math.PI * 0.5,
		eye_offset = {0, EYE_HEIGHT, 0},
	)

	mb.set_cursor_locked(true)

	for mb.is_running() {
		mb.poll_events()
		dt := mb.get_delta_time()

		if mb.is_key_pressed(.ESCAPE) {
			if mb.is_cursor_locked() {
				mb.set_cursor_locked(false)
			} else {
				mb.mbi.running = false
			}
		}

		// Clicking in the window takes the pointer back. Only when it is loose
		// already, so a click while playing is a click in the game.
		if !mb.is_cursor_locked() && mb.is_mouse_pressed(.LEFT) {
			mb.set_cursor_locked(true)
		}

		// Only while the pointer belongs to us. Without the check, the frame
		// after ESC still carries the motion that reached the window before it
		// was released, and the view jumps as you go for the menu.
		if mb.is_cursor_locked() {
			mb.first_person_walk(&rig, &player, WALK_SPEED, dt)
		}

		/*
			What `first_person_walk` is, for a game whose player is a body in a
			solver:

				mb.first_person_input(&rig)

				velocity := rig.move * WALK_SPEED
				b3.Body_SetLinearVelocity(body, {velocity.x, 0, velocity.z})
				b3.World_Step(world, 1.0 / 60.0, 4)

				body_pos := b3.Body_GetPosition(body)
				player = {body_pos.x, body_pos.y, body_pos.z}

				mb.first_person_aim(&rig, player)

			Matchbox moves nothing. It says which way you are facing and which
			way the keys point; the solver decides where that gets you.

			Note that the eye height appears nowhere here. It is on the rig, and
			`first_person_aim` adds it -- where the loose form had it written out
			at the call site, and again at every other place a position came
			back from the solver.
		*/

		mb.begin_drawing()
		mb.clear_background(mb.CORNFLOWER_BLUE)

		mb.begin_drawing_3d(rig.camera)

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

		if mb.is_cursor_locked() {
			mb.draw_text(font, "ESC releases the pointer", 20, 70, mb.WHITE)
		} else {
			mb.draw_text(font, "click to look again, ESC again to quit", 20, 70, mb.WHITE)
		}

		mb.draw_text(font, fmt.tprintf("yaw %.2f  pitch %.2f", rig.yaw, rig.pitch), 20, 110, mb.WHITE)
		mb.draw_text(font, fmt.tprintf("standing at %.1f, %.1f, %.1f  eye at %.1f",
			player.x, player.y, player.z, rig.camera.position.y), 20, 140, mb.WHITE)

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
