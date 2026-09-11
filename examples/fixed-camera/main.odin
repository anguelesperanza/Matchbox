package fixed_camera_example

/*
	Fixed camera angles, and the two ways of walking under them.

	Three spaces -- a hall, a corridor and a far room -- each with a camera placed
	by hand. The camera is never the player's: `Fixed_Camera` cuts to whichever
	shot covers the character, and `Character_Controls` decides what the stick
	means while it does. Run through the PSX filter by default, because this is
	the look the pieces exist for.

	The frame is three steps, in this order:

		character_steer   -- the stick, read under the camera the player can see
		(the walls)       -- the game's own collision, moving the character
		fixed_camera_follow -- which shot now covers where they ended up

	`character_walk` is the first two for a character with no walls. This
	example has walls, so it shows the halves, the same way the third-person
	example shows the solver version of `third_person_walk`.

	Things to try:

	  - **walk from the hall into the corridor, holding up.** The hall's camera
	    looks toward the door and the corridor's looks back from the far end, so
	    up flips meaning at the cut. Under tank controls nothing happens, because
	    tank controls never asked the camera. Under camera-relative controls the
	    character keeps walking, because the direction is held from the camera
	    the stick was pushed under
	  - **press H, and do it again.** With the hold off, the same walk reaches
	    the doorway, cuts, and turns the character straight back into the hall,
	    because up now means away from the corridor's camera. The hall's camera
	    cuts back in and up changes meaning again, so the character never gets
	    down the corridor however long up is held -- here they end up sliding
	    off along the hall's wall. That is the bug every fixed-camera game with
	    camera-relative controls has to solve, and seeing it is the fastest way
	    to see why the hold is on by default
	  - **let go in the corridor and push up again.** Now up means away from the
	    corridor's camera, toward the hall. Letting go is what hands the stick to
	    the camera on screen
	  - **walk the corridor.** Its camera is a `.TRACK` shot: it stays at the far
	    end and turns to keep you in frame. The hold also stops that turning from
	    bending a straight walk into a curve round the lens
	  - **press TAB.** Tank controls, then camera-relative. Tank: up walks the
	    way the character faces, down backs away more slowly, left and right
	    turn on the spot -- and a diagonal is full walking speed *and* full
	    turning speed at once
	  - **press Z.** Draws every shot's zone and where its camera stands. The
	    zones overlap at each doorway, which is what stops a character standing
	    on the seam from strobing between two shots
	  - **press P.** The PSX filter off and on. The HUD is drawn after it either
	    way, so the text stays sharp
	  - **hold shift** to run. A pad works too: left stick or d-pad to walk,
	    south to run, north for TAB, west for H

	The rooms are `draw_plane` and `draw_cube`, and the character is the same
	three boxes the third-person example uses.
*/

import "core:fmt"
import "core:math"

import mb "../../matchbox"

WALK_SPEED :: 3.2
RUN_SPEED  :: 6.0

// How far the character's centre keeps from a wall.
PLAYER_RADIUS :: 0.35

WALL_HEIGHT :: 3.0

FOG_COLOR :: [4]f32{0.02, 0.02, 0.04, 1}

// A rectangle on the ground, in x and z.
Area :: struct {
	min: [2]f32,
	max: [2]f32,
}

Box :: struct {
	position: [3]f32,
	size:     [3]f32,
	color:    [4]f32,
}

// The floors as drawn: the hall, the corridor, the far room.
floors := []Area{
	{min = {-12, -6},  max = {0, 6}},
	{min = {0, -1.5},  max = {16, 1.5}},
	{min = {16, -8},   max = {26, 8}},
}

floor_colors := [][4]f32{
	{0.34, 0.28, 0.22, 1},
	{0.22, 0.22, 0.26, 1},
	{0.24, 0.30, 0.24, 1},
}

