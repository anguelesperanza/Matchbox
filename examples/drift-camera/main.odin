package drift_camera_example

/*
	A camera that follows you around a town without ever being yours.

	One open square in the fog, one camera placement, and no cuts. `Drift_Camera`
	keeps the angle the level gave it and is dragged along behind the character:
	inside `dead_zone` they move and it does not, and outside it the camera is
	pulled after them at `follow_speed`, always stopping a dead zone short. That
	is the camera an early survival-horror game walks you around a town with,
	and it is the piece `examples/fixed-camera` does not have -- hand-placed
	shots need a room to be placed in, and a square this size would need a
	dozen of them and a cut every few paces.

	The frame is three steps, in this order:

		character_steer     -- the stick, read under the camera on screen
		(the buildings)     -- the game's own collision, moving the character
		drift_camera_follow -- where the camera ends up given where they did

	The debug overlay is the point of this example. It draws the anchor the
	camera orbits, the dead zone around it and the leash between anchor and
	character, so what the numbers do is visible rather than felt.

		                       keyboard        pad
		walk                   WASD or arrows  left stick or d-pad
		run                    hold shift      hold A
		tank / camera-rel.     TAB             Y
		lazy swing on and off  X               X
		dead zone  -- / ++     [ and ]         --
		follow speed -- / ++   , and .         --
		overlay                Z               Back
		PSX filter             P               Start
		warp across the square T               B
		warp without a snap    G               --
		quit                   ESC             --

	The two tuning pairs are keyboard-only on purpose: the d-pad is already the
	stick, and taking it for the dead zone would mean letting go of walking to
	tune the thing you can only judge while walking.

	Things to try:

	  - **take one step and stop.** Nothing moves. Inside the dead zone the
	    camera is not eased toward you gently, it is not moved at all, and that
	    is what stops a scene from sliding an inch under every footfall
	  - **now walk somewhere.** The camera comes after you, settles a little
	    behind, and leaves you standing off-centre on the side you walked in
	    from. Walk back and it is the other side. Nothing else here frames a
	    character that way
	  - **press Z and watch the ring.** The anchor is what the camera looks at,
	    the ring is the dead zone around it, and the leash is drawn from one to
	    the other. Walking out of the ring drags it; the ring never catches you
	  - **hold shift and run.** The gap opens up, and closes again when you
	    stop. How far the camera sits behind a *walking* character is
	    `dead_zone + speed / follow_speed`, not `dead_zone` -- the leash is what
	    the anchor is chasing, and while you keep moving it never arrives. The
	    HUD prints both that prediction and the gap as measured
	  - **press , a few times.** At a follow speed of 1 the camera is half a
	    square behind you and the town reads as something you are getting away
	    from. Keep going to 0 and it stops following at all, which is the zero
	    value's documented meaning rather than a special case
	  - **press X.** The lazy swing, off by default. The camera starts creeping
	    round to look the way you are walking -- a quarter of a radian a second,
	    so a long street turns it and a turn on the spot does not. Switch it off
	    again and the angle you are left with is the new one; nothing springs
	    back
	  - **press T, then G.** T warps you across the square and snaps the camera
	    with you, which is what a door or a cutscene wants. G warps you and
	    leaves the camera where it was, so it crawls the whole way across the
	    fog to catch up. That crawl is why `drift_camera_snap` exists
	  - **press TAB.** Tank controls, then camera-relative. `hold_basis` is doing
	    much less work here than in the fixed-camera example: this camera never
	    cuts, so "away from the camera" only ever creeps, and it creeps at the
	    speed you can see under X

	The buildings are `draw_cube` and the character is the same three boxes the
	third-person and fixed-camera examples use.
*/

import "core:fmt"
import "core:math"
import "core:math/linalg"

import mb "../../matchbox"

WALK_SPEED :: 3.2
RUN_SPEED  :: 6.4

// How far the character's centre keeps from a wall.
PLAYER_RADIUS :: 0.4

