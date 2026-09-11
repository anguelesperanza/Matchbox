package matchbox

/*
	Movement -- tank and camera-relative
	------------------------------------
	The two ways a character is steered when the player is not holding the
	camera: it is fixed (camera3d_fixed.odin), scripted, or on a rail, and the
	stick has to mean something without it.

	**Tank controls** read the stick against the character. Up walks forward
	along whichever way the character faces, down walks back, and left and right
	turn on the spot. The camera plays no part at all -- which is exactly why
	fixed-angle games used them. A cut to a camera looking the other way changes
	nothing about what up does, so the character walks straight through the cut.

	**Camera-relative controls** read the stick against the camera: up walks
	away from it, right walks toward the right of the screen, and the character
	turns to face wherever that is. Easier to pick up, and the source of the
	famous fixed-camera bug, which `Character_Controls.hold_basis` exists to
	prevent -- see that field.

	Not the same thing as `Third_Person_Camera`'s steering, though it shares the
	angle conventions and `turn_toward`. That rig reads the keys against a
	camera the player is turning with the mouse, and turning the camera is
	supposed to turn the run. Here nobody is turning the camera, and a camera
	that turns by itself -- a cut, a `.TRACK` shot swinging round -- is exactly
	what the run must not follow.

	Like the camera rigs, this moves nothing. `character_steer` writes which way
	to go into `move`; adding that to a position, or handing it to a solver, is
	the game's. `character_walk` is the two together, for a character nothing
	else is driving.
*/

import "core:math"
import "core:math/linalg"

/*
	What the stick is read against.
*/
Control_Scheme :: enum {
	/*
		Against the character. Up and down walk along the heading, left and
		right turn. See this file's top comment.
	*/
	TANK,

	/*
		Against the camera. Up walks away from it and the body turns to face the
		way it is going. See `Character_Controls.hold_basis` for what happens on
		a cut.
	*/
	CAMERA_RELATIVE,
}

/*
	Every number `create_character_controls` starts from that
	`CAMERA3D_DEFAULTS` does not already have.

	`turn_speed` is not here because it is already there: the body turning to
	face the way it runs is the same job `Third_Person_Camera` does, and two
	defaults for one job would drift apart.
*/
Movement_Defaults :: struct {
	/*
		Radians per second a full push left or right turns a tank-controlled
		character. Three is a half turn in about a second, which is the speed the
		genre settled on: fast enough to turn to face something, slow enough that
		turning to face it is a commitment.

		Much slower than `CAMERA3D_DEFAULTS.turn_speed`, and it has to be. That
		one is a body catching up with a direction already chosen, and is meant
		to be nearly instant; this one *is* the choosing.
	*/
	tank_turn_speed: f32,

	/*
		How fast a tank-controlled character walks backwards, as a fraction of
		forward. Backing away is meant to be the worse option.
	*/
	backward_speed: f32,

	/*
		How far, in radians, the stick may swing from where it was when a
		camera-relative basis was taken before the basis is let go. See
		`Character_Controls.hold_basis`.

		A third of a half turn, which is a little over the 45 degrees between
		keyboard directions. That margin is the reason for the number: holding W
		and adding D is a correction, not a new intention, and should not throw
		away the camera the run started under -- while swinging from W to D
		outright is ninety degrees and does.
	*/
	hold_tolerance: f32,
}

MOVEMENT_DEFAULTS :: Movement_Defaults{
	tank_turn_speed = 3,
	backward_speed  = 0.6,
	hold_tolerance  = math.PI / 3,
}

