package matchbox

/*
	Camera -- 3D
	------------
	Where the scene is looked at from, and the two matrices that follow from
	that.

	Deliberately the same five fields raylib's Camera3D has, because both games
	already fill them in and the port should be a rename rather than a rethink.
	`near` and `far` are the additions, and only because raylib hides them and
	then gives you no way to change them when you want fog to reach further than
	1000 units.
*/

import "core:math"
import "core:math/linalg"

Camera3D_Projection :: enum {
	PERSPECTIVE,
	ORTHOGRAPHIC,
}

/*
	A point to look from, a point to look at, and how much fits in the frame.

	`fov` is vertical and in **degrees**, matching what both games already
	write. Everything else angular in Matchbox is radians; this is the exception
	and it is the same exception every engine makes.

	`near`, `far` and `up` may be left zero. A camera with a zero `up` has no
	idea which way is up and a camera with `near == far` has no depth at all, so
	rather than draw nothing and say nothing, the defaults below are filled in
	at use: up is +y, near is 0.1 and far is 1000, which is what raylib picks
	and what both games have been running on without knowing it.
*/
Camera3D :: struct {
	position:   [3]f32,
	target:     [3]f32,
	up:         [3]f32,
	fov:        f32,
	projection: Camera3D_Projection,
	near:       f32,
	far:        f32,
}

// A camera at `position` looking at `target`, with everything else left to the
// defaults. The short way to get a scene on screen.
camera3d_at :: proc(position, target: [3]f32, fov: f32 = 70) -> Camera3D {
	return Camera3D{
		position   = position,
		target     = target,
		up         = {0, 1, 0},
		fov        = fov,
		projection = .PERSPECTIVE,
		near       = 0.1,
		far        = 1000,
	}
}

// Fills in whatever was left zero. Called by the matrix builders rather than by
// the game, so a struct literal with three fields set still works.
@(private)
camera3d_defaults :: proc(camera: Camera3D) -> Camera3D {
	c := camera

	if c.up == {0, 0, 0} do c.up = {0, 1, 0}
	if c.fov <= 0        do c.fov = 70
	if c.near <= 0       do c.near = 0.1
	if c.far <= c.near   do c.far = 1000

	return c
}

// The matrix that moves the world in front of the camera.
camera3d_view :: proc(camera: Camera3D) -> matrix[4, 4]f32 {
	c := camera3d_defaults(camera)
	return look_at_matrix(c.position, c.target, c.up)
}

/*
	The matrix that turns view space into clip space, for the window as it is
	now.

	Aspect comes from the window rather than from the logical size, because the
	3D pass draws into the swapchain at its real pixel dimensions -- a 3D scene
	is not letterboxed the way `set_logical_size` letterboxes 2D.

	An orthographic camera reads `fov` as the height of the visible box in world
	units rather than as an angle, which is what raylib does with the same
	field.
*/
camera3d_projection :: proc(camera: Camera3D) -> matrix[4, 4]f32 {
	c := camera3d_defaults(camera)

	width  := f32(mbi.window_width)
	height := f32(mbi.window_height)

	// A minimised window reports zero and would divide by it.
	aspect: f32 = 1
	if height > 0 do aspect = width / height

	switch c.projection {
	case .ORTHOGRAPHIC:
		half_h := c.fov * 0.5
		half_w := half_h * aspect
		return ortho(-half_w, half_w, -half_h, half_h, c.near, c.far)

	case .PERSPECTIVE:
		fallthrough
	case:
		return perspective(c.fov, aspect, c.near, c.far)
	}
}

// Both at once, in the order a vertex shader wants them.
camera3d_view_projection :: proc(camera: Camera3D) -> matrix[4, 4]f32 {
	return camera3d_projection(camera) * camera3d_view(camera)
}

// -----------------------------------------------------------------------
// Which way it is facing
// -----------------------------------------------------------------------

