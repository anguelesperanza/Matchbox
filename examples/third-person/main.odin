package third_person_example

/*
	The same walk as `examples/first-person`, from behind.

	A third-person camera is the first-person one pushed backwards: the same
	yaw, the same pitch, the same `camera3d_look` producing both, and then a
	distance that seats the camera that far back along the direction those two
	describe. What is new is that something is standing in front of it, and the
	something has to be turned to face the way it is running -- which is
	`yaw_from_direction` for the angle, `turn_toward` to get there smoothly, and
	`facing_rotation` to hand it to a draw call.

	The split from stage 2 survives intact, and is worth more here than it was
	there. `camera3d_third_person` moves no character -- there is nothing here
	for it to move, because the character is the game's. So unlike
	`camera3d_first_person`, the composite is the one a real game *can* call:
	move your body in the solver, read its position back, pass it as the focus.

	Things to try:

	  - **walk in a circle.** The character turns to face where it is going
	    rather than snapping, which is `turn_toward` -- and it turns the short
	    way even when the two angles are written a full turn apart
	  - **strafe with A and D.** The keys are read relative to the camera, so
	    the character runs sideways across the screen and pivots to face that
	    way. Turn the camera while holding one and it curves
	  - **press 1, 2 and 3.** Centred, over the left shoulder, over the right.
	    The rig slides sideways rather than turning, so the view direction is
	    unchanged and the character just stops being in the middle of it -- keep
	    walking while you press them and W still goes the same way
	  - **stand behind the tall white box and lean out.** Which shoulder you are
	    on decides which side of it you can see past, which is the whole reason
	    a game offers both
	  - **scroll.** The wheel pulls the camera in and out between 1.5 and 20
	    units. Keep going in and it becomes first person with a body in the way,
	    which is the same thing this always was. Over a shoulder it is worth
	    coming in close, and this example does that for you when you pick one
	  - **look up.** It stops early -- `ORBIT_PITCH_MAX` is 0.30, not
	    `PITCH_LIMIT` -- because pitching up on an orbit camera swings it
	    *under* the character rather than tilting a head, and the floor is down
	    there
	  - **press C.** Toggles the camera keeping out of the floor. With it off,
	    look up at full pitch and the ground swallows the view. With it on, the
	    distance is shortened until the camera clears it -- which is the
	    hand-rolled stand-in for the ray cast a game with Box3D would do against
	    `camera3d_orbit_position`. Matchbox does not cast rays
	  - **hold shift** to run
	  - **press ESC.** The pointer comes back and the window keeps running.
	    Press it again to quit, exactly as in the first-person example, and for
	    the same reason: `set_escape_key(.UNKNOWN)` first

	The ground is `draw_plane` and the blocks are `draw_cube`, both from stage 3.
*/

import "core:fmt"
import "core:math"

import mb "../../matchbox"

// The point the camera looks at. Shoulder height rather than the feet, or the
// character sits on the bottom edge of the screen with the sky above it.
SHOULDER_HEIGHT :: 1.6

WALK_SPEED :: 6.0
RUN_SPEED  :: 11.0

// Radians per second the character pivots at. Fast enough that a tap of A does
// not look like a handbrake turn, slow enough to be visible.
TURN_SPEED :: 12.0

// How far above the ground the camera is kept when C is on.
CAMERA_FLOOR :: 0.4

// As close as the camera comes when a shoulder is picked.
//
// Game policy, not the camera's. Over-the-shoulder framing is a close framing
// -- the sideways step is a fixed distance at the character, so it reads as a
// bigger part of the frame the nearer you are, and six units back makes the
// whole thing a shrug. `SHOULDER_OFFSET` deliberately does not scale with
// distance for exactly this reason, which leaves the choice here.
SHOULDER_DISTANCE :: 3.0

Block :: struct {
	position: [3]f32,
	size:     [3]f32,
	color:    [4]f32,
}

blocks := []Block{
	{{  5, 1.0,   3}, {1, 2, 1},   mb.LIME_GREEN},
	{{ -4, 1.5,  -2}, {2, 3, 2},   mb.CORNFLOWER_BLUE},
	{{  0, 1.0,  -8}, {6, 0.6, 1}, mb.RED},
	{{ -7, 1.0,   5}, {1, 2, 6},   mb.PUMPKIN_ORANGE},
	{{  9, 2.5,  -5}, {2, 5, 2},   mb.WHITE},
	{{ -9, 0.5, -10}, {2, 1, 2},   mb.PURPLE},
	{{  3, 0.5,   9}, {1, 1, 1},   mb.ORANGE},
}

