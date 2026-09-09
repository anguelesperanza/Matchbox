package third_person_example

/*
	The same walk as `examples/first-person`, from behind.

	A third-person camera is the first-person one pushed backwards: the same
	yaw, the same pitch, the same `camera3d_look` producing both, and then a
	distance that seats the camera that far back along the direction those two
	describe. What is new is that something is standing in front of it, and the
	something has to be turned to face the way it is running.

	All of that lives in a `Third_Person_Camera`, which is what this example
	uses: one struct, one call to set it up, one call a frame. The loose
	procedures it is built out of are still there and still the right thing for
	a game that keeps its own yaw and pitch -- `camera3d_look`, `camera3d_zoom`,
	`camera3d_follow`, `walk_direction`, `turn_toward` -- and the physics block
	further down shows the two halves the one call is made of.

	Things to try:

	  - **walk in a circle.** The character turns to face where it is going
	    rather than snapping, which is `turn_toward` -- and it turns the short
	    way even when the two angles are written a full turn apart
	  - **press F.** Cycles the three steering settings, which differ in what the
	    body does rather than in where the camera is.

	    `.CAMERA` is the default: W goes away from the camera and the character
	    turns to face wherever the keys sent it, so holding D swings it a
	    quarter turn and it runs off that way.

	    `.STRAFE` reads the keys the same but keeps the body facing the camera,
	    so A and D side-step instead of turning into the step. Try it over a
	    shoulder -- press 3 first -- which is the pair every third-person
	    shooter offers. Standing still and turning the camera still turns the
	    body, because aiming does not stop when the feet do.

	    `.CHARACTER` reads them against the character's own heading instead:
	    hold W, look left, and you carry straight on while the camera swings
	    round to watch from the side. **Q and E** turn the character in that
	    setting, because nothing else does -- which is the point of it
	  - **press 1, 2 and 3.** Centred, over the left shoulder, over the right.
	    The rig slides sideways rather than turning, so the view direction is
	    unchanged and the character just stops being in the middle of it
	  - **stand behind the tall white box and lean out.** Which shoulder you are
	    on decides which side of it you can see past, which is the whole reason
	    a game offers both
	  - **scroll.** The wheel pulls the camera in and out between 1.5 and 20
	    units. Keep going in and it becomes first person with a body in the way,
	    which is the same thing this always was
	  - **look up.** It stops early -- `CAMERA3D_DEFAULTS.orbit_pitch_max` is 0.30,
	    not `pitch_limit` -- because pitching up on an orbit camera swings it
	    *under* the character rather than tilting a head, and the floor is down
	    there
	  - **press C.** Toggles the camera keeping out of the floor. With it off,
	    look up at full pitch and the ground swallows the view. With it on, the
	    rig is seated a second time at a shorter distance -- which is the
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

WALK_SPEED :: 6.0
RUN_SPEED  :: 11.0

// Radians per second Q and E turn the character at, under `.CHARACTER`
// steering. Slower than the rig's own `turn_speed`, because that one is
// catching up with a direction already chosen and this one *is* the choosing.
TURN_KEY_SPEED :: 2.5

// How far above the ground the camera is kept when C is on.
CAMERA_FLOOR :: 0.4

// As close as the camera comes when a shoulder is picked.
//
// Game policy, not the camera's. Over-the-shoulder framing is a close framing
// -- the sideways step is a fixed distance at the character, so it reads as a
// bigger part of the frame the nearer you are, and six units back makes the
// whole thing a shrug. The shoulder offset deliberately does not scale with
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

	// ESC gives the pointer back here, so it must not also close the window --
	// the same first line every mouse-look game in Matchbox needs.
	mb.set_escape_key(.UNKNOWN)

	// Where the character is. This stays the game's: the rig follows a position
	// it is handed and never writes one of its own, which is what lets a solver
	// have the last word on it.
	player_position := [3]f32{0, 0, 0}

	// Everything else -- the angles, the distance, the framing, the steering,
	// the character's heading and the Camera3D itself. One call, and the camera
	// is already seated behind the character before the loop starts.
	//
	// The arguments not named here are the defaults: centred, six units back,
	// looking slightly down, camera-steered, looking at head height. Facing
	// -pi/2 is along -z, so the character starts with its back to the camera
	// and the blocks in front of it.
	rig := mb.create_third_person_camera(
		position = player_position,
		facing   = -math.PI * 0.5,
	)

	keep_off_floor := true

	// Where the wheel was left while centred. Picking a shoulder pulls the
	// camera in, and going back to centred should give you back the distance
	// you chose rather than the default -- which needs remembering, because
	// `rig.distance` is about to be overwritten with the closer framing.
	centred_distance := rig.distance

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

		if !mb.is_cursor_locked() && mb.is_mouse_pressed(.LEFT) {
			mb.set_cursor_locked(true)
		}

		if mb.is_key_pressed(.C) do keep_off_floor = !keep_off_floor

		// What the body does. The one field, and nothing else about the camera
		// changes with it.
		if mb.is_key_pressed(.F) {
			switch rig.steering {
			case .CAMERA:    rig.steering = .STRAFE
			case .STRAFE:    rig.steering = .CHARACTER
			case .CHARACTER: rig.steering = .CAMERA
			}
		}

		// Where the camera sits relative to the character. Three settings, and
		// nothing else about the camera changes with them either.
		if mb.is_key_pressed(._1) do rig.shoulder = .CENTER
		if mb.is_key_pressed(._2) do rig.shoulder = .LEFT
		if mb.is_key_pressed(._3) do rig.shoulder = .RIGHT

		// The distance that goes with the framing, which is the game's to
		// decide and not something the camera does for you. See
		// SHOULDER_DISTANCE. `min` rather than an assignment, so picking a
		// shoulder while already close does not push the camera back out.
		if mb.is_key_pressed(._1) || mb.is_key_pressed(._2) || mb.is_key_pressed(._3) {
			rig.distance = centred_distance if rig.shoulder == .CENTER else min(centred_distance, SHOULDER_DISTANCE)
		}

		// Only while the pointer belongs to us, for the same reason the
		// first-person example checks: the frame after ESC still carries the
		// motion that arrived before the pointer was released.
		if mb.is_cursor_locked() {
			// Under `.CHARACTER` steering nothing turns the character -- that
			// is what the setting means -- so the turn keys are the game's to
			// provide. `facing` is a plain field and this is all it takes.
			if rig.steering == .CHARACTER {
				if mb.is_key_held(.Q) do rig.facing -= TURN_KEY_SPEED * dt
				if mb.is_key_held(.E) do rig.facing += TURN_KEY_SPEED * dt
			}

			speed: f32 = RUN_SPEED if mb.is_key_held(.LSHIFT) else WALK_SPEED

			// Mouse, wheel, keys, the move, the turn and the camera, for a
			// character nothing else is driving.
			mb.third_person_walk(&rig, &player_position, speed, dt)

			// Something is between the camera and the character -- the floor,
			// here -- so the rig is seated a second time, shorter. This is the
			// shape of the real thing: follow, find out what is in the way,
			// follow again. A game with physics casts from the focus to
			// `camera3d_orbit_position` instead of looking at one coordinate.
			if keep_off_floor && rig.camera.position.y < CAMERA_FLOOR {
				focus := player_position + rig.focus_offset
				mb.camera3d_follow(&rig.camera, focus, rig.yaw, rig.pitch,
					clear_of_floor(focus, rig.pitch, rig.distance),
					rig.shoulder, rig.shoulder_offset)
			}

			// After the zoom, because the zoom is what there is to remember.
			// Only while centred: the wheel over a shoulder is adjusting the
			// close framing, which is not the distance to come back to.
			if rig.shoulder == .CENTER do centred_distance = rig.distance
		}

		/*
			What `third_person_walk` is, for a game whose character is a body in
			a solver:

				mb.third_person_input(&rig)

				velocity := rig.move * speed
				b3.Body_SetLinearVelocity(body, {velocity.x, 0, velocity.z})
				b3.World_Step(world, 1.0 / 60.0, 4)

				body_pos := b3.Body_GetPosition(body)
				player_position = {body_pos.x, body_pos.y, body_pos.z}

				mb.third_person_follow(&rig, player_position, dt)

			Two halves with the solver between them, which is why they are two
			procedures. `third_person_input` reads the mouse and the keys and
			writes `rig.move`; `third_person_follow` turns the character and
			seats the camera at wherever the solver decided they ended up.
			Matchbox moves nothing either way.
		*/

		mb.begin_drawing()
		mb.clear_background(mb.CORNFLOWER_BLUE)

		mb.begin_drawing_3d(rig.camera)

		mb.draw_plane({0, 0, 0}, {60, 60}, {0.42, 0.47, 0.40, 1})
		mb.draw_grid(slices = 30, spacing = 2, color = {1, 1, 1, 0.20})

		for block in blocks {
			mb.draw_cube(block.position, block.size, block.color)
			mb.draw_cube_wires(block.position, block.size, mb.BLACK)
		}

		draw_character(player_position, rig.facing)

		mb.end_drawing_3d()

		font := &mb.mbi.font
		mb.draw_text(font, "WASD to run, mouse to orbit, wheel to zoom, shift to sprint", 20, 40, mb.WHITE)

		if mb.is_cursor_locked() {
			mb.draw_text(font, "ESC releases the pointer", 20, 70, mb.WHITE)
		} else {
			mb.draw_text(font, "click to look again, ESC again to quit", 20, 70, mb.WHITE)
		}

		mb.draw_text(font, fmt.tprintf("yaw %.2f  pitch %.2f  distance %.1f",
			rig.yaw, rig.pitch, rig.distance), 20, 110, mb.WHITE)
		mb.draw_text(font, fmt.tprintf("player at %.1f, %.1f  facing %.2f",
			player_position.x, player_position.z, rig.facing), 20, 140, mb.WHITE)
		mb.draw_text(font, fmt.tprintf("camera at %.1f, %.1f, %.1f",
			rig.camera.position.x, rig.camera.position.y, rig.camera.position.z), 20, 170, mb.WHITE)

		floor_note := "C: camera kept off the floor" if keep_off_floor else "C: camera free to sink"
		mb.draw_text(font, floor_note, 20, 210, mb.WHITE)

		mb.draw_text(font, "1 centred   2 over the left shoulder   3 over the right", 20, 240, mb.WHITE)
		mb.draw_text(font, fmt.tprintf("shoulder %v", rig.shoulder), 20, 270, mb.WHITE)

		steer_note: string
		switch rig.steering {
		case .CAMERA:    steer_note = "F: steering CAMERA -- the body turns to face where it runs"
		case .STRAFE:    steer_note = "F: steering STRAFE -- the body faces the camera, A and D side-step"
		case .CHARACTER: steer_note = "F: steering CHARACTER -- W follows the heading, Q and E turn"
		}
		mb.draw_text(font, steer_note, 20, 310, mb.WHITE)

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