/*
	The direction the camera looks.

	Both games need this and neither needs it for rendering: `CoffeeGame` walks
	along it, and both cast along it -- Box3D's `World_CastRayClosest` takes an
	origin and a translation, and the translation is this multiplied by how far
	you can reach.
*/
camera3d_forward :: proc(camera: Camera3D) -> [3]f32 {
	return linalg.normalize(camera.target - camera.position)
}

// Sideways from the camera, to the right. What strafing moves along, and what
// an item held in front of the player is offset by.
camera3d_right :: proc(camera: Camera3D) -> [3]f32 {
	c := camera3d_defaults(camera)
	return linalg.normalize(linalg.cross(camera3d_forward(c), c.up))
}

// -----------------------------------------------------------------------
// First person
// -----------------------------------------------------------------------

/*
	The pieces of a first-person camera, kept separate on purpose.

	A game with physics does not want its camera moved for it. `CoffeeGame`
	drives a Box3D body with a velocity, steps the world, and only then reads
	the body's position back out -- so the camera's position is decided by the
	solver and the camera's *direction* is decided by the mouse. Those are two
	different jobs and a single procedure that did both would be useless to it.

	So: `camera3d_look` turns mouse motion into angles, `camera3d_aim` points
	the camera along them from wherever it now is, and `walk_direction` says
	which way the keys are asking to go. A game with physics uses all three and
	moves nothing itself. `camera3d_first_person` is those three plus the move,
	for a camera that nothing else is driving.

	Yaw and pitch belong to the game rather than to the Camera3D, because they
	are the source and `target` is derived from them. Storing both on the camera
	would be storing the same fact twice and inviting them to disagree.
*/

// Radians per unit of mouse motion. CoffeeGame's number, which felt right.
MOUSE_SENSITIVITY :: f32(0.003)

// Just short of straight up or straight down. Exactly vertical is where the
// forward direction becomes parallel to `up`, the cross product that makes the
// view matrix collapses, and the picture rolls over.
PITCH_LIMIT :: f32(1.56) // a little under pi/2

// Which way you are facing, from the two angles. Yaw 0 looks along +x.
direction_from_angles :: proc(yaw, pitch: f32) -> [3]f32 {
	return {
		math.cos(pitch) * math.cos(yaw),
		math.sin(pitch),
		math.cos(pitch) * math.sin(yaw),
	}
}

// The angles that would produce the direction a camera is already looking in.
// What to seed yaw and pitch with, so the first frame of mouse look does not
// snap the view somewhere else.
camera3d_angles :: proc(camera: Camera3D) -> (yaw, pitch: f32) {
	forward := camera3d_forward(camera)
	return math.atan2(forward.z, forward.x), math.asin(clamp(forward.y, -1, 1))
}

/*
	Turns this frame's mouse motion into a change in yaw and pitch.

	Touches no camera. A game that never moves its own camera still needs the
	angles, because the angles are what a Box3D ray is cast along.

	Pitch is clamped; yaw is not, and is free to wind past a full turn. Nothing
	downstream cares -- sin and cos do not -- and clamping it would put an
	invisible wall in the middle of turning around.

	The clamp is a pair of arguments rather than the constant, because a
	third-person camera wants a different one: its pitch swings the camera
	above and below the character instead of tilting a head, so straight down
	is useful and straight up puts the camera under the floor. See
	`ORBIT_PITCH_MIN` and `ORBIT_PITCH_MAX`.
*/
camera3d_look :: proc(
	yaw, pitch:  ^f32,
	sensitivity: f32 = MOUSE_SENSITIVITY,
	pitch_min:   f32 = -PITCH_LIMIT,
	pitch_max:   f32 =  PITCH_LIMIT,
) {
	delta := get_mouse_delta()

	yaw^   += delta.x * sensitivity
	pitch^ += delta.y * sensitivity // mouse_dy is already up-positive
	pitch^  = clamp(pitch^, pitch_min, pitch_max)
}