main :: proc() {
	mb.init("Third Person", 1280, 720)
	defer mb.cleanup()

	// ESC gives the pointer back here, so it must not also close the window --
	// the same first line every mouse-look game in Matchbox needs.
	mb.set_escape_key(.UNKNOWN)

	// Where the character is and which way it is turned. Both belong to the
	// game: Matchbox places the camera and says which way the keys point, and
	// that is all it does.
	player_position := [3]f32{0, 0, 0}
	player_facing:   f32

	// Placed like any other camera, then read back into the three numbers that
	// actually drive it. That read-back is what `camera3d_orbit_angles` is for:
	// starting yaw, pitch and distance at zero instead would swing the camera
	// across the scene on the first frame of mouse motion.
	camera := mb.camera3d_at(position = {0, 4, 7}, target = {0, SHOULDER_HEIGHT, 0})
	yaw, pitch, distance := mb.camera3d_orbit_angles(camera)

	// So the character starts with its back to the camera rather than side-on.
	player_facing = yaw

	keep_off_floor := true
	shoulder       := mb.Camera3D_Shoulder.CENTER

	// Where the wheel was left while centred. Picking a shoulder pulls the
	// camera in, and going back to centred should give you back the distance
	// you chose rather than the default -- which needs remembering, because
	// `distance` itself is about to be overwritten with the closer framing.
	centred_distance := distance

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

		if !mb.cursor_locked() && mb.is_mouse_pressed(.LEFT) {
			mb.set_cursor_locked(true)
		}

		if mb.is_key_pressed(.C) do keep_off_floor = !keep_off_floor

		// Where the camera sits relative to the character. Three settings, and
		// nothing else about the camera changes with them -- same yaw, same
		// pitch, same keys.
		if mb.is_key_pressed(._1) do shoulder = .CENTER
		if mb.is_key_pressed(._2) do shoulder = .LEFT
		if mb.is_key_pressed(._3) do shoulder = .RIGHT

		// The distance that goes with the framing, which is the game's to
		// decide and not something the camera does for you. See
		// SHOULDER_DISTANCE. `min` rather than an assignment, so picking a
		// shoulder while already close does not push the camera back out.
		if mb.is_key_pressed(._1) || mb.is_key_pressed(._2) || mb.is_key_pressed(._3) {
			distance = centred_distance if shoulder == .CENTER else min(centred_distance, SHOULDER_DISTANCE)
		}

		// Only while the pointer belongs to us, for the same reason the
		// first-person example checks: the frame after ESC still carries the
		// motion that arrived before the pointer was released.
		if mb.cursor_locked() {
			// Camera-relative, which is what makes this third person rather
			// than tank controls: W is away from the camera, not along the
			// character's nose, so turning the camera turns the run.
			direction := mb.walk_direction(yaw)
			speed: f32 = RUN_SPEED if mb.is_key_held(.LSHIFT) else WALK_SPEED

			if direction != {0, 0, 0} {
				player_position += direction * speed * dt

				// Face where the keys are asking to go. Separate from the move
				// on purpose -- the character arrives instantly and turns to
				// suit, which is what it looks like when a run changes
				// direction.
				mb.turn_toward(&player_facing, mb.yaw_from_direction(direction), TURN_SPEED, dt)
			}

			focus := player_position + {0, SHOULDER_HEIGHT, 0}

			if keep_off_floor {
				// The long way round, and the shape a game with collision has:
				// take the angles, take the distance, decide for yourself how
				// much of that distance you actually get, and only then seat
				// the camera. Box3D would cast from `focus` to
				// `camera3d_orbit_position(focus, yaw, pitch, distance)` and
				// use the hit; there is no physics here, so the floor is the
				// only thing in the way and trigonometry is enough.
				mb.camera3d_look(&yaw, &pitch, mb.MOUSE_SENSITIVITY, mb.ORBIT_PITCH_MIN, mb.ORBIT_PITCH_MAX)
				mb.camera3d_zoom(&distance)
				mb.camera3d_follow(&camera, focus, yaw, pitch,
					clear_of_floor(focus, pitch, distance), shoulder)
			} else {
				// The short way: those same calls, in one.
				mb.camera3d_third_person(&camera, focus, &yaw, &pitch, &distance, shoulder)
			}

			// After the zoom, because the zoom is what there is to remember.
			// Only while centred: the wheel over a shoulder is adjusting the
			// close framing, which is not the distance to come back to.
			if shoulder == .CENTER do centred_distance = distance
		}

		/*
			What this looks like with physics, which is the point of the split:

				mb.camera3d_look(&yaw, &pitch, mb.MOUSE_SENSITIVITY,
					mb.ORBIT_PITCH_MIN, mb.ORBIT_PITCH_MAX)
				mb.camera3d_zoom(&distance)

				velocity := mb.walk_direction(yaw) * WALK_SPEED
				b3.Body_SetLinearVelocity(body, {velocity.x, 0, velocity.z})
				b3.World_Step(world, 1.0 / 60.0, 4)

				body_pos := b3.Body_GetPosition(body)
				player_position = {body_pos.x, body_pos.y, body_pos.z}
				mb.turn_toward(&player_facing,
					mb.yaw_from_direction(velocity), TURN_SPEED, dt)

				mb.camera3d_follow(&camera,
					player_position + {0, SHOULDER_HEIGHT, 0}, yaw, pitch, distance,
					shoulder)

			Note that this is the *whole* difference. Nothing above needed
			rewriting to make room for a solver, because nothing above was moved
			by Matchbox in the first place.
		*/

		mb.begin_drawing()
		mb.clear_background(mb.CORNFLOWER_BLUE)

		mb.begin_drawing_3d(camera)

		mb.draw_plane({0, 0, 0}, {60, 60}, {0.42, 0.47, 0.40, 1})
		mb.draw_grid(slices = 30, spacing = 2, color = {1, 1, 1, 0.20})

		for block in blocks {
			mb.draw_cube(block.position, block.size, block.color)
			mb.draw_cube_wires(block.position, block.size, mb.BLACK)
		}

		draw_character(player_position, player_facing)

		mb.end_drawing_3d()

		font := &mb.mbi.font
		mb.draw_text(font, "WASD to run, mouse to orbit, wheel to zoom, shift to sprint", 20, 40, mb.WHITE)
		mb.draw_text(font, "1 centred   2 over the left shoulder   3 over the right", 20, 240, mb.WHITE)

		if mb.cursor_locked() {
			mb.draw_text(font, "ESC releases the pointer", 20, 70, mb.WHITE)
		} else {
			mb.draw_text(font, "click to look again, ESC again to quit", 20, 70, mb.WHITE)
		}

		mb.draw_text(font, fmt.tprintf("yaw %.2f  pitch %.2f  distance %.1f", yaw, pitch, distance),
			20, 110, mb.WHITE)
		mb.draw_text(font, fmt.tprintf("shoulder %v", shoulder), 20, 270, mb.WHITE)
		mb.draw_text(font, fmt.tprintf("player at %.1f, %.1f  facing %.2f",
			player_position.x, player_position.z, player_facing), 20, 140, mb.WHITE)
		mb.draw_text(font, fmt.tprintf("camera at %.1f, %.1f, %.1f",
			camera.position.x, camera.position.y, camera.position.z), 20, 170, mb.WHITE)

		floor_note := "C: camera kept off the floor" if keep_off_floor else "C: camera free to sink"
		mb.draw_text(font, floor_note, 20, 210, mb.WHITE)

		mb.end_drawing()
	}

	mb.wait_idle()
}