FOG_COLOR :: [4]f32{0.05, 0.055, 0.06, 1}

// How fast the lazy swing turns, in radians per second, when it is switched on.
// Slow enough that walking a street turns the camera and turning on the spot
// does not.
SWING :: 0.25

// A rectangle on the ground, in x and z.
Rect :: struct {
	min: [2]f32,
	max: [2]f32,
}

Box :: struct {
	position: [3]f32,
	size:     [3]f32,
	color:    [4]f32,
}

// The square itself: where the character may walk, before the buildings take
// their bites out of it.
plaza := Rect{min = {-24, -18}, max = {24, 18}}

// The blocks around the edge, with the gaps between them reading as streets.
// Their footprints are what the character collides with -- derived below rather
// than written twice, because a building drawn in one place and collided with
// in another is a wall you can walk through in the fog and never work out why.
buildings := []Box{
	{{-17, 4.0, -14}, {14, 8.0, 8},  {0.20, 0.19, 0.18, 1}},
	{{  1, 5.0, -15}, {10, 10.0, 6}, {0.17, 0.17, 0.19, 1}},
	{{ 17, 3.5, -13}, {12, 7.0, 10}, {0.21, 0.19, 0.17, 1}},
	{{-19, 4.5,  13}, {10, 9.0, 10}, {0.18, 0.18, 0.17, 1}},
	{{ -2, 3.0,  15}, {14, 6.0, 6},  {0.20, 0.18, 0.16, 1}},
	{{ 18, 4.0,  14}, {10, 8.0, 8},  {0.17, 0.18, 0.19, 1}},

	// One block out in the middle, so there is something to walk round and
	// judge the drift against rather than only open ground.
	{{0, 1.2, 1}, {5, 2.4, 5}, {0.23, 0.22, 0.20, 1}},
}

// The lamps, and the light each one casts. Positions are the foot of the post.
lamps := [][3]f32{
	{-12, 0, -4},
	{ 10, 0, -6},
	{ -8, 0,  9},
	{ 13, 0,  7},
}

LAMP_HEIGHT :: 4.0