/*
	A character's heading, and how the stick steers it.

	The same shape as the camera rigs: one struct, one constructor with every
	argument defaulted, and procedures taking a pointer. What is not in here is
	the character's position, for the reason given everywhere in camera3d.odin --
	it comes from the game, usually from a solver.

	`scheme` is a plain field, meant to be flipped from an options menu at any
	time. Nothing else needs resetting when it changes.
*/
Character_Controls :: struct {
	// Which way the character faces, as a yaw: 0 is along +x, the convention
	// every rig in camera3d.odin uses. `facing_rotation(controls.facing)` is the
	// quaternion to draw them with.
	facing: f32,

	/*
		Which way this frame's input asked to go, flat on the ground, with a
		length from 0 to 1 -- a stick pushed halfway asks for half. Multiply by a
		speed, or hand it to a solver as a velocity. Written by
		`character_steer`.

		Under `.TANK` a character walking backwards has a shorter `move` than
		one walking forwards, by `backward_speed`, so the same speed multiplied in
		gives the slower back-step without the game special-casing it.
	*/
	move: [3]f32,

	scheme: Control_Scheme,

	// `.TANK`: radians per second at full turn, and the backwards fraction.
	// See `Movement_Defaults`.
	tank_turn_speed: f32,
	backward_speed:  f32,

	// `.CAMERA_RELATIVE`: how fast the body turns to face the way it runs, in
	// radians per second.
	turn_speed: f32,

	/*
		`.CAMERA_RELATIVE`: whether to keep reading the stick against the camera
		it was first pushed under, until it is let go.

		The problem this solves. A character walks toward the edge of a shot,
		holding up, which here means away from the camera. They cross into the
		next shot, and its camera is looking the other way. Read against the new
		camera, up now means back where they came from -- so the character turns
		round, walks back across the line, the camera cuts back, up means forward
		again, and the character stands on the seam turning in place for as long
		as the stick is held. Every fixed-camera game with camera-relative
		controls has to answer this.

		The answer is to not re-read the camera while the player's intention has
		not changed. When the stick first leaves centre, the camera's heading is
		taken as the *basis*, and the stick is read against that basis until the
		stick returns to centre or swings further than `hold_tolerance` from where
		it started. Held up through a cut, the character keeps walking the way
		they were; let go and push up again, and up means away from the camera
		now on screen.

		It also steadies a `.TRACK` shot. That camera turns as the character
		passes it, and a basis re-read every frame would bend a straight run into
		a curve round the lens.

		Off, the stick is read against whatever camera is on screen every frame,
		which is the bug above -- kept switchable because seeing it once is the
		quickest way to understand why this is on by default.
	*/
	hold_basis:     bool,
	hold_tolerance: f32,

	/*
		The hold's own state, written by `character_steer`.

		`basis_yaw` is the camera heading the stick is being read against;
		`basis_input` is the stick as it was when that heading was taken; and
		`basis_held` is whether a basis is currently being held -- true while
		the stick is pushed, false while it rests. A game shows "still walking by
		the old camera" by comparing `basis_yaw` with the camera on screen.
	*/
	basis_yaw:   f32,
	basis_input: [2]f32,
	basis_held:  bool,
}

/*
	Character controls, facing `facing`, with everything else defaulted.

		controls := mb.create_character_controls(facing = spawn_facing)
		controls := mb.create_character_controls(scheme = .CAMERA_RELATIVE)

	Tank controls unless told otherwise, since they are the scheme that works
	under any camera without further thought.
*/
create_character_controls :: proc(
	facing:          f32 = 0,
	scheme:          Control_Scheme = .TANK,
	tank_turn_speed: f32 = MOVEMENT_DEFAULTS.tank_turn_speed,
	backward_speed:  f32 = MOVEMENT_DEFAULTS.backward_speed,
	turn_speed:      f32 = CAMERA3D_DEFAULTS.turn_speed,
	hold_basis:      bool = true,
	hold_tolerance:  f32 = MOVEMENT_DEFAULTS.hold_tolerance,
) -> Character_Controls {
	return Character_Controls{
		facing          = facing,
		scheme          = scheme,
		tank_turn_speed = tank_turn_speed,
		backward_speed  = backward_speed,
		turn_speed      = turn_speed,
		hold_basis      = hold_basis,
		hold_tolerance  = hold_tolerance,
	}
}

