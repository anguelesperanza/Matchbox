package tether

/*
	Tether -- physics
	-----------------
	Box3D, with the parts two games actually used given names that say what
	they are for.

	**A Matchbox package**, `matchbox/tether`, beside `matchbox` and `eko`
	rather than inside `package matchbox`: it imports nothing from Matchbox, and
	folding it in would link Box3D into every game that only wanted to draw a
	sprite. It was a repository of its own until 2026-09-17; `CLAUDE.md` and
	`tether.md` at the repository root have why it moved, and nothing about the
	API changed when it did.

	Everything here was lifted out of PsxGame and MBCoffeeGame, which both
	called `vendor:box3d` directly and wrote much the same code to do it: a world
	at -10 gravity, box hulls sized from a model's bounds, an upright capsule
	for the player, collision categories as a `bit_set` transmuted to `u64`, and
	a closest-ray cast told to ignore the player it starts inside. CoffeeGame
	adds picking a body up and setting it down again.

	That is the whole of it, deliberately. A Box3D feature neither game used --
	joints, spheres, contact events -- is not here yet rather than forgotten,
	and arrives when a game needs it. Turning a body where it stands, and
	removing one, arrived that way on 2026-09-17: a level built in Stargate's
	editor has colliders that are turned, and a level that is unloaded has to
	take its bodies with it.

	A game using this should not need to import `vendor:box3d` at all.
*/

import "core:math/linalg"

import b3 "vendor:box3d"

/*
	The one piece of package state.

	For the same reason Matchbox has `mbi`: every body and every ray belongs to a
	world, and passing a world id to each `create_box_body` and `cast_ray` would
	put it at every call site for no gain -- neither game ever had more than
	one. Anything else that wants to live at package scope belongs in here
	instead.
*/
Tether_Instance :: struct {
	world: b3.WorldId,
}
tpi: Tether_Instance

/*
	Box3D's handles, under names in this package's style.

	Aliases rather than distinct types, so a game can compare `hit.body` with
	`item.body.id` without a cast, and so neither side has to import
	`vendor:box3d` to name the type of a field.
*/
Body_Id  :: b3.BodyId
Shape_Id :: b3.ShapeId

/*
	What the solver does with a body.

	The values sit in Box3D's own order, and the asserts below hold them there,
	so converting is a cast rather than a switch that could fall out of step.
*/
Body_Type :: enum {
	STATIC,    // never moves, still collides -- floors, walls, props
	KINEMATIC, // moved by the game; pushes dynamic bodies, pushed by nothing
	DYNAMIC,   // moved by the solver -- gravity, contacts, velocity
}

#assert(int(Body_Type.STATIC)    == int(b3.BodyType.staticBody))
#assert(int(Body_Type.KINEMATIC) == int(b3.BodyType.kinematicBody))
#assert(int(Body_Type.DYNAMIC)   == int(b3.BodyType.dynamicBody))

/*
	Which ways a body is not allowed to move.

	Both games' players lock the same four: translation along Y, so eye height
	is decided by the game rather than by gravity, and all three rotations, so a
	capsule clipped by a corner stays upright:

		locks = {.LINEAR_Y, .ANGULAR_X, .ANGULAR_Y, .ANGULAR_Z}

	A `bit_set` rather than Box3D's struct of six bools, so that reads as one
	value at the call site.
*/
Motion_Lock :: enum {
	LINEAR_X,
	LINEAR_Y,
	LINEAR_Z,
	ANGULAR_X,
	ANGULAR_Y,
	ANGULAR_Z,
}
Motion_Locks :: bit_set[Motion_Lock]

/*
	One body with one shape on it -- the only arrangement either game built.

	`offset` is there because a model's origin is rarely the centre of its
	bounds. The collider is centred on the geometry, so the body's transform is
	too, and the point a game draws the model at is that transform with the
	offset backed out *after turning it by the body's rotation*. CoffeeGame
	found the last part the hard way -- subtract the offset unturned and a
	tumbling item swings about the wrong point -- and `get_body_origin` now does
	it in one place.

	`half_extents` is the collider's half-size: a box's own, or the box a capsule
	fits inside. `place_body` needs it to sit a body on a surface rather than
	half inside one.

	Both are fixed when the body is made and never written again, so a copy of a
	`Body` stays as true as the original. What does change -- position,
	rotation, type -- is Box3D's, and is read from Box3D rather than mirrored
	here where it could go stale. CoffeeGame's `Item.body_type` is the warning:
	it still says `.dynamicBody` while the item is held and kinematic.
*/
Body :: struct {
	id:           Body_Id,
	shape:        Shape_Id,
	offset:       [3]f32,
	half_extents: [3]f32,
}