/*
	Where the character's centre may stand: each floor pulled in from its walls
	by PLAYER_RADIUS.

	Not simply the floors shrunk, because shrinking each on its own leaves a gap
	at every doorway -- the hall would stop short of x = 0 and the corridor would
	start after it, with no ground a centre could cross between. So the
	corridor's runs a unit into the room at each end, and the rooms' walls are
	what stop it going further.
*/
walkable := []Area{
	{min = {-12 + PLAYER_RADIUS, -6 + PLAYER_RADIUS},  max = {0 - PLAYER_RADIUS, 6 - PLAYER_RADIUS}},
	{min = {-1, -1.5 + PLAYER_RADIUS},                 max = {17, 1.5 - PLAYER_RADIUS}},
	{min = {16 + PLAYER_RADIUS, -8 + PLAYER_RADIUS},   max = {26 - PLAYER_RADIUS, 8 - PLAYER_RADIUS}},
}

WALL :: [4]f32{0.42, 0.40, 0.38, 1}

walls := []Box{
	// The hall. Its east wall is two pieces, with the corridor's doorway between.
	{{-6, WALL_HEIGHT / 2, -6.2},    {12.4, WALL_HEIGHT, 0.4}, WALL},
	{{-6, WALL_HEIGHT / 2,  6.2},    {12.4, WALL_HEIGHT, 0.4}, WALL},
	{{-12.2, WALL_HEIGHT / 2, 0},    {0.4, WALL_HEIGHT, 12.4}, WALL},
	{{0.2, WALL_HEIGHT / 2, -3.75},  {0.4, WALL_HEIGHT, 4.5},  WALL},
	{{0.2, WALL_HEIGHT / 2,  3.75},  {0.4, WALL_HEIGHT, 4.5},  WALL},

	// The corridor.
	{{8, WALL_HEIGHT / 2, -1.7},     {16, WALL_HEIGHT, 0.4},   WALL},
	{{8, WALL_HEIGHT / 2,  1.7},     {16, WALL_HEIGHT, 0.4},   WALL},

	// The far room. Its west wall is two pieces, the other doorway between.
	{{15.8, WALL_HEIGHT / 2, -4.75}, {0.4, WALL_HEIGHT, 6.5},  WALL},
	{{15.8, WALL_HEIGHT / 2,  4.75}, {0.4, WALL_HEIGHT, 6.5},  WALL},
	{{26.2, WALL_HEIGHT / 2, 0},     {0.4, WALL_HEIGHT, 16.4}, WALL},
	{{21, WALL_HEIGHT / 2, -8.2},    {10.4, WALL_HEIGHT, 0.4}, WALL},
	{{21, WALL_HEIGHT / 2,  8.2},    {10.4, WALL_HEIGHT, 0.4}, WALL},
}

// Something to walk round and to judge the angles by. Not collided with -- the
// walls are enough to show the collision shape.
props := []Box{
	{{-9, 0.5, -4.5},  {1, 1, 1},       {0.45, 0.30, 0.16, 1}},
	{{-7.8, 0.4, -4.8}, {0.8, 0.8, 0.8}, {0.40, 0.27, 0.14, 1}},
	{{-4, 1.5, 3},     {0.8, 3, 0.8},   {0.55, 0.52, 0.48, 1}},
	{{22, 1, 0},       {1, 2, 1},       {0.75, 0.72, 0.62, 1}},
	{{19, 0.4, -6},    {2.4, 0.8, 1.2}, {0.30, 0.18, 0.10, 1}},
	{{24.5, 0.6, 6},   {1.2, 1.2, 1.2}, {0.50, 0.12, 0.10, 1}},
}

