package matchbox

/*
	Camera -- drifting follow
	-------------------------
	The camera an early survival-horror game uses outdoors, where the hand-placed
	shots of `Fixed_Camera` run out: it keeps the angle the level gave it and
	slides along after the character, a few paces behind, rather than being
	carried around by them.

	Two things make it that rather than a third-person camera. The angle is the
	level's and not the player's -- nothing here reads the mouse, and a character
	turning on the spot does not swing the world round them. And the camera is
	only dragged once the character has left the patch of ground it was watching:
	inside `dead_zone` they move and the camera does not, which is what stops
	every step from sliding the whole scene an inch.

	Why not the rigs already here:

	  - `Fixed_Camera` with a `.TRACK` shot stays exactly where it was put and
	    turns to follow. An open square would need a shot every few paces, and
	    every boundary between them is a cut; one drifting placement covers the
	    square.
	  - `Third_Person_Camera` hands the angle to the player and sits behind the
	    character's heading. That is the other genre. It never loses the
	    character, and it never frames anything either.
	  - The same rig with `dead_zone = 0` is a plain damped follow, and moves the
	    world on every step, however gently. The dead zone is the difference
	    between a camera that follows you and a camera that watches you.

	Like every rig in camera3d.odin this moves nothing: the character's position
	is the game's, handed in, and never written. There is also nothing to
	destroy, unlike `Fixed_Camera` and the shots it owns.

	It drives `Character_Controls` the way the fixed camera does, by handing
	`rig.camera` to `character_steer`. `hold_basis` matters far less here,
	though: it exists for the frame a cut changes what "up" means, and this
	camera never cuts. Its angle only ever creeps, at `swing_speed`, and the walk
	direction creeps with it.
*/

import "core:math"
import "core:math/linalg"

/*
	A camera at a fixed angle, dragged along behind what it is watching.

	The fields are public and may be written between frames: `pitch` and
	`distance` to tune a shot while the game runs, `yaw` to turn the camera
	somewhere else and have it creep round rather than cut.
*/
Drift_Camera :: struct {
	// What `begin_drawing_3d` takes. Written by `drift_camera_follow` and
	// `drift_camera_snap`, and seated by the constructor, so it is a real
	// camera before the first frame rather than the zero one -- whose position
	// and target are the same point, and whose view matrix is therefore built
	// from nothing.
	camera: Camera3D,

	/*
		The point the camera orbits: where the character was last watched from,
		in their own space -- their feet, not their head. `focus_offset` is added
		to it when the camera is seated.

		Not the character's position, and the whole trick of the rig. It trails
		them by up to `dead_zone`, so it is also where they were a moment ago,
		which is why the camera reads as following rather than as carried.
	*/
	anchor: [3]f32,

	// Where the camera sits relative to the anchor, as `camera3d_follow` takes
	// them: the direction it looks along, and how far back it stands.
	yaw:      f32,
	pitch:    f32,
	distance: f32,

	/*
		How far the character may stray from the anchor, on the ground plane,
		before the camera is dragged after them.

		Measured in x and z only. Height is followed directly -- see
		`drift_camera_follow` -- because a leash that included it would leave a
		character walking downstairs sinking out of the bottom of the frame.
	*/
	dead_zone: f32,

	/*
		How quickly the anchor closes on where it is being dragged to, as a rate
		per second. Bigger is tighter; a large one is a camera pinned to the edge
		of the dead zone with no lag left, so no special value is needed for
		that.

		**It sets how far behind the character the camera sits while they walk**,
		which is the thing to tune by and is not `dead_zone`: a character walking
		at `speed` is followed from `dead_zone + speed / follow_speed` back,
		because the anchor never catches a leash that keeps moving. At the
		defaults a 4-units-a-second walk trails by 2.8 rather than 1.5, and
		halving the rate takes it to 4.2 -- a different shot. Measured in
		camera3d_drift_test.odin.

		**Zero means the camera does not follow at all**, the reading
		`camera_follow` gives it in camera.odin, and a negative one is read the
		same way. A rig nobody configured therefore sits still rather than
		lurching after the first position handed to it, and a game that wants the
		camera held for a scripted moment can write a zero here instead of
		unpicking its frame.
	*/
	follow_speed: f32,

	/*
		How fast the camera turns to look the way the character is walking, in
		radians per second. Zero -- the default -- never turns it: the angle is
		the level's and stays the level's.

		A small one, a quarter of a radian a second or so, is the lazy swing an
		open area wants: walk the same way for long enough and the camera ends up
		behind you, without ever having been dragged round by a turn on the spot.
		It only turns while the character is out of the dead zone and actually
		pulling the camera along, so pacing about in a doorway leaves the shot
		alone.
	*/
	swing_speed: f32,

	// Added to the anchor to get the point the camera looks at. The same offset
	// `Third_Person_Camera` and `Fixed_Camera` use, and for the same reason: a
	// camera aimed at a character's feet puts them at the bottom of the frame.
	focus_offset: [3]f32,
}