/*
	How much of `distance` the camera actually gets, so it stays above
	`CAMERA_FLOOR`.

	Stands in for a ray cast. `camera3d_orbit_position` puts the camera at
	`focus.y - sin(pitch) * distance`, so a positive pitch -- the camera swinging
	below the character to look up at it -- is the only case that digs in, and
	the distance that just clears the floor falls straight out of that.

	A game with a physics library replaces this whole procedure with one cast
	and does not need the trigonometry.
*/
clear_of_floor :: proc(focus: [3]f32, pitch, distance: f32) -> f32 {
	drop := math.sin(pitch)
	if drop <= 0 do return distance // camera is level with the focus or above it

	room := (focus.y - CAMERA_FLOOR) / drop
	return clamp(room, 0.5, distance)
}

/*
	A person, out of three boxes, because there is no character model in this
	repository and a cube has no front.

	The torso is thin front-to-back and wide across the shoulders, so the
	rotation is visible on it; the nose is what tells you which way that is.
	Both come from `facing_rotation`, and the nose's *offset* has to be turned
	by hand -- `draw_cube` rotates a box about its own centre, so a box placed
	in front of the character in world coordinates would stay north of it while
	the character spun.
*/
draw_character :: proc(position: [3]f32, facing: f32) {
	rotation := mb.facing_rotation(facing)

	// The character's own forward, which is the flat half of
	// `direction_from_angles` and the direction yaw 0 points.
	forward := [3]f32{math.cos(facing), 0, math.sin(facing)}

	torso := position + {0, 0.65, 0}
	head  := position + {0, 1.45, 0}

	mb.draw_cube(torso, {0.45, 1.3, 0.85}, mb.MAROON, rotation)
	mb.draw_cube_wires(torso, {0.45, 1.3, 0.85}, mb.BLACK, rotation)

	mb.draw_cube(head, {0.5, 0.5, 0.5}, {0.85, 0.70, 0.55, 1}, rotation)
	mb.draw_cube_wires(head, {0.5, 0.5, 0.5}, mb.BLACK, rotation)

	mb.draw_cube(head + forward * 0.30, {0.18, 0.14, 0.30}, mb.BLACK, rotation)
}