main :: proc() {
	// 4:3, because that is the shape this camera was framed for.
	mb.init("Drift Camera", 960, 720)
	defer mb.cleanup()

	scene, scene_err := mb.create_render_target()
	if scene_err != nil do return
	defer mb.destroy(&scene)

	mb.set_lighting({
		enabled = true,
		ambient = {color = {0.9, 0.95, 1.1, 1}},

		// Close fog, because a camera this far back needs the far side of the
		// square to be suggestion rather than geometry -- and because it is
		// what the look is made of.
		fog = {enabled = true, color = FOG_COLOR, start = 7, end = 34},
	})

	lights := make([dynamic]mb.Light)
	defer delete(lights)

	// A moon, and a warm lamp at the top of each post.
	append(&lights, mb.create_directional_light({0.3, -1, 0.2}, {0.16, 0.17, 0.22, 1}))
	for lamp in lamps {
		append(&lights, mb.create_point_light(lamp + {0, LAMP_HEIGHT, 0}, {1.0, 0.72, 0.38, 1}))
	}
	mb.set_lights(lights[:])

	/*
		One placement for the whole square.

		The angle is high and off to one side, looking down a diagonal: high
		enough that a building does not swallow the character, and off-axis so
		the streets run across the frame rather than straight away from it. It
		is the level's angle, and nothing the player does will change it -- the
		swing under X is the only thing that ever will.

		`follow_speed` is slower than the default here. The default is tuned for
		a character you are meant to keep up with; a town you are wandering
		round wants the camera a little further behind than that.
	*/
	player   := [3]f32{-6, 0, 6}
	teleport := [3]f32{16, 0, -4}

	rig := mb.create_drift_camera(player,
		yaw          = -2.2,
		pitch        = -0.34,
		distance     = 9.5,
		dead_zone    = 2,
		follow_speed = 2.2)

	controls := mb.create_character_controls(facing = -math.PI * 0.5)

	psx     := true
	overlay := false

	for mb.is_running() {
		mb.poll_events()
		dt := mb.get_delta_time()

		// Pad 0's buttons beside each key, named by position: `.NORTH` is
		// whichever button sits at the top, which is Y on an Xbox pad.
		if mb.is_key_pressed(.TAB) || mb.is_gamepad_button_pressed(0, .NORTH) {
			controls.scheme = .CAMERA_RELATIVE if controls.scheme == .TANK else .TANK
		}
		if mb.is_key_pressed(.X) || mb.is_gamepad_button_pressed(0, .WEST) {
			rig.swing_speed = 0 if rig.swing_speed > 0 else SWING
		}
		if mb.is_key_pressed(.Z) || mb.is_gamepad_button_pressed(0, .BACK)  do overlay = !overlay
		if mb.is_key_pressed(.P) || mb.is_gamepad_button_pressed(0, .START) do psx = !psx

		// Tuning, live. Clamped at zero on both counts: a negative dead zone is
		// read as none and a negative follow speed as no follow, and letting
		// somebody hold a key into either is a camera that looks broken for a
		// reason nothing on screen explains.
		if mb.is_key_pressed(.LEFTBRACKET)  do rig.dead_zone = max(rig.dead_zone - 0.5, 0)
		if mb.is_key_pressed(.RIGHTBRACKET) do rig.dead_zone = min(rig.dead_zone + 0.5, 8)
		if mb.is_key_pressed(.COMMA)        do rig.follow_speed = max(rig.follow_speed - 0.4, 0)
		if mb.is_key_pressed(.PERIOD)       do rig.follow_speed = min(rig.follow_speed + 0.4, 12)

		// The two warps, and the difference between them is the whole argument
		// for `drift_camera_snap`.
		if mb.is_key_pressed(.T) || mb.is_gamepad_button_pressed(0, .EAST) {
			player, teleport = teleport, player
			mb.drift_camera_snap(&rig, player)
		}
		if mb.is_key_pressed(.G) {
			player, teleport = teleport, player
		}

		run := mb.is_key_held(.LSHIFT) || mb.is_gamepad_button_held(0, .SOUTH)
		speed: f32 = RUN_SPEED if run else WALK_SPEED

		/*
			The stick, read under `rig.camera` -- the camera from the last
			follow, which is the one on screen, which is the one the player
			pushed the stick while looking at. Following first and steering
			second would read this frame's input under a camera nobody has seen.
		*/
		mb.character_steer(&controls, mb.get_movement_input(), rig.camera, dt)

		// The buildings. One axis at a time, so walking into a corner at an
		// angle slides along it rather than stopping dead.
		step := controls.move * speed * dt
		if is_walkable({player.x + step.x, player.z}) do player.x += step.x
		if is_walkable({player.x, player.z + step.z}) do player.z += step.z

		// Wherever the buildings let them end up is what the camera answers to.
		mb.drift_camera_follow(&rig, player, dt)

		mb.begin_drawing()

		if psx {
			mb.begin_drawing_target(&scene)
			draw_world(&rig, player, controls.facing, overlay)
			mb.end_drawing_target()

			mb.draw_post(scene, .PSX, {320, 240})
		} else {
			draw_world(&rig, player, controls.facing, overlay)
		}

		draw_hud(&rig, &controls, player, speed, psx, overlay)

		mb.end_drawing()
	}

	mb.wait_idle()
}

// Inside the square and out of every building. The buildings are grown by
// PLAYER_RADIUS rather than the character being tested as a box, which is the
// same trick and one rectangle's worth of arithmetic.
is_walkable :: proc(point: [2]f32) -> bool {
	if point.x < plaza.min.x + PLAYER_RADIUS || point.x > plaza.max.x - PLAYER_RADIUS do return false
	if point.y < plaza.min.y + PLAYER_RADIUS || point.y > plaza.max.y - PLAYER_RADIUS do return false

	for building in buildings {
		footprint := footprint_of(building, PLAYER_RADIUS)
		if point.x >= footprint.min.x && point.x <= footprint.max.x &&
		   point.y >= footprint.min.y && point.y <= footprint.max.y {
			return false
		}
	}

	return true
}