/*
	A drift camera watching `position`, seated and ready to draw with.

	Every argument has a default, and `position` is the character's -- the rig
	starts with its anchor on them, so the first frame is already framed rather
	than swooping in from the origin:

		rig := mb.create_drift_camera(player.position, yaw = -2.2, distance = 7)

		// each frame, after the character has moved
		mb.drift_camera_follow(&rig, player.position, mb.get_delta_time())

	`yaw` is the direction the camera looks *along*, in the sense
	`camera3d_follow` uses it, so the camera itself stands on the opposite side:
	yaw 0 puts it west of the character, looking east.
*/
create_drift_camera :: proc(
	position:     [3]f32 = {0, 0, 0},
	yaw:          f32 = 0,
	pitch:        f32 = CAMERA3D_DEFAULTS.orbit_pitch,
	distance:     f32 = CAMERA3D_DEFAULTS.distance,
	dead_zone:    f32 = CAMERA3D_DEFAULTS.dead_zone,
	follow_speed: f32 = CAMERA3D_DEFAULTS.follow_speed,
	swing_speed:  f32 = CAMERA3D_DEFAULTS.swing_speed,
	focus_offset: [3]f32 = CAMERA3D_DEFAULTS.focus_offset,
	near:         f32 = 0.1,
	far:          f32 = 1000,
) -> Drift_Camera {
	rig := Drift_Camera{
		camera = Camera3D{
			up         = {0, 1, 0},
			fov        = 70,
			projection = .PERSPECTIVE,
			near       = near,
			far        = far,
		},

		yaw          = yaw,
		pitch        = pitch,
		distance     = distance,
		dead_zone    = dead_zone,
		follow_speed = follow_speed,
		swing_speed  = swing_speed,
		focus_offset = focus_offset,
	}

	drift_camera_snap(&rig, position)
	return rig
}

/*
	Drags the camera along after `position`, and seats it.

	Call it once a frame, after the character has moved, with the character's
	position -- their feet, not their head; `focus_offset` is added here.

	Three steps, and the order of them is the whole behaviour:

	  - the character is measured against the anchor on the ground plane. Inside
	    `dead_zone` there is nothing to drag, and the shot does not move at all
	  - outside it, the anchor is given a goal `dead_zone` short of the
	    character, along the line between them -- a leash, so the camera is
	    pulled by the amount the character overran it rather than sent to where
	    they are standing. That is what leaves them off-centre in the direction
	    they are walking, which is the look
	  - the anchor eases toward that goal at `follow_speed`, and the camera is
	    seated `distance` back from it along `yaw` and `pitch`

	**Height is followed with no dead zone**, because a leash in three dimensions
	is a camera that stays at first-floor height while the character walks down
	to the cellar. The easing still applies, so a step down is a settle rather
	than a drop.

	**The easing is `1 - exp(-rate * dt)`**, which gives the same curve whatever
	the frame rate and cannot overshoot. `camera_follow` in camera.odin uses the
	linear `rate * dt` clamped to 1, and says why: that API was designed around
	it and has it written on the tin. This one has no such history, so it gets
	the exact form. The two differ slightly at ordinary frame times and a lot on
	a stalled frame, where the linear form would have been clamped into a snap.

	A teleport wants `drift_camera_snap` instead, which this would answer by
	walking the camera across the level to catch up.
*/
drift_camera_follow :: proc(rig: ^Drift_Camera, position: [3]f32, delta_time: f32) {
	// Height goes straight into the goal; only x and z are on the leash.
	goal := [3]f32{rig.anchor.x, position.y, rig.anchor.z}

	leash := max(rig.dead_zone, 0)
	away  := [3]f32{position.x - rig.anchor.x, 0, position.z - rig.anchor.z}

	if reach := linalg.length(away); reach > leash && reach > 0 {
		direction := away / reach

		goal.x = position.x - direction.x * leash
		goal.z = position.z - direction.z * leash

		// Only while there is a drag to turn with. A character shuffling about
		// inside the dead zone has a direction of travel too, and swinging the
		// shot round for it is how a lazy camera becomes a restless one.
		if rig.swing_speed > 0 {
			turn_toward(&rig.yaw, yaw_from_direction(direction), rig.swing_speed, delta_time)
		}
	}

	// Zero or less is "does not follow", as camera.odin reads it. Written as a
	// guard rather than left to the maths, because exp(0) is 1 and a zero rate
	// would come out as no movement only by accident -- a negative one would
	// come out negative and ease the camera away from the character.
	if rig.follow_speed > 0 && delta_time > 0 {
		rig.anchor += (goal - rig.anchor) * (1 - math.exp(-rig.follow_speed * delta_time))
	}

	drift_camera_seat(rig)
}

/*
	Puts the anchor on `position` with no easing, and seats the camera.

	What a teleport, a level load or the end of a cutscene wants: the camera
	where it would have settled after standing there a while, rather than flying
	across the level to catch up. The constructor is this call, which is why a
	rig is framed before its first frame.

	The angle is left alone. A warp that should also look from somewhere else
	writes `yaw` and `pitch` around this -- both are read here rather than
	stored, so either order works.
*/
drift_camera_snap :: proc(rig: ^Drift_Camera, position: [3]f32) {
	rig.anchor = position
	drift_camera_seat(rig)
}

// Writes the anchor and the angles into the camera. Through `camera3d_follow`
// rather than done here, so that this rig and the third-person rig cannot come
// to disagree about what an angle means.
@(private)
drift_camera_seat :: proc(rig: ^Drift_Camera) {
	camera3d_follow(&rig.camera, rig.anchor + rig.focus_offset,
		rig.yaw, rig.pitch, rig.distance)
}
