package matchbox

/*
	Camera -- fixed angles
	----------------------
	The camera a PlayStation-era survival horror game is built on: a set of
	shots placed by hand, each covering one part of the level, and a cut from one
	to the next as the character walks between them.

	Each `Camera_Shot` is a camera placement plus a box of the world it covers.
	`fixed_camera_follow` is handed the character's position every frame and puts
	the camera at the shot whose box they are standing in. The player never turns
	this camera. Where it stands is the level's decision, which is the point of
	the style: a corridor can be framed so that whatever waits at the far end is
	behind the doorframe until the character is committed to walking down it.

	**Cuts, not blends.** Two shots are routinely placed on opposite sides of a
	wall, and a blend between them sweeps the camera through it. `cut` is true for
	the one frame the shot changed, so a game that wants a fade or a blend has the
	moment to start one from.

	**A cut changes what "up" means**, if up means "away from the camera". That
	is a movement problem rather than a camera one, and it is solved there: see
	`Character_Controls.hold_basis` in movement3d.odin, which keeps a character
	walking through a cut instead of turning round on the spot and walking
	straight back into the shot it just left.

	Like every rig in camera3d.odin, this moves nothing. The character's position
	is the game's, handed in, and never written.
*/

/*
	What a shot does with the character in frame.
*/
Camera_Shot_Aim :: enum {
	/*
		Looks at the shot's own `target` and never moves. The classic: a corner of
		a room, framed once.
	*/
	FIXED,

	/*
		Stays where it was put and turns to keep the character in frame, looking
		at the followed position plus `Fixed_Camera.focus_offset`. What a long
		corridor wants, where a fixed framing loses the character at one end of
		it.

		`target` is only read until there is a character to track -- see
		`fixed_camera_add_shot`. A tracking camera placed directly above the
		character's path has the same problem any camera looking straight down
		along `up` has: the view has no idea which way is up. Put it off to one
		side.
	*/
	TRACK,
}

/*
	One camera placement, and the part of the level it covers.

	`zone_min` and `zone_max` are opposite corners of a box in world space -- the
	same pair `draw_bounds_wires` takes, so a game can draw every zone and see
	where the cuts will land. They may be written either way round; a box whose
	corners were swapped is still the same box, and silently never containing
	anything would be the worst way to find out it was written backwards.

	**Give zones some height.** The box is tested in all three axes, so a zone
	made flat at floor level contains a character standing exactly on the floor
	and loses them the moment they are a hair above it.

	**Let neighbouring zones overlap** where they meet, by about a stride. The
	overlap is what stops the camera cutting back and forth when a character
	stands on the line between two shots -- see `fixed_camera_follow`.

	`fov` left at zero is 70, the default every `Camera3D` fills in.
*/
Camera_Shot :: struct {
	position: [3]f32,
	target:   [3]f32,
	fov:      f32,
	aim:      Camera_Shot_Aim,

	zone_min: [3]f32,
	zone_max: [3]f32,
}

/*
	A set of fixed shots and which one is on screen.

	**The rig owns its shots**, rather than holding a slice of an array the game
	keeps. A slice would be lighter, and it would also be a pointer into memory
	the rig has no say over: a game that builds its shots as a slice literal
	inside a level-loading procedure and returns the rig gets a camera reading a
	stack frame that no longer exists. Owning them costs a `destroy`, which is the
	same price `Parallax_Sprites` pays for the same reason.

	The fields are public. `shots` may be edited in place -- nudging a camera
	while tuning a room is what a game does -- and `shot` may be written to force
	a cut; see `fixed_camera_follow` for how long a forced shot lasts.
*/
Fixed_Camera :: struct {
	// What `begin_drawing_3d` takes. Written by `fixed_camera_follow`, and
	// seated on the first shot as soon as one is added.
	camera: Camera3D,

	// Every shot, in the order added. Order matters in one case only: when the
	// character walks into a place covered by more than one zone from outside
	// all of them, the earliest-added shot wins.
	shots: [dynamic]Camera_Shot,

	// Which shot is on screen, as an index into `shots`. Meaningless while
	// there are no shots.
	shot: int,

	/*
		True for exactly the frame on which `shot` changed, and false again on
		the next `fixed_camera_follow`.

		Polled rather than delivered, like everything else in Matchbox. A game
		that wants to fade on a cut, play a door sound, or reset something that
		was aimed at the old camera asks this on the frame it cares about.
	*/
	cut: bool,

	// Added to the followed position to get the point a `.TRACK` shot looks at.
	// The same offset `Third_Person_Camera` uses, and for the same reason: a
	// camera aimed at a character's feet puts them at the bottom of the frame.
	focus_offset: [3]f32,
}