main :: proc() {
	// 4:3, because that is the shape these cameras were framed for.
	mb.init("Fixed Camera", 960, 720)
	defer mb.cleanup()

	scene, scene_err := mb.create_render_target()
	if scene_err != nil do return
	defer mb.destroy(&scene)

	mb.set_lighting({
		enabled = true,
		ambient = {color = {2.2, 2.2, 2.6, 1}},
		fog     = {enabled = true, color = FOG_COLOR, start = 6, end = 26},
	})
	mb.set_lights({
		mb.create_directional_light({0.3, -1, 0.4}, {0.25, 0.25, 0.30, 1}),
		mb.create_point_light({-6, 2.6, 0},  {1.0, 0.75, 0.45, 1}),
		mb.create_point_light({8, 2.4, 0},   {0.55, 0.65, 1.0, 1}),
		mb.create_point_light({21, 2.8, 0},  {0.85, 1.0, 0.75, 1}),
	})

	/*
		The shots. Each zone reaches three quarters of a unit past its doorway
		into the next space, so neighbouring zones overlap by a stride and a
		half -- see `fixed_camera_follow` for why an overlap is a buffer rather
		than a tie.

		Every zone runs from below the floor to above head height. The box is
		tested in all three axes, and a character's feet are at y = 0.
	*/
	rig := mb.create_fixed_camera()
	defer mb.destroy(&rig)

	// The hall, from its back corner, looking toward the doorway.
	mb.fixed_camera_add_shot(&rig, {
		position = {-11.4, 5, 5.4}, target = {-2, 0, -1}, fov = 55,
		zone_min = {-12, -1, -6}, zone_max = {0.75, 4, 6},
	})

	// The corridor, from just inside the far room, turning to watch the
	// character come toward it. The opposite way to the hall's camera, which
	// is the point: up means something else on each side of the doorway.
	//
	// Placed past the end of its own zone, so the character leaves the shot
	// before they can walk underneath the lens.
	mb.fixed_camera_add_shot(&rig, {
		position = {16.9, 2.6, 0.9}, target = {0, 1, 0}, fov = 60, aim = .TRACK,
		zone_min = {-0.75, -1, -1.5}, zone_max = {16.5, 4, 1.5},
	})

	// The far room, from high in the corner opposite its doorway.
	mb.fixed_camera_add_shot(&rig, {
		position = {25.4, 6.5, 7.4}, target = {19, 0, -2}, fov = 60,
		zone_min = {15.25, -1, -8}, zone_max = {26, 4, 8},
	})

	// On the hall camera's own line through the doorway, so that under
	// camera-relative controls, holding up from the very first frame walks
	// straight into the corridor and through the cut.
	player := [3]f32{-6, 0, 4}
	controls := mb.create_character_controls(facing = 0)

	// Seat the right shot before the first frame is drawn.
	mb.fixed_camera_follow(&rig, player)

	psx        := true
	show_zones := false

	// How long the "cut" note stays up. `rig.cut` is true for one frame, which
	// is exactly right for code and far too short to read.
	cut_note: f32

	for mb.is_running() {
		mb.poll_events()
		dt := mb.get_delta_time()

		if mb.is_key_pressed(.TAB) || mb.is_gamepad_button_pressed(0, .NORTH) {
			controls.scheme = .CAMERA_RELATIVE if controls.scheme == .TANK else .TANK
		}
		if mb.is_key_pressed(.H) || mb.is_gamepad_button_pressed(0, .WEST) {
			controls.hold_basis = !controls.hold_basis
		}
		if mb.is_key_pressed(.Z) do show_zones = !show_zones
		if mb.is_key_pressed(.P) do psx = !psx

		run := mb.is_key_held(.LSHIFT) || mb.is_gamepad_button_held(0, .SOUTH)
		speed: f32 = RUN_SPEED if run else WALK_SPEED

		/*
			The stick, read under `rig.camera` -- the camera from the last
			follow, which is the one on screen, which is the one the player
			pushed the stick while looking at. Following first and steering
			second would read this frame's input under a camera the player has
			not seen yet.
		*/
		mb.character_steer(&controls, mb.get_movement_input(), rig.camera, dt)

		// The walls. One axis at a time, so walking into a wall at an angle
		// slides along it rather than stopping dead.
		step := controls.move * speed * dt
		if is_walkable({player.x + step.x, player.z}) do player.x += step.x
		if is_walkable({player.x, player.z + step.z}) do player.z += step.z

		// Wherever the walls let them end up decides the shot.
		mb.fixed_camera_follow(&rig, player)

		if rig.cut do cut_note = 0.6
		cut_note = max(cut_note - dt, 0)

		mb.begin_drawing()

		if psx {
			mb.begin_drawing_target(&scene)
			draw_world(&rig, player, controls.facing, show_zones)
			mb.end_drawing_target()

			mb.draw_post(scene, .PSX, {320, 240})
		} else {
			draw_world(&rig, player, controls.facing, show_zones)
		}

		draw_hud(&rig, &controls, psx, show_zones, cut_note > 0)

		mb.end_drawing()
	}

	mb.wait_idle()
}