/*
	The movement the player is asking for this frame, from the keys and a pad.

	`x` is right and `y` is up -- *up is positive*, unlike `get_gamepad_stick`,
	whose y follows the screen. That stick reads as a position on a screen; this
	reads as a direction to walk, and forward being positive is what makes
	`input.y * speed` walk forward.

	WASD and the arrow keys both, and pad `pad`'s left stick and d-pad. They are
	added together and each axis clamped to -1..1, so pressing W and the up
	arrow at once is not twice as fast. Pass `pad = -1` to leave the pads out.

	**Each axis is clamped on its own, not the length.** A diagonal of keys comes
	back as {1, 1}, not scaled down to a length of one, because the two schemes
	want different things from it. Tank controls read the axes as two separate
	controls -- walk at full speed *and* turn at full speed -- and a normalised
	diagonal would make both slower. `character_steer` limits the length itself
	for the camera-relative scheme, where a diagonal is one direction and must
	not be faster than a straight line.
*/
get_movement_input :: proc(pad: int = 0) -> [2]f32 {
	input: [2]f32

	if is_key_held(.W) || is_key_held(.UP)    do input.y += 1
	if is_key_held(.S) || is_key_held(.DOWN)  do input.y -= 1
	if is_key_held(.D) || is_key_held(.RIGHT) do input.x += 1
	if is_key_held(.A) || is_key_held(.LEFT)  do input.x -= 1

	if is_gamepad_connected(pad) {
		stick := get_gamepad_stick(pad, .LEFT)
		input += {stick.x, -stick.y} // the stick's y is down-positive

		if is_gamepad_button_held(pad, .DPAD_UP)    do input.y += 1
		if is_gamepad_button_held(pad, .DPAD_DOWN)  do input.y -= 1
		if is_gamepad_button_held(pad, .DPAD_RIGHT) do input.x += 1
		if is_gamepad_button_held(pad, .DPAD_LEFT)  do input.x -= 1
	}

	return {clamp(input.x, -1, 1), clamp(input.y, -1, 1)}
}

/*
	Turns the character and works out `move` from `input`, under `camera`.

	`input` is shaped like `get_movement_input`'s answer -- x right, y up -- and
	may come from anywhere: a replay, an AI, a remapped control. `camera` is the
	one on screen, and is read only by `.CAMERA_RELATIVE`; `.TANK` ignores it.

	Moves nothing. Afterwards `facing` and `move` are this frame's, and what
	happens next is the game's: add `move * speed * delta_time` to a position, or
	give `move * speed` to a solver.

	Under `.TANK`, right always turns the character clockwise seen from above,
	walking forwards or backwards. A car would reverse the turn when reversing;
	the genre does not, because the character is not steering by the feet but
	turning on the spot and then walking.
*/
character_steer :: proc(controls: ^Character_Controls, input: [2]f32, camera: Camera3D, delta_time: f32) {
	switch controls.scheme {
	case .TANK:
		// Per axis -- see `get_movement_input` for why not the length.
		stick := [2]f32{clamp(input.x, -1, 1), clamp(input.y, -1, 1)}

		// No basis is held under tank controls, so switching to
		// `.CAMERA_RELATIVE` mid-stride takes the camera on screen at the next
		// push rather than one from before the switch.
		controls.basis_held = false

		controls.facing += stick.x * controls.tank_turn_speed * delta_time

		throttle := stick.y
		if throttle < 0 do throttle *= controls.backward_speed

		// After the turn, so this frame's step goes the way the character now
		// faces rather than the way they faced a frame ago.
		forward := [3]f32{math.cos(controls.facing), 0, math.sin(controls.facing)}
		controls.move = forward * throttle

	case .CAMERA_RELATIVE:
		// By length: a diagonal is one direction, and must not be faster than
		// a straight line.
		stick := input
		if length := linalg.length(stick); length > 1 do stick /= length

		yaw := character_basis_yaw(controls, stick, camera)

		// The same pair `walk_direction` builds: forward along the yaw, right a
		// quarter turn clockwise from it, which for a camera with +y up is
		// exactly `camera3d_right`.
		forward := [3]f32{math.cos(yaw), 0, math.sin(yaw)}
		right   := [3]f32{-math.sin(yaw), 0, math.cos(yaw)}

		controls.move = forward * stick.y + right * stick.x

		// Face the way the run goes, and only while running -- a character
		// who stops keeps the heading they had rather than swinging round to
		// the camera.
		if controls.move != {0, 0, 0} {
			turn_toward(&controls.facing, yaw_from_direction(controls.move), controls.turn_speed, delta_time)
		}
	}
}