// Points the camera along `yaw` and `pitch` from wherever it currently is.
// Call it after moving the position, which for a game with physics means after
// reading the body back out of the solver.
camera3d_aim :: proc(camera: ^Camera3D, yaw, pitch: f32) {
	camera.target = camera.position + direction_from_angles(yaw, pitch)
}

/*
	Which way WASD is asking to go, flattened onto the ground and normalised.

	Flattened because looking at your feet should not walk you into the floor:
	the forward the keys use is the facing direction with the pitch taken out,
	which is what every first-person game does and what `CoffeeGame` writes by
	hand as `flat_forward`.

	Normalised, so holding two keys is not faster than holding one. Zero when
	nothing is pressed, which is a length a caller has to expect before
	multiplying by a speed.

	The keys are fixed. A game wanting different ones builds the same vector out
	of `camera3d_forward` and `camera3d_right` in two lines, which is less than
	it would take to describe a rebinding.
*/
walk_direction :: proc(yaw: f32) -> [3]f32 {
	forward := [3]f32{math.cos(yaw), 0, math.sin(yaw)}
	right   := [3]f32{-math.sin(yaw), 0, math.cos(yaw)}

	direction: [3]f32

	if is_key_held(.W) do direction += forward
	if is_key_held(.S) do direction -= forward
	if is_key_held(.D) do direction += right
	if is_key_held(.A) do direction -= right

	if direction == {0, 0, 0} do return direction
	return linalg.normalize(direction)
}

/*
	Mouse look and WASD, moving the camera directly.

	For a camera nothing else is driving: a free camera, a level viewer, an
	example. A game with collision wants the three procedures above instead, so
	that the solver decides where the camera ends up and this does not overwrite
	it -- see the note at the top of this section.

	`speed` is units per second.
*/
camera3d_first_person :: proc(
	camera:      ^Camera3D,
	yaw, pitch:  ^f32,
	speed:       f32,
	delta_time:  f32,
	sensitivity: f32 = MOUSE_SENSITIVITY,
) {
	camera3d_look(yaw, pitch, sensitivity)

	camera.position += walk_direction(yaw^) * speed * delta_time

	camera3d_aim(camera, yaw^, pitch^)
}

// -----------------------------------------------------------------------
// Third person
// -----------------------------------------------------------------------

/*
	The same split again, for a camera that orbits something instead of sitting
	inside it.

	A third-person camera is a first-person camera that has been pushed
	backwards along its own view direction. That is the whole difference, and it
	is why the yaw and pitch are the same two numbers produced by the same
	`camera3d_look`: an orbit camera looking north-east from twenty degrees up
	is a head looking north-east from twenty degrees up, moved back six units.

	So the pieces are `camera3d_look` again for the angles, `camera3d_zoom` for
	the distance, `Camera3D_Shoulder` for which side of the character to sit on,
	`camera3d_orbit_position` for where all of that puts the camera, and
	`camera3d_follow` to seat it there looking at the focus.
	`camera3d_third_person` is the lot.

	**The composite moves no character**, unlike `camera3d_first_person`, which
	moves its camera. There is nothing here for it to move: the thing being
	orbited belongs to the game, and by the time the camera is placed the solver
	has already decided where it is. That makes the composite the one a real
	game *can* use -- pass it the character's position each frame and it is
	correct, physics or no physics.

	What is still the game's to do is stopping the camera going through a wall.
	`camera3d_orbit_position` is the piece for it: cast from the focus to the
	position it returns, and if something is in the way, call `camera3d_follow`
	with the shorter distance instead. Matchbox does not cast rays (see D7).
*/

// A distance to start at, and how close and how far the wheel may take it.
// Six units behind a character shows the character and enough of what is
// around it; under about one and a half the near plane starts eating the
// model.
ORBIT_DISTANCE     :: f32(6)
ORBIT_DISTANCE_MIN :: f32(1.5)
ORBIT_DISTANCE_MAX :: f32(20)

// World units of distance per notch of wheel.
ORBIT_ZOOM_SPEED :: f32(1)