/*
	What `cast_ray` found.

	`body` comes back beside `shape` because CoffeeGame's first move with every
	hit was `Shape_GetBody`: a game stores bodies, and a shape is rarely the
	thing it has to hand.

	Every field is zero on a miss. That includes `body`, which is also the id of
	a `Body` that was never created, so compare through `is_body_hit` rather
	than on the ids alone.
*/
Ray_Hit :: struct {
	hit:    bool,
	body:   Body_Id,
	shape:  Shape_Id,
	point:  [3]f32,
	normal: [3]f32,
}

// -----------------------------------------------------------------------
// The world
// -----------------------------------------------------------------------

/*
	Makes the world every body and ray in this package belongs to.

	`gravity` defaults to -10 on Y, which is Box3D's own default and also what
	both games set by hand. `shutdown` takes it down again.
*/
init :: proc(gravity: [3]f32 = {0, -10, 0}) {
	world_def := b3.DefaultWorldDef()
	world_def.gravity = gravity
	tpi.world = b3.CreateWorld(world_def)
}

/*
	Destroys the world, and every body in it.

	Bodies still held as `Body` values are not zeroed by this, since the world
	does not know where they are kept; their ids simply stop being valid.
	`destroy_body` is the way to take one body out and leave the rest standing.

	Doing this twice, or without an `init`, does nothing rather than crashing:
	the guard is what makes `defer shutdown()` safe in a caller that also tears
	the world down on some other path, which is how a tool that builds a world
	per question ends up written.
*/
shutdown :: proc() {
	if !b3.World_IsValid(tpi.world) do return

	b3.DestroyWorld(tpi.world)
	tpi = {}
}

/*
	Advances the simulation by one step.

	Defaults to a sixtieth of a second in four sub-steps, which both games run
	once a frame at a 60 FPS target. Keep the step fixed rather than feeding it
	the frame's delta time. Box3D's continuous collision stops a long step from
	tunnelling a body through a floor -- measured, not even at half a second --
	but contacts go soft as the step grows: a crate dropped onto a thin floor
	ended 0.05 into it at 0.5 s steps, 0.002 at 0.1 s, and too little to measure
	at a sixtieth. More `sub_steps` costs more and settles stacks and fast bodies
	better.
*/
step :: proc(time_step: f32 = 1.0 / 60.0, sub_steps: i32 = 4) {
	b3.World_Step(tpi.world, time_step, sub_steps)
}

/*
	A game's own collision categories, as the `u64` Box3D filters on.

	Both games name their categories with an enum and a `bit_set[...; u64]` over
	it, then `transmute` at every shape and every ray. This is that transmute,
	written once.

	The `where` clause is what rejects a `bit_set` of the wrong size, and it is
	there for the error message: the `bit_set[$E; u64]` pattern alone lets a
	one-byte set through, and the mistake then surfaces as a transmute failure
	inside this file with no mention of the caller. The clause's error names
	the calling line.

		Category :: enum {
			WORLD,
			PLAYER,
		}
		Categories :: bit_set[Category; u64]

		tether.category_bits(Categories{.WORLD})
*/
category_bits :: proc(categories: $T/bit_set[$E; u64]) -> u64 where size_of(T) == size_of(u64) {
	return transmute(u64)categories
}

// -----------------------------------------------------------------------
// Making bodies
// -----------------------------------------------------------------------