is_walkable :: proc(point: [2]f32) -> bool {
	for area in walkable {
		if point.x >= area.min.x && point.x <= area.max.x &&
		   point.y >= area.min.y && point.y <= area.max.y {
			return true
		}
	}
	return false
}

draw_world :: proc(rig: ^mb.Fixed_Camera, player: [3]f32, facing: f32, show_zones: bool) {
	mb.clear_background(FOG_COLOR)
	mb.begin_drawing_3d(rig.camera)

	for floor, index in floors {
		center := (floor.min + floor.max) * 0.5
		mb.draw_plane({center.x, 0, center.y}, floor.max - floor.min, floor_colors[index])
	}

	for wall in walls do mb.draw_cube(wall.position, wall.size, wall.color)
	for prop in props do mb.draw_cube(prop.position, prop.size, prop.color)

	draw_character(player, facing)

	if show_zones {
		for shot, index in rig.shots {
			color := mb.ORANGE if index == rig.shot else [4]f32{0.5, 0.5, 0.5, 1}
			mb.draw_bounds_wires(shot.zone_min, shot.zone_max, color)
			mb.draw_cube(shot.position, {0.3, 0.3, 0.3}, color)
		}
	}

	mb.end_drawing_3d()
}

draw_hud :: proc(rig: ^mb.Fixed_Camera, controls: ^mb.Character_Controls, psx, show_zones, cut: bool) {
	font := &mb.mbi.font
	line := [2]f32{12, 12}
	gap  := f32(32)

	mb.draw_text_plate(font, "WASD, arrows or left stick to walk, shift to run, ESC quits", line)
	line.y += gap

	switch controls.scheme {
	case .TANK:
		mb.draw_text_plate(font, "TAB  TANK -- up walks where you face, left and right turn", line)
	case .CAMERA_RELATIVE:
		mb.draw_text_plate(font, "TAB  CAMERA_RELATIVE -- up walks away from the camera", line)
	}
	line.y += gap

	hold := "on" if controls.hold_basis else "OFF -- walk through a doorway holding up"
	if controls.scheme == .TANK do hold = fmt.tprintf("%s (camera-relative only)", "on" if controls.hold_basis else "off")
	mb.draw_text_plate(font, fmt.tprintf("H    hold direction through cuts: %s", hold), line)
	line.y += gap

	mb.draw_text_plate(font, fmt.tprintf("Z    zones %s    P  PSX filter %s",
		"shown" if show_zones else "hidden", "on" if psx else "off"), line)
	line.y += gap * 1.5

	shot_text := fmt.tprintf("shot %d of %d", rig.shot + 1, len(rig.shots))
	if cut do shot_text = fmt.tprintf("%s   CUT", shot_text)
	mb.draw_text_plate(font, shot_text, line)
	line.y += gap

	// The hold made visible: the stick is being read against a heading that
	// is no longer the camera on screen.
	if controls.scheme == .CAMERA_RELATIVE && controls.basis_held {
		yaw, _ := mb.camera3d_angles(rig.camera)
		if angle_gap(controls.basis_yaw, yaw) > 0.01 {
			mb.draw_text_plate(font, "walking by an earlier camera's up -- let go to take this one", line)
		}
	}
}

// How far apart two headings are, the short way round.
angle_gap :: proc(a, b: f32) -> f32 {
	difference := math.mod(a - b + math.PI, math.TAU)
	if difference < 0 do difference += math.TAU
	return abs(difference - math.PI)
}

/*
	A person, out of three boxes -- the third-person example's, unchanged.

	The torso is thin front-to-back and wide across the shoulders, so the
	turn is visible on it; the nose is what tells you which way that is. Its
	offset is turned by hand, because `draw_cube` rotates a box about its own
	centre and a box placed in front of the character in world coordinates
	would stay put while the character spun.
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