/*
	How far the camera may swing above and below what it is orbiting.

	Not `PITCH_LIMIT`, and not symmetric, because the two ends are not the same
	thing here. Looking down means the camera is overhead, which is a view a
	game actually wants -- so the bottom end goes most of the way to straight
	down. Looking up means the camera is *below* the character, and a few
	degrees of that is a glance up at them while more of it is a camera under
	the floor. Hence the short top end.
*/
ORBIT_PITCH_MIN :: f32(-1.30) // camera high above, looking down
ORBIT_PITCH_MAX :: f32( 0.30) // camera a little below, looking up

// Turns this frame's wheel into a change in distance. Wheel up pulls the
// camera in, which is the direction every game scrolls.
//
// Touches no camera, for the same reason `camera3d_look` does not: a game that
// shortens the distance itself to stay out of a wall still wants the wheel
// read for it.
camera3d_zoom :: proc(
	distance:     ^f32,
	min_distance: f32 = ORBIT_DISTANCE_MIN,
	max_distance: f32 = ORBIT_DISTANCE_MAX,
	speed:        f32 = ORBIT_ZOOM_SPEED,
) {
	wheel := get_mouse_wheel()
	if wheel.y == 0 do return

	distance^ = clamp(distance^ - wheel.y * speed, min_distance, max_distance)
}

/*
	Where the camera sits relative to the character: behind it, or off one
	shoulder.

	Over the shoulder is not a different camera. It is the same rig slid
	sideways -- position and target together, by the same vector -- so the view
	direction is unchanged and the character simply stops being in the middle of
	it. Turning the camera instead would point it away from what the player is
	walking toward, which is the mistake this enum exists to make impossible.

	Which shoulder is a real choice rather than a preference: it decides which
	side of the character the player can see past, so a game that lets you lean
	round a corner needs both, and a game that puts a weapon in one hand usually
	picks the other.
*/
Camera3D_Shoulder :: enum {
	CENTER, // directly behind, the character in the middle of the screen
	LEFT,   // camera off the character's left, character to the right of centre
	RIGHT,  // camera off the character's right, character to the left of centre
}

/*
	How far sideways an over-the-shoulder camera slides, in world units.

	Small, because this is measured at the character and read at the far end of
	the distance: three quarters of a unit off a camera six units back moves the
	character about seven degrees across the frame, which is enough to see past
	them and not enough to look like the camera is pointed wrong.

	The offset does not scale with distance on purpose. It is a step to one side
	of the character, not a fraction of the screen, so pulling the camera in
	makes the framing more over-the-shoulder rather than less -- which is what a
	game does when it raises a weapon.
*/
SHOULDER_OFFSET :: f32(0.75)

/*
	The signed sideways step a shoulder setting asks for. Positive is to the
	camera's right.

	Exposed because it is the number to interpolate. Switching shoulders by
	swapping the enum snaps the view across the character; a game that wants the
	swap to slide keeps its own f32, moves it toward this, and feeds the result
	through `camera3d_side_offset`.
*/
camera3d_shoulder_amount :: proc(shoulder: Camera3D_Shoulder, offset: f32 = SHOULDER_OFFSET) -> f32 {
	switch shoulder {
	case .LEFT:  return -offset
	case .RIGHT: return  offset
	case .CENTER: fallthrough
	case:        return 0
	}
}

/*
	The world-space slide, for a signed amount.

	Sideways from the camera and flat, which for a camera with +y up is the same
	thing: `cross(forward, up)` for the direction `yaw` and `pitch` describe
	comes out as `{-sin(yaw), 0, cos(yaw)}` with the pitch cancelling, so the
	step does not shorten as you look down.

	The general form of the shoulder, and the one to reach for when the setting
	is being interpolated rather than switched. It also means a game never needs
	the enum at all: add this to your own focus point and pass `.CENTER`, which
	is the same rig by a different route.
*/
camera3d_side_offset :: proc(yaw: f32, amount: f32) -> [3]f32 {
	return [3]f32{-math.sin(yaw), 0, math.cos(yaw)} * amount
}