/*
	A body with a box collider, the shape both games build nearly everything
	from.

	Every argument has a default; name the ones you care about. The body is
	placed at `position + offset`, the collider's centre. For a model, pass where
	it is drawn as `position`, its scaled centre as `offset`, and *half* its
	scaled size as `half_extents`. Box3D builds a box from half-extents where a
	model's size is the whole thing, and both are three floats that will not
	complain if confused:

		item.body = tether.create_box_body(
			position     = item.position,
			half_extents = mb.model_size(item.model) * item.scale * 0.5,
			offset       = mb.model_center(item.model) * item.scale,
			type         = .DYNAMIC,
			category     = tether.category_bits(Categories{.WORLD}),
		)

	`type` defaults to `.STATIC`, as Box3D's does, and a static body never moves
	whatever else is set. CoffeeGame's `load_item` carries a comment about
	exactly that mix-up, with the collision category standing in for the type.

	`density` defaults to 1, what both games set, rather than Box3D's 1000. Mass
	does not change how fast a body falls, only how it trades pushes with other
	bodies, so the thing that matters is that bodies agree -- and one body left
	on Box3D's default beside one on this would be a thousand times heavier.

	`category` defaults to every bit, Box3D's own default, so a body made without
	one is visible to every ray.

	`rotation` turns the box where it stands, and **turns `offset` with it**, so
	that `get_body_origin` -- which backs the rotated offset out again -- hands
	back exactly the `position` given here. Left unturned, the offset would put
	a turned model's collider somewhere its model is not.

	Neither game needed a turned body: both built their scenery from walls
	square to the world, and their one moving body was an upright capsule. A
	level built in an editor turns things, and a wall at 30 degrees collided
	with as though it stood at 0 is a wall the player walks through.
*/
create_box_body :: proc(
	position:     [3]f32 = {0, 0, 0},
	half_extents: [3]f32 = {0.5, 0.5, 0.5},
	offset:       [3]f32 = {0, 0, 0},
	type:         Body_Type = .STATIC,
	category:     u64 = max(u64),
	density:      f32 = 1,
	friction:     f32 = 0.6,
	locks:        Motion_Locks = {},
	rotation:     quaternion128 = 1,
) -> Body {
	body := Body{
		offset       = offset,
		half_extents = half_extents,
	}

	body_def := make_body_def(position + linalg.quaternion128_mul_vector3(rotation, offset), rotation, type, locks)
	body.id = b3.CreateBody(tpi.world, body_def)

	hull := b3.MakeBoxHull(half_extents.x, half_extents.y, half_extents.z)
	shape_def := make_shape_def(category, density, friction)
	body.shape = b3.CreateHullShape(body.id, shape_def, &hull.base)

	return body
}

/*
	A body with an upright capsule collider -- the player, in both games.

	`half_height` runs from the capsule's centre to the centre of each rounded
	end, so the whole thing stands `2 * (half_height + radius)` tall. The games
	used `half_height` 0.5 and 0.6 under a `radius` of 0.35 and 0.4.

	A capsule rather than a box because it has no edges to catch: pressed into a
	corner it slides round rather than stopping dead. PsxGame's header notes
	that this makes narrow gaps feel different to the axis-by-axis collision it
	replaced, and that is expected.

	The same defaults as `create_box_body`, `.STATIC` included, so a player wants
	`type = .DYNAMIC` and almost certainly the four locks shown on
	`Motion_Locks`.

	`rotation` tips the capsule over: its axis is +Y in its own space, so a
	quarter turn about Z lays it along X. A player's capsule stays upright and
	wants the default; a fallen log authored in an editor does not.
*/
create_capsule_body :: proc(
	position:    [3]f32 = {0, 0, 0},
	radius:      f32 = 0.5,
	half_height: f32 = 0.5,
	type:        Body_Type = .STATIC,
	category:    u64 = max(u64),
	density:     f32 = 1,
	friction:    f32 = 0.6,
	locks:       Motion_Locks = {},
	rotation:    quaternion128 = 1,
) -> Body {
	body := Body{
		half_extents = {radius, half_height + radius, radius},
	}

	body_def := make_body_def(position, rotation, type, locks)
	body.id = b3.CreateBody(tpi.world, body_def)

	capsule := b3.Capsule{
		center1 = {0, -half_height, 0},
		center2 = {0,  half_height, 0},
		radius  = radius,
	}
	shape_def := make_shape_def(category, density, friction)
	body.shape = b3.CreateCapsuleShape(body.id, shape_def, &capsule)

	return body
}

/*
	Takes one body out of the world, with its shape, and leaves the `Body`
	zeroed.

	**Zeroed rather than left naming a destroyed body**, because Box3D reuses a
	body slot: a `Body` still holding the old id would, after enough bodies had
	come and gone, silently name whatever now lives there. A zeroed one names
	nothing -- `is_body_hit` already answers `false` for it, which is the same
	reasoning that makes a never-created `Body` safe to compare.

	It is the caller's job not to keep a `^Body` pointing at a body destroyed
	through another copy of it. Nothing here can see the copies.

	Neither game removed a body, which is why this was not here at first: theirs
	lived exactly as long as the world. A level does not. Loading a second level
	into a running game has to take the first one's bodies out, and rebuilding
	the world for each change would take the player's body and everything else
	the game made with it.
*/
destroy_body :: proc(body: ^Body) {
	if !b3.Body_IsValid(body.id) do return

	b3.DestroyBody(body.id)
	body^ = {}
}