/*
	`character_steer` with this frame's `get_movement_input`, and the move added
	to `position` -- the whole frame, for a character nothing else is driving.

	The counterpart of `third_person_walk`, with the same warning: it writes
	`position`, which a game with collision cannot allow. Such a game calls
	`character_steer`, moves the character by `move` itself -- against its walls
	or through its solver -- and then hands the result to
	`fixed_camera_follow`.

	`speed` is units per second.
*/
character_walk :: proc(
	controls:   ^Character_Controls,
	position:   ^[3]f32,
	speed:      f32,
	camera:     Camera3D,
	delta_time: f32,
	pad:        int = 0,
) {
	character_steer(controls, get_movement_input(pad), camera, delta_time)

	position^ += controls.move * speed * delta_time
}

/*
	The heading to read a camera-relative stick against this frame, holding a
	basis through cuts when `hold_basis` is on. See that field for why.
*/
@(private)
character_basis_yaw :: proc(controls: ^Character_Controls, stick: [2]f32, camera: Camera3D) -> f32 {
	camera_yaw, ok := camera_ground_yaw(camera)

	// A camera with no usable heading -- see camera_ground_yaw -- reads as the
	// basis already held, rather than as east.
	if !ok do camera_yaw = controls.basis_yaw

	// The stick at rest, or near enough. A basis is only ever taken from a
	// pushed stick, so every later angle test has a real direction to measure.
	resting := linalg.length2(stick) < 1e-6

	if !controls.hold_basis || resting {
		controls.basis_yaw   = camera_yaw
		controls.basis_input = stick
		controls.basis_held  = false
		return camera_yaw
	}

	if !controls.basis_held || stick_swing(stick, controls.basis_input) > controls.hold_tolerance {
		controls.basis_yaw   = camera_yaw
		controls.basis_input = stick
		controls.basis_held  = true
	}

	return controls.basis_yaw
}

/*
	Which way "away from the camera" points on the ground, as a yaw.

	Normally that is the camera's forward with the height taken out. A camera
	looking straight down has no forward left once the height is gone, and
	for that one the top of the screen is the camera's `up`, flattened the same
	way -- which is why a straight-down camera has to be given an `up` other than
	+y in the first place. Only a camera whose forward *and* up are both
	vertical has no heading at all, and that is a camera `camera3d_view` cannot
	build a matrix for either; `ok` is false for it.
*/
@(private)
camera_ground_yaw :: proc(camera: Camera3D) -> (yaw: f32, ok: bool) {
	forward := camera.target - camera.position
	if length := linalg.length(forward); length > 0 {
		forward /= length
		if forward.x * forward.x + forward.z * forward.z > 1e-6 {
			return math.atan2(forward.z, forward.x), true
		}
	}

	up := camera3d_defaults(camera).up
	if length := linalg.length(up); length > 0 {
		up /= length
		if up.x * up.x + up.z * up.z > 1e-6 {
			return math.atan2(up.z, up.x), true
		}
	}

	return 0, false
}

// The angle between two stick directions, in radians. Both must be non-zero.
@(private)
stick_swing :: proc(a, b: [2]f32) -> f32 {
	cosine := linalg.dot(a, b) / (linalg.length(a) * linalg.length(b))
	return math.acos(clamp(cosine, -1, 1))
}