// The point an orbit camera actually looks at: the focus, stepped sideways by
// the shoulder setting. What `camera3d_follow` puts in `camera.target`, and
// what a wall-avoiding ray cast starts from -- not the character's own centre,
// which is no longer where the camera is aimed.
camera3d_orbit_focus :: proc(
	focus:           [3]f32,
	yaw:             f32,
	shoulder:        Camera3D_Shoulder = .CENTER,
	shoulder_offset: f32 = SHOULDER_OFFSET,
) -> [3]f32 {
	if shoulder == .CENTER do return focus
	return focus + camera3d_side_offset(yaw, camera3d_shoulder_amount(shoulder, shoulder_offset))
}

/*
	Where an orbit camera wants to be: `distance` back from the focus, along the
	direction the angles describe, off whichever shoulder was asked for.

	The one to cast a ray at. A game with collision casts from
	`camera3d_orbit_focus` to this and follows at whatever shorter distance the
	cast comes back with, which is what keeps the camera out of the wall behind
	the player.
*/
camera3d_orbit_position :: proc(
	focus:                [3]f32,
	yaw, pitch, distance: f32,
	shoulder:             Camera3D_Shoulder = .CENTER,
	shoulder_offset:      f32 = SHOULDER_OFFSET,
) -> [3]f32 {
	aim := camera3d_orbit_focus(focus, yaw, shoulder, shoulder_offset)
	return aim - direction_from_angles(yaw, pitch) * distance
}

// Seats the camera behind `focus` and points it at it. The third-person
// counterpart of `camera3d_aim`, and the call to make after physics has moved
// whatever is being followed.
//
// `focus` is a point, not a character: pass the head or the shoulders rather
// than the feet, or the character sits at the bottom edge of the screen. With a
// shoulder set it is still the character's point -- the step to one side is
// taken here, so the game keeps passing the same thing either way.
camera3d_follow :: proc(
	camera:               ^Camera3D,
	focus:                [3]f32,
	yaw, pitch, distance: f32,
	shoulder:             Camera3D_Shoulder = .CENTER,
	shoulder_offset:      f32 = SHOULDER_OFFSET,
) {
	camera.position = camera3d_orbit_position(focus, yaw, pitch, distance, shoulder, shoulder_offset)
	camera.target   = camera3d_orbit_focus(focus, yaw, shoulder, shoulder_offset)
}

// The angles and distance an orbit camera is already at. What to seed yaw,
// pitch and distance with, for the same reason `camera3d_angles` exists: a
// camera placed by `camera3d_at` and then driven from zeroed angles jumps on
// the first frame.
camera3d_orbit_angles :: proc(camera: Camera3D) -> (yaw, pitch, distance: f32) {
	yaw, pitch = camera3d_angles(camera)
	return yaw, pitch, linalg.length(camera.target - camera.position)
}

/*
	Mouse look, wheel zoom, and the camera placed behind `focus`.

	The whole third-person camera, and safe for a game with a solver -- see the
	note at the top of this section. Call it after the character has been moved,
	with the point on the character the camera should look at.

	`walk_direction(yaw)` is what the character moves along: in third person the
	keys are read relative to the camera, so W walks away from it, which is what
	makes turning the camera turn the character. That stays true off a shoulder
	-- the slide moves where the camera is, not which way it faces -- so a game
	swapping shoulders mid-stride does not swap which way W goes.
*/
camera3d_third_person :: proc(
	camera:               ^Camera3D,
	focus:                [3]f32,
	yaw, pitch, distance: ^f32,
	shoulder:             Camera3D_Shoulder = .CENTER,
	shoulder_offset:      f32 = SHOULDER_OFFSET,
	sensitivity:          f32 = MOUSE_SENSITIVITY,
	pitch_min:            f32 = ORBIT_PITCH_MIN,
	pitch_max:            f32 = ORBIT_PITCH_MAX,
) {
	camera3d_look(yaw, pitch, sensitivity, pitch_min, pitch_max)
	camera3d_zoom(distance)
	camera3d_follow(camera, focus, yaw^, pitch^, distance^, shoulder, shoulder_offset)
}