// A drawn box's shadow on the ground, grown by `margin`. The single source of
// truth for where a building is: it is drawn from the same numbers.
footprint_of :: proc(box: Box, margin: f32 = 0) -> Rect {
	half := [2]f32{box.size.x, box.size.z} * 0.5 + margin
	return Rect{
		min = {box.position.x - half.x, box.position.z - half.y},
		max = {box.position.x + half.x, box.position.z + half.y},
	}
}

draw_world :: proc(rig: ^mb.Drift_Camera, player: [3]f32, facing: f32, overlay: bool) {
	mb.clear_background(FOG_COLOR)
	mb.begin_drawing_3d(rig.camera)

	center := (plaza.min + plaza.max) * 0.5
	mb.draw_plane({center.x, 0, center.y}, plaza.max - plaza.min, {0.13, 0.13, 0.14, 1})

	// Paving. Not decoration: a camera that drifts by half a metre over two
	// seconds is invisible over flat ground and obvious over lines.
	mb.draw_grid(24, 2, {0.35, 0.35, 0.38, 0.30})

	for building in buildings do mb.draw_cube(building.position, building.size, building.color)

	for lamp in lamps {
		mb.draw_cube(lamp + {0, LAMP_HEIGHT * 0.5, 0}, {0.18, LAMP_HEIGHT, 0.18}, {0.16, 0.16, 0.17, 1})
		mb.draw_sphere(lamp + {0, LAMP_HEIGHT, 0}, 0.22, {1.0, 0.85, 0.55, 1})
	}

	draw_character(player, facing)

	if overlay {
		// Just off the ground, so the plane does not fight it for the same
		// depth -- the anchor sits at the character's feet, which is exactly
		// where the floor is.
		anchor := rig.anchor + {0, 0.03, 0}

		draw_ring(anchor, rig.dead_zone, mb.ORANGE)
		mb.draw_cube(anchor, {0.3, 0.06, 0.3}, mb.ORANGE)

		// The leash: how far out of its dead zone the character has pulled the
		// camera. Nothing when they are inside it, which is the state worth
		// seeing.
		draw_leash(anchor, player, {0.45, 0.85, 1.0, 1})
	}

	mb.end_drawing_3d()
}

// A circle on the ground out of small markers. There is no line-strip in the
// 3D shapes, and a ring of cubes is a dozen lines of example code against a new
// primitive in the package -- which the package should get for its own reasons
// rather than for a debug ring here.
draw_ring :: proc(center: [3]f32, radius: f32, color: [4]f32, segments: int = 32) {
	if radius <= 0 do return

	for index in 0 ..< segments {
		angle := f32(index) / f32(segments) * math.TAU
		point := center + {math.cos(angle) * radius, 0, math.sin(angle) * radius}
		mb.draw_cube(point, {0.16, 0.05, 0.16}, color)
	}
}

// A flat bar laid from one point to the other. `facing_rotation` turns +x to a
// heading, and the bar's length is its own x, so the two line up without any
// matrix work here.
draw_leash :: proc(from, to: [3]f32, color: [4]f32) {
	flat := [3]f32{to.x - from.x, 0, to.z - from.z}

	length := linalg.length(flat)
	if length < 0.05 do return

	middle := [3]f32{(from.x + to.x) * 0.5, from.y, (from.z + to.z) * 0.5}
	mb.draw_cube(middle, {length, 0.04, 0.08}, color, mb.facing_rotation(mb.yaw_from_direction(flat)))
}