@(private)
make_body_def :: proc(position: [3]f32, rotation: quaternion128, type: Body_Type, locks: Motion_Locks) -> b3.BodyDef {
	body_def := b3.DefaultBodyDef()
	body_def.type = b3.BodyType(type)
	body_def.position = position
	body_def.rotation = rotation
	body_def.motionLocks = {
		linearX  = .LINEAR_X  in locks,
		linearY  = .LINEAR_Y  in locks,
		linearZ  = .LINEAR_Z  in locks,
		angularX = .ANGULAR_X in locks,
		angularY = .ANGULAR_Y in locks,
		angularZ = .ANGULAR_Z in locks,
	}
	return body_def
}

@(private)
make_shape_def :: proc(category: u64, density: f32, friction: f32) -> b3.ShapeDef {
	shape_def := b3.DefaultShapeDef()
	shape_def.filter.categoryBits = category
	shape_def.density = density
	shape_def.baseMaterial.friction = friction
	return shape_def
}

// -----------------------------------------------------------------------
// Reading and moving bodies
// -----------------------------------------------------------------------

/*
	Where the solver has the body's collider centre.

	The collider's centre, not the model's origin: for anything made with an
	`offset`, where to draw is `get_body_origin`. A player's capsule has no
	offset, so for the player the two agree and this is what the camera
	follows.
*/
get_body_position :: proc(body: ^Body) -> [3]f32 {
	return b3.Body_GetPosition(body.id)
}

// How the body is turned. Identity until something knocks it, or forever for a body with all three angular locks.
get_body_rotation :: proc(body: ^Body) -> quaternion128 {
	return b3.Body_GetRotation(body.id)
}

/*
	Where to draw the thing this body stands in for.

	The collider's centre with `offset` backed out, turned by the body's
	rotation first because the offset turns with the body. Left unturned, a
	model whose origin sits at its base would orbit its own centre as it tumbled
	instead of tumbling with it. Draw with `get_body_rotation` alongside.
*/
get_body_origin :: proc(body: ^Body) -> [3]f32 {
	rotation := b3.Body_GetRotation(body.id)
	return b3.Body_GetPosition(body.id) - linalg.quaternion128_mul_vector3(rotation, body.offset)
}

/*
	Moves the body straight to a transform, collider centre first.

	A teleport: nothing between here and there is collided with. `position` is
	the collider's centre, the same point `get_body_position` reads, not the
	origin `get_body_origin` reads.
*/
set_body_transform :: proc(body: ^Body, position: [3]f32, rotation: quaternion128 = 1) {
	b3.Body_SetTransform(body.id, position, rotation)
}

// Changes what the solver does with the body. See `Body_Type`.
set_body_type :: proc(body: ^Body, type: Body_Type) {
	b3.Body_SetType(body.id, b3.BodyType(type))
}

/*
	Sets how fast the body is moving, in units per second.

	Both games drive their player this way rather than with forces: every frame,
	set the velocity the keys ask for and let the solver decide where that ends
	up. That is what makes a wall stop the player instead of being walked
	through.
*/
set_body_linear_velocity :: proc(body: ^Body, velocity: [3]f32) {
	b3.Body_SetLinearVelocity(body.id, velocity)
}

// Sets how fast the body is spinning, in radians per second about each axis.
set_body_angular_velocity :: proc(body: ^Body, velocity: [3]f32) {
	b3.Body_SetAngularVelocity(body.id, velocity)
}

// -----------------------------------------------------------------------
// Rays
// -----------------------------------------------------------------------