// -----------------------------------------------------------------------
// Facing
// -----------------------------------------------------------------------

/*
	Which way a flat direction points, as a yaw. The inverse of the horizontal
	half of `direction_from_angles`, and what a third-person game turns its
	character to face after reading `walk_direction`.

	The y component is ignored rather than being an error: `walk_direction`
	returns a vector already flattened onto the ground, and the answer for one
	that is not is the direction of its shadow, which is the useful one.

	Zero for a zero direction, which is a caller's cue to leave the character
	facing where it was rather than snapping it east.
*/
yaw_from_direction :: proc(direction: [3]f32) -> f32 {
	if direction.x == 0 && direction.z == 0 do return 0
	return math.atan2(direction.z, direction.x)
}

/*
	Turns `angle` toward `target` the short way round, at most `speed` radians
	per second, and lands exactly on it.

	The short way is the point. A character running east and turning to run
	north-east has a target that may be written as -6.0 or as 0.28, and
	subtracting the two gives a spin most of the way round the compass. This
	takes the difference across the wrap, so the turn is the few degrees it
	looks like.
*/
turn_toward :: proc(angle: ^f32, target: f32, speed: f32, delta_time: f32) {
	// Signed difference in (-pi, pi], which is what makes the turn the short
	// one.
	difference := math.mod(target - angle^ + math.PI, math.TAU)
	if difference < 0 do difference += math.TAU
	difference -= math.PI

	step := speed * delta_time

	if abs(difference) <= step {
		angle^ = target
		return
	}

	angle^ += math.sign(difference) * step
}

/*
	The rotation that turns a model to face `yaw`.

	For a model whose own forward is +x, which is the direction yaw 0 points and
	so the one the rest of this file is written in. The negation is not a typo:
	a rotation of `t` about +y takes +x to `{cos t, 0, -sin t}`, and the
	direction wanted is `{cos yaw, 0, sin yaw}`, so the angle to rotate by is
	`-yaw`. Getting this backwards gives a character that turns the wrong way,
	which on a symmetrical model takes a while to notice.
*/
facing_rotation :: proc(yaw: f32) -> quaternion128 {
	return transform_rotation({0, 1, 0}, -yaw)
}

// -----------------------------------------------------------------------
// Third person -- the whole thing in one struct
// -----------------------------------------------------------------------

/*
	Who the keys are relative to.

	The two settings differ in one thing: whether turning the camera turns the
	run. Everything else about the camera is the same either way -- the same
	orbit, the same shoulder, the same zoom.
*/
Camera3D_Steering :: enum {
	/*
		The camera steers. W goes away from the camera, so turning the camera
		while walking curves the run, and the character is turned to face
		wherever it ends up going.

		What most third-person games do, and what `examples/third-person` does
		unless you press F.
	*/
	CAMERA,

	/*
		The character steers. W goes along the character's own heading, so the
		camera can look wherever it likes and the run carries straight on --
		look left while walking forward and you keep walking forward, looking
		left.

		Nothing turns the character in this setting. That is the point of it,
		and it means turning is the game's: write `facing` from your own turn
		keys, or put the steering back to `.CAMERA` -- which is what a game
		does when free look is a key you hold rather than a mode you are in.
	*/
	CHARACTER,
}

// Where the camera looks on the character, added to the position you follow.
// Head height on a person-sized one; the feet are the wrong point to aim at,
// because aiming there puts the character on the bottom edge of the screen.
FOCUS_OFFSET :: [3]f32{0, 1.6, 0}

// Radians per second the character pivots at under `.CAMERA` steering. Fast
// enough that a tap of A is not a handbrake turn, slow enough to be visible.
TURN_SPEED :: f32(12)