draw_hud :: proc(
	rig:      ^mb.Drift_Camera,
	controls: ^mb.Character_Controls,
	player:   [3]f32,
	speed:    f32,
	psx:      bool,
	overlay:  bool,
) {
	font := &mb.mbi.font
	line := [2]f32{12, 12}
	gap  := f32(32)

	mb.draw_text_plate(font, "walk: WASD, arrows, left stick or d-pad    run: shift or pad A    quit: ESC", line)
	line.y += gap

	switch controls.scheme {
	case .TANK:
		mb.draw_text_plate(font, "TAB / pad Y   TANK -- up walks where you face, left and right turn", line)
	case .CAMERA_RELATIVE:
		mb.draw_text_plate(font, "TAB / pad Y   CAMERA_RELATIVE -- up walks away from the camera", line)
	}
	line.y += gap

	swing := "off -- the angle is the level's"
	if rig.swing_speed > 0 {
		swing = fmt.tprintf("%.2f rad/s -- creeping round to the walk", rig.swing_speed)
	}
	mb.draw_text_plate(font, fmt.tprintf("X / pad X     lazy swing: %s", swing), line)
	line.y += gap

	mb.draw_text_plate(font, fmt.tprintf("[ ]           dead zone %.1f        , .   follow speed %.1f%s",
		rig.dead_zone, rig.follow_speed,
		"  -- zero, so the camera does not follow" if rig.follow_speed <= 0 else ""), line)
	line.y += gap

	mb.draw_text_plate(font, fmt.tprintf("Z / pad Back  overlay %s    P / pad Start  PSX filter %s    T / pad B  warp    G  warp without a snap",
		"shown" if overlay else "hidden", "on" if psx else "off"), line)
	line.y += gap * 1.5

	/*
		The measurement the docs promise, live: a character walking at `speed`
		is followed from `dead_zone + speed / follow_speed` back. Standing still
		it settles to the dead zone instead, so the prediction is only shown
		while the feet are moving -- printing it beside a gap that is closing to
		something else would read as the prediction being wrong.
	*/
	trail := linalg.length([3]f32{player.x - rig.anchor.x, 0, player.z - rig.anchor.z})

	if controls.move != {0, 0, 0} && rig.follow_speed > 0 {
		mb.draw_text_plate(font, fmt.tprintf("trailing by %.2f    walking, settles at dead_zone + speed/follow_speed = %.2f",
			trail, rig.dead_zone + speed / rig.follow_speed), line)
	} else {
		mb.draw_text_plate(font, fmt.tprintf("trailing by %.2f    standing still, settles at the dead zone = %.2f",
			trail, rig.dead_zone), line)
	}
	line.y += gap

	if trail <= rig.dead_zone {
		mb.draw_text_plate(font, "inside the dead zone -- the camera is not moving at all", line)
	}

	dims := mb.get_screen_dims()
	mb.draw_text_plate(font, "pad buttons use Xbox names -- on PlayStation, A B X Y are Cross, Circle, Square, Triangle",
		{12, dims.y - 44})
}

/*
	A person, out of three boxes -- the fixed-camera example's, unchanged.

	The torso is thin front-to-back and wide across the shoulders, so the turn is
	visible on it; the nose is what tells you which way that is. Its offset is
	turned by hand, because `draw_cube` rotates a box about its own centre and a
	box placed in front of the character in world coordinates would stay put
	while the character spun.
*/
draw_character :: proc(position: [3]f32, facing: f32) {
	rotation := mb.facing_rotation(facing)
	forward  := [3]f32{math.cos(facing), 0, math.sin(facing)}

	torso := position + {0, 0.65, 0}
	head  := position + {0, 1.45, 0}

	mb.draw_cube(torso, {0.45, 1.3, 0.85}, mb.MAROON, rotation)
	mb.draw_cube(head, {0.5, 0.5, 0.5}, {0.85, 0.70, 0.55, 1}, rotation)
	mb.draw_cube(head + forward * 0.30, {0.18, 0.14, 0.30}, mb.BLACK, rotation)
}