/*
	An empty fixed camera, waiting for shots.

	Every argument has a default. The camera is not seated until the first shot
	is added, because until then there is nowhere for it to be:

		rig := mb.create_fixed_camera()
		defer mb.destroy(&rig)

		mb.fixed_camera_add_shot(&rig, {position = {-9, 4, -9}, target = {-5, 0, 0},
			zone_min = {-10, -1, -10}, zone_max = {0.5, 3, 10}})

	The zero value works too -- adding a shot to one allocates with the context
	allocator -- so this is for naming `near`, `far` or an allocator rather than
	something a rig cannot do without.
*/
create_fixed_camera :: proc(
	focus_offset: [3]f32 = CAMERA3D_DEFAULTS.focus_offset,
	near:         f32 = 0.1,
	far:          f32 = 1000,
	allocator := context.allocator,
) -> Fixed_Camera {
	return Fixed_Camera{
		camera = Camera3D{
			up         = {0, 1, 0},
			fov        = 70,
			projection = .PERSPECTIVE,
			near       = near,
			far        = far,
		},

		shots        = make([dynamic]Camera_Shot, allocator),
		focus_offset = focus_offset,
	}
}

/*
	Adds a shot, and answers its index in `shots`.

	The first shot added is put on screen immediately, looking at its own
	`target` whatever its aim -- so the rig has a real camera to draw with before
	the first `fixed_camera_follow`, rather than one sitting at the origin
	looking at the origin, which is a view matrix made of nothing.
*/
fixed_camera_add_shot :: proc(rig: ^Fixed_Camera, shot: Camera_Shot) -> int {
	append(&rig.shots, shot)
	index := len(rig.shots) - 1

	if index == 0 {
		rig.shot = 0
		fixed_camera_seat(rig, shot, shot.target)
	}

	return index
}

/*
	Puts the camera at the shot covering `position`, and aims it.

	Call it every frame, after the character has moved, with the character's
	position -- their feet, not their head; `focus_offset` is added here for the
	shots that track.

	**The shot on screen keeps the screen for as long as the character is still
	inside its zone**, even where another zone overlaps it. Only once they leave
	it is a new shot picked, the earliest-added whose zone contains them. That is
	what makes an overlap between two zones a buffer rather than a tie: picking
	the first containing zone every frame instead would cut to the earlier shot
	the moment the character stepped into the overlap, and cut back when they
	stepped out, and a character standing on the seam would strobe between the
	two.

	A character outside every zone keeps the last shot rather than getting none.
	Gaps between zones are a level-authoring mistake, and a frozen camera shows
	the mistake while a camera that went nowhere would show nothing.

	A game that writes `shot` itself -- a scripted look at a door opening, say --
	gets that shot until this call finds the character outside its zone. A shot
	whose zone does not contain the character is therefore replaced on the very
	next call; give a scripted shot a zone covering where the character stands,
	or stop calling this while the script runs.
*/
fixed_camera_follow :: proc(rig: ^Fixed_Camera, position: [3]f32) {
	rig.cut = false
	if len(rig.shots) == 0 do return

	holding := rig.shot >= 0 && rig.shot < len(rig.shots) &&
	           camera_shot_contains(rig.shots[rig.shot], position)

	if !holding {
		for shot, index in rig.shots {
			if !camera_shot_contains(shot, position) do continue

			if index != rig.shot {
				rig.shot = index
				rig.cut  = true
			}
			break
		}
	}

	// A shot index a game wrote out of range, with the character in no zone to
	// replace it: nothing sensible to seat, so the camera stays where it was.
	if rig.shot < 0 || rig.shot >= len(rig.shots) do return

	fixed_camera_seat(rig, rig.shots[rig.shot], position + rig.focus_offset)
}

// Releases the shots. Safe on a zero rig and safe twice.
destroy_fixed_camera :: proc(rig: ^Fixed_Camera) {
	delete(rig.shots)
	rig^ = {}
}

/*
	Whether `point` is inside a shot's zone, edges included.

	Edges included so that two zones written to share a face, with no overlap,
	still leave no gap a character can stand in between them. They will cut on
	the seam, which is what the overlap in `Camera_Shot`'s comment is for, but
	they will not freeze.
*/
@(private)
camera_shot_contains :: proc(shot: Camera_Shot, point: [3]f32) -> bool {
	for axis in 0 ..< 3 {
		low  := min(shot.zone_min[axis], shot.zone_max[axis])
		high := max(shot.zone_min[axis], shot.zone_max[axis])
		if point[axis] < low || point[axis] > high do return false
	}
	return true
}

// Writes a shot into the rig's camera, looking at `focus` if the shot tracks.
@(private)
fixed_camera_seat :: proc(rig: ^Fixed_Camera, shot: Camera_Shot, focus: [3]f32) {
	rig.camera.position = shot.position
	rig.camera.fov      = shot.fov

	switch shot.aim {
	case .TRACK: rig.camera.target = focus
	case .FIXED: rig.camera.target = shot.target
	}
}