// A little above level, looking slightly down, which is where a third-person
// camera sits before anybody touches the mouse.
ORBIT_PITCH :: f32(-0.3)

/*
	Everything a third-person camera needs, in one place.

	The loose procedures above are the pieces, and a game that already keeps its
	own yaw and pitch should keep using them. This is for the other case: five
	numbers, a framing, a steering setting and a `Camera3D` all have to agree
	with each other every frame, and a game that holds them as eight separate
	variables is a game that will one day update seven of them.

	What is *not* in here is the character's position. That is deliberate and it
	is the same line drawn everywhere else in this file: the position comes from
	the game -- from a solver, usually -- so it is an argument to
	`third_person_follow` rather than a field somebody has to remember to write.
	Matchbox still moves nothing (D7).

	The fields are public and meant to be written. `shoulder` and `steering` are
	settings a game changes on a keypress; `facing` is the character's heading,
	which the rig turns under `.CAMERA` steering and the game turns under
	`.CHARACTER`; `distance` is the wheel's, and a game is free to overwrite it.
*/
Third_Person_Camera :: struct {
	// What `begin_drawing_3d` takes. Written by `third_person_follow`; there is
	// nothing to set here by hand.
	camera: Camera3D,

	// The orbit. Yaw and pitch are the same two angles the first-person camera
	// uses, and `distance` is how far back the rig sits from what it follows.
	yaw:      f32,
	pitch:    f32,
	distance: f32,

	// Which way the character is turned. Read it to draw them --
	// `facing_rotation(rig.facing)` is the quaternion.
	facing: f32,

	// Which way the keys asked to go this frame, flattened and normalised, and
	// zero when nothing is pressed. What to multiply by a speed, or to hand a
	// solver as a velocity. Written by `third_person_input`.
	move: [3]f32,

	// The framing. See `Camera3D_Shoulder`.
	shoulder:        Camera3D_Shoulder,
	shoulder_offset: f32,

	// Added to the position being followed to get the point the camera looks
	// at. See `FOCUS_OFFSET`.
	focus_offset: [3]f32,

	// Whether turning the camera turns the run. See `Camera3D_Steering`.
	steering:   Camera3D_Steering,
	turn_speed: f32,

	// Tuning, all of it defaulted by `third_person_camera` and none of it
	// looked at again unless a game changes it.
	sensitivity:  f32,
	pitch_min:    f32,
	pitch_max:    f32,
	zoom_speed:   f32,
	distance_min: f32,
	distance_max: f32,
}

/*
	A third-person camera, set up and already pointed at the character.

	Every argument has a default, so `third_person_camera()` is a working camera
	behind a character standing at the origin. Name the ones you care about:

		rig := mb.third_person_camera(position = spawn, facing = spawn_facing,
			shoulder = .RIGHT)

	`yaw` is not an argument. It is seeded from `facing`, which puts the camera
	behind the character rather than side-on to them -- the same reasoning as
	`camera3d_angles`, one step earlier. A game wanting to start it elsewhere
	writes `rig.yaw` after this returns.

	The camera is seated before this returns, so the rig may be drawn with on
	the same frame it was made -- which matters for a loading screen, and for
	anything that reads `rig.camera` before the first `third_person_follow`.
*/
third_person_camera :: proc(
	position:        [3]f32 = {0, 0, 0},
	facing:          f32 = 0,
	focus_offset:    [3]f32 = FOCUS_OFFSET,
	distance:        f32 = ORBIT_DISTANCE,
	pitch:           f32 = ORBIT_PITCH,
	shoulder:        Camera3D_Shoulder = .CENTER,
	shoulder_offset: f32 = SHOULDER_OFFSET,
	steering:        Camera3D_Steering = .CAMERA,
	turn_speed:      f32 = TURN_SPEED,
	fov:             f32 = 70,
	near:            f32 = 0.1,
	far:             f32 = 1000,
	sensitivity:     f32 = MOUSE_SENSITIVITY,
	pitch_min:       f32 = ORBIT_PITCH_MIN,
	pitch_max:       f32 = ORBIT_PITCH_MAX,
	zoom_speed:      f32 = ORBIT_ZOOM_SPEED,
	distance_min:    f32 = ORBIT_DISTANCE_MIN,
	distance_max:    f32 = ORBIT_DISTANCE_MAX,
) -> Third_Person_Camera {
	rig := Third_Person_Camera{
		camera = Camera3D{
			up         = {0, 1, 0},
			fov        = fov,
			projection = .PERSPECTIVE,
			near       = near,
			far        = far,
		},

		yaw      = facing, // behind the character, not beside them
		pitch    = clamp(pitch, pitch_min, pitch_max),
		distance = clamp(distance, distance_min, distance_max),

		facing = facing,

		shoulder        = shoulder,
		shoulder_offset = shoulder_offset,
		focus_offset    = focus_offset,

		steering   = steering,
		turn_speed = turn_speed,

		sensitivity  = sensitivity,
		pitch_min    = pitch_min,
		pitch_max    = pitch_max,
		zoom_speed   = zoom_speed,
		distance_min = distance_min,
		distance_max = distance_max,
	}

	camera3d_follow(&rig.camera, position + rig.focus_offset,
		rig.yaw, rig.pitch, rig.distance, rig.shoulder, rig.shoulder_offset)

	return rig
}