/*
	The first thing along a line, and which body it belongs to.

	`translation` is the whole ray, direction *times* reach, not a direction, so
	the ray has an end. PsxGame's raylib original cast a ray with no length and
	had to pick a number when it moved to Box3D.

	`mask` is the categories the ray can see, as `category_bits` makes them, and
	defaults to all of them.

	Mask the player out of a look ray. Both games do, on the reasoning that the
	ray starts inside the player's capsule and would report it. Measured against
	this Box3D, a ray ignores a shape it starts inside *or exactly on*, and
	reports one it starts outside by any amount at all -- one float step above a
	capsule's top or a box's face is enough. Static or dynamic makes no
	difference.

	That last part is what bites, because the ordinary first-person setup puts
	the eye on the capsule's top and leaves which side of it to rounding. A
	1.7-tall capsule centred at 0.85 under Matchbox's 1.7 eye height is the case:
	in the body's own space the eye sits 0.350000024 above the upper sphere's
	centre, against a radius of 0.349999994, so it is outside and every downward
	glance names the player. A third-person camera starts outside the capsule on
	purpose and names it the same way. The mask stops the answer depending on
	any of that.
*/
cast_ray :: proc(origin: [3]f32, translation: [3]f32, mask: u64 = max(u64)) -> Ray_Hit {
	filter := b3.DefaultQueryFilter()
	filter.maskBits = mask

	result := b3.World_CastRayClosest(tpi.world, origin, translation, filter)

	// Zeroed here rather than trusted to Box3D, because `Ray_Hit` promises it.
	if !result.hit do return {}

	return Ray_Hit{
		hit    = true,
		body   = b3.Shape_GetBody(result.shapeId),
		shape  = result.shapeId,
		point  = result.point,
		normal = result.normal,
	}
}

/*
	Whether a ray landed on this body.

	It checks `hit` first, which comparing ids does not. A miss carries a zero
	body id, and so does a `Body` that was never created -- PsxGame's
	INTERACTABLE items have exactly that -- so `hit.body == item.body.id` on its
	own names every such item on every frame the ray hits nothing. Both games
	get this right by testing `hit.hit` first; this makes it the only way.
*/
is_body_hit :: proc(hit: Ray_Hit, body: ^Body) -> bool {
	return hit.hit && hit.body == body.id
}

// -----------------------------------------------------------------------
// Holding and placing
// -----------------------------------------------------------------------

/*
	Keeps a body at a point, as though in a hand. Call it every frame it is held.

	Kinematic while held, because a dynamic body teleported every frame still
	has gravity pulling it and contacts shoving it between teleports, and
	jitters. A kinematic body ignores both and still pushes dynamic bodies out of
	its way. Velocities are zeroed each time so that nothing carries over from
	the frame before, or from the fall it was picked up out of.

	Setting the type every frame costs nothing extra: Box3D's `Body_SetType`
	returns straight away when the type is not changing.

	CoffeeGame turns the held body with the player's yaw. It built that with
	`b3.MakeQuatFromAxisAngle({0, 1, 0}, -yaw)`, which without Box3D is
	`linalg.quaternion_angle_axis_f32(-yaw, {0, 1, 0})`. Note the arguments swap.
*/
hold_body :: proc(body: ^Body, point: [3]f32, rotation: quaternion128 = 1) {
	b3.Body_SetType(body.id, .kinematicBody)
	b3.Body_SetTransform(body.id, point, rotation)
	b3.Body_SetLinearVelocity(body.id, {0, 0, 0})
	b3.Body_SetAngularVelocity(body.id, {0, 0, 0})
}

/*
	Sets a body down against the surface a ray hit, and lets go of it.

	Answers whether it did: on a miss there is nowhere to put it, the body is
	left untouched, and the game should keep holding.

	The body is lifted off the surface along the hit normal by its half-extents
	projected onto that normal, so it rests against the face rather than half
	inside it. That projection is only exact for a box that is square to the
	world, which is why the rotation is reset to identity here rather than taken
	as an argument.

	Dynamic again afterwards, with both velocities zeroed after the type change,
	so it settles where it was put instead of carrying any motion from being
	held.
*/
place_body :: proc(body: ^Body, hit: Ray_Hit) -> bool {
	if !hit.hit do return false

	n := hit.normal
	h := body.half_extents
	lift := abs(n.x) * h.x + abs(n.y) * h.y + abs(n.z) * h.z

	b3.Body_SetTransform(body.id, hit.point + n * lift, 1)
	b3.Body_SetType(body.id, .dynamicBody)
	b3.Body_SetLinearVelocity(body.id, {0, 0, 0})
	b3.Body_SetAngularVelocity(body.id, {0, 0, 0})

	return true
}