/*
	Reads the mouse, the wheel and the keys into the rig.

	Afterwards `yaw`, `pitch` and `distance` are this frame's, and `move` is
	which way the keys are asking to go -- against the camera under `.CAMERA`
	steering, against the character's own heading under `.CHARACTER`.

	Moves nothing and touches no position, so what happens next is the game's:
	step a solver with `move` as a velocity, or add it to a position yourself.
	`third_person_follow` comes after that.
*/
third_person_input :: proc(rig: ^Third_Person_Camera) {
	camera3d_look(&rig.yaw, &rig.pitch, rig.sensitivity, rig.pitch_min, rig.pitch_max)
	camera3d_zoom(&rig.distance, rig.distance_min, rig.distance_max, rig.zoom_speed)

	switch rig.steering {
	case .CHARACTER:
		rig.move = walk_direction(rig.facing)
	case .CAMERA:
		fallthrough
	case:
		rig.move = walk_direction(rig.yaw)
	}
}

/*
	Turns the character and seats the camera behind them, at wherever they
	actually ended up.

	The second half of the frame, and the one that takes the position: call it
	after the solver has run, or after you have added `move` to a position
	yourself.

	The turn happens only under `.CAMERA` steering and only while the keys are
	asking for something -- a character standing still keeps the heading it had
	rather than snapping back to face the camera.
*/
third_person_follow :: proc(rig: ^Third_Person_Camera, position: [3]f32, delta_time: f32) {
	if rig.steering == .CAMERA && rig.move != {0, 0, 0} {
		turn_toward(&rig.facing, yaw_from_direction(rig.move), rig.turn_speed, delta_time)
	}

	camera3d_follow(&rig.camera, position + rig.focus_offset,
		rig.yaw, rig.pitch, rig.distance, rig.shoulder, rig.shoulder_offset)
}

/*
	Input, the move, and the follow -- the whole frame, for a character nothing
	else is driving.

	The counterpart of `camera3d_first_person`, and the same warning applies: it
	writes `position`, which a game with a solver cannot allow. Such a game
	calls `third_person_input`, gives `move` to the solver, reads the body back
	out, and calls `third_person_follow` with it. Those are the two halves this
	is made of.

	`speed` is units per second.
*/
third_person_walk :: proc(
	rig:        ^Third_Person_Camera,
	position:   ^[3]f32,
	speed:      f32,
	delta_time: f32,
) {
	third_person_input(rig)

	position^ += rig.move * speed * delta_time

	third_person_follow(rig, position^, delta_time)
}
