package level

/*
	Colliders
	---------
	What a level is solid with. A box or a capsule on an entity, which a game
	hands to a physics engine so that its player walks on the floors and into
	the walls that were built in the editor. Stargate's `level_editor_plan.md`
	section 5.21 is the design.

	**The level describes bodies; it does not make them.** Nothing here imports
	Tether, and nothing here imports `vendor:box3d`. `level_colliders` hands
	back a list of `Collider_Desc`, each one a world-space description of a body
	that does not exist yet, and the game makes it:

		for desc in level.level_colliders(&yard, context.temp_allocator) {
			switch desc.kind {
			case .BOX:
				tether.create_box_body(
					position     = desc.position,
					offset       = desc.offset,
					half_extents = desc.half_extents,
					rotation     = desc.rotation,
					type         = tether.Body_Type(desc.body),
					density      = desc.density,
					friction     = desc.friction,
				)
			case .CAPSULE:
				tether.create_capsule_body(
					position    = desc.center,
					radius      = desc.radius,
					half_height = desc.half_height,
					rotation    = desc.rotation,
					type        = tether.Body_Type(desc.body),
					density     = desc.density,
					friction    = desc.friction,
				)
			}
		}

	**Why not build the bodies here.** Tether is a Matchbox package now --
	`matchbox/tether`, which this file could reach as `../tether` -- so the
	original reason, that it was a path out of the repository, went away on
	2026-09-17 when it moved in. Two reasons did not, and the first is enough on
	its own:

	- **Importing `tether` here would link Box3D into every game that loads a
	  level.** `level` is what a game imports to draw a scene somebody built in
	  an editor, and plenty of those never want physics at all. That is the same
	  cost that keeps `tether` out of `package matchbox` in the first place
	  (CLAUDE.md, Scope), and it does not get cheaper by being paid one package
	  further in.
	- **A description survives a game that uses something else**, or nothing.
	  `Collider_Desc` is a box and a capsule in world space; it names no solver.

	The price is ten lines per game, which is `tether.md`'s "Colliders from a
	level" and, run for real, Stargate's `editor/collision.odin`.

	**If those ten lines ever want a home**, it is a small package of its own
	importing both -- not this one, and not `tether`, since `tether` importing
	`level` would link Matchbox into a game that only wanted physics. Nobody has
	written the same ten lines twice yet, so nobody has needed it.

	**A collider is not a shape** (shape.odin). A shape is an area the game asks
	questions about -- is the player inside this trigger, where is this camera
	zone -- and the level answers them itself, with `shape_contains` and
	`shape_bounds`. A collider is a body the solver pushes things out of, and
	the level cannot answer anything about it without a solver. They are
	separate components because an entity often wants one and not the other: a
	trigger area is a shape with no collider, a wall is a collider with no
	shape, and a crate that is both solid and watched for carries both.

	**Box and capsule, because that is what Tether has.** A collider kind this
	package invented but nothing could build would be a field the editor offers
	and a game silently drops.
*/

import "core:math/linalg"

import mb "../matchbox"

/*
	What shape the collider is.

	A box for nearly everything a level is built from, and a capsule for
	anything that has to slide round a corner rather than catch on it. Both are
	turned and placed by the entity's transform, as everything else is.
*/
Collider_Kind :: enum {
	BOX,     // `size` is the half-extent on each axis
	CAPSULE, // `size.x` is the radius, `size.y` the half-height; the axis is +Y
}

/*
	What the solver is to do with the body.

	The names and their order are Tether's `Body_Type`, so that a game converts
	with a cast rather than a switch that could fall out of step with it. The
	editor's `collision_test.odin` asserts the two agree, which is the only
	place both packages are in scope at once.
*/
Collider_Body :: enum {
	STATIC,    // never moves, still collides -- floors, walls, scenery
	KINEMATIC, // moved by the game, pushes dynamic bodies, pushed by nothing
	DYNAMIC,   // moved by the solver -- gravity, contacts, velocity
}

/*
	A collider on an entity: a shape, a size and how the solver treats it.

	Where it is and how it is turned are not here. They come from the entity's
	world matrix, the same way a light's direction and a camera's aim do, so the
	move and rotate gizmos place a collider with nothing added and there is no
	second position to keep in step with the first.

	**No colour**, unlike `Shape_Component`. Every collider means the same thing,
	so one colour for all of them says as much as a colour each, and leaving it
	out keeps four numbers per collider out of every level file.

	**No category, and no motion locks.** Tether has both, and a level has no use
	for either yet: a ray's mask is the game's own enum, which a level cannot
	know, and the mapping a game actually writes is one line off the body type
	(`tether.md`: scenery when static, a prop when dynamic). Locks belong to
	the player's capsule, which the game makes and the level never sees. Each
	arrives here when a level needs it rather than because Tether has it.
*/
Collider_Component :: struct {
	kind: Collider_Kind,
	body: Collider_Body,

	// BOX: the half-extent on each axis. CAPSULE: `x` is the radius and `y` the
	// half-height, centre to the centre of each rounded end, so the capsule
	// stands `2 * (y + x)` tall. In the entity's own space, before its scale.
	size: [3]f32,

	// The collider's centre, relative to where the entity is drawn, in the
	// entity's own space. A model's origin is rarely the middle of its bounds
	// -- usually it is the base -- and a collider is centred on the geometry.
	// `fit_collider_to_model` fills this in from the model's own bounds.
	offset: [3]f32,

	// Only relative to other bodies: how hard things push each other. Tether's
	// default, 1, rather than Box3D's 1000.
	density: f32,

	// Tether's default, 0.6. Unread for a static body's own motion, but it is
	// half of every contact a static body takes part in, so a floor's friction
	// is what slows a crate sliding on it.
	friction: f32,
}

Collider_Defaults :: struct {
	size:     f32,
	density:  f32,
	friction: f32,
}

// Half a metre, and Tether's own density and friction. What a collider with
// nothing filled in gets on load, and what the editor puts on a new one.
COLLIDER_DEFAULTS :: Collider_Defaults{size = 0.5, density = 1, friction = 0.6}

/*
	One body a game should make, in world space, with everything a physics
	engine needs to make it and nothing it does not.

	`position` and `offset` are split the way Tether splits them, rather than
	handed over as the one point they add up to: a dynamic body is drawn from
	`get_body_origin`, which backs the offset out again, so a game that passed
	the centre as the position would draw a falling crate a foot above itself.
	`center` is that sum, worked out here, for anything that only wants the
	point -- drawing a wire box over a collider, say.

	`name` and `entity` are borrowed from the level, so that a game can tell
	which entity a body came from. The name is the entity's own string and lives
	exactly as long as the level does.
*/
Collider_Desc :: struct {
	entity: Entity_Handle,
	name:   string,

	kind: Collider_Kind,
	body: Collider_Body,

	// Where the entity is drawn, in the world: Tether's `position`.
	position: [3]f32,

	// The collider's centre relative to that, scaled but not turned: Tether's
	// `offset`, which it turns by the rotation below.
	offset: [3]f32,

	// `position` with the turned `offset` added: where the collider's centre
	// actually is. A capsule has no offset argument in Tether, so this is the
	// point a capsule body is made at.
	center: [3]f32,

	rotation: quaternion128,

	half_extents: [3]f32, // BOX
	radius:       f32,    // CAPSULE
	half_height:  f32,    // CAPSULE

	density:  f32,
	friction: f32,
}

/*
	The body one entity's collider asks for, in world space. False when the
	entity is gone or has no collider.

	Needs `update_level` to have run, like everything that reads a world
	placement.

	**Scale is applied**, unlike a light's or a camera's: a wall scaled to twice
	the length is twice as long to walk along, and a collider that ignored that
	would be a wall you could walk through half of. A box scales on each axis. A
	capsule cannot become an ellipse, so its radius takes the larger of the two
	scales across its axis and its half-height takes the scale along it -- which
	is the closest a capsule can come, and is why a collider stretched unevenly
	is better authored as a box.
*/
collider_desc :: proc(level: ^Level, handle: Entity_Handle) -> (desc: Collider_Desc, ok: bool) {
	entity := get_entity(level, handle)
	if entity == nil do return {}, false

	component := entity.collider.? or_return

	world := mb.transform_from_matrix(entity.world)
	scale := [3]f32{abs(world.scale.x), abs(world.scale.y), abs(world.scale.z)}

	desc = Collider_Desc{
		entity   = Entity_Handle{index = handle.index, id = entity.id},
		name     = entity.name,
		kind     = component.kind,
		body     = component.body,
		position = world.position,
		offset   = component.offset * scale,
		rotation = world.rotation,
		density  = component.density,
		friction = component.friction,
	}
	desc.center = desc.position + linalg.quaternion_mul_vector3(world.rotation, desc.offset)

	switch component.kind {
	case .BOX:
		desc.half_extents = component.size * scale
	case .CAPSULE:
		desc.radius      = component.size.x * max(scale.x, scale.z)
		desc.half_height = component.size.y * scale.y
	}

	return desc, true
}

/*
	Every collider in the level, in list order, ready to be made into bodies.

	Handed back rather than made, for the reason at the top of this file. A
	level with no colliders answers with an empty list, not a failure: a level
	that is only scenery to look at is a level, and the loop over it does
	nothing.

	`delete` the list when finished, or pass the temp allocator -- the strings
	inside it are the level's and must not be freed.
*/
level_colliders :: proc(level: ^Level, allocator := context.allocator) -> [dynamic]Collider_Desc {
	descs := make([dynamic]Collider_Desc, 0, 8, allocator)

	for entity, i in level.entities {
		handle := Entity_Handle{index = i, id = entity.id}
		if desc, ok := collider_desc(level, handle); ok do append(&descs, desc)
	}
	return descs
}

/*
	The same, for the entity with this name -- beside `get_level_camera` and
	`get_level_shape_bounds`, and read the same way. A name with a slash in it
	is a path through the tree (`find_entity_path`).

		floor, ok := level.get_level_collider(&yard, "ground/floor")
*/
get_level_collider :: proc(level: ^Level, name: string) -> (desc: Collider_Desc, ok: bool) {
	handle := find_entity_path(level, name) or_else Entity_Handle{}
	return collider_desc(level, handle)
}

/*
	Sizes an entity's collider to fit its own model, and returns whether it
	could.

	This is the one thing an editor cannot work out from the transform, and the
	thing every collider on a model wants: the box you collide with and the
	model you see match by construction, rather than by someone dragging three
	numbers until they look right.

	Needs the model loaded -- `load_level_models` first -- since the bounds come
	off the loaded model. In the entity's **own** space, before its scale, so an
	entity scaled after the fit stays fitted.

	A capsule is fitted round the model rather than inside it: the radius takes
	the larger of the two widths, so a model wider than it is deep is not
	clipped, and the half-height is what is left over the rounded ends -- zero
	for a model shorter than it is wide, which makes a sphere, and is right.
*/
fit_collider_to_model :: proc(level: ^Level, handle: Entity_Handle) -> bool {
	entity := get_entity(level, handle)
	if entity == nil do return false

	collider, has_collider := &entity.collider.?
	if !has_collider do return false

	model, has_model := entity.model.?
	if !has_model || model.model == nil do return false

	size   := mb.model_size(model.model^)
	centre := mb.model_center(model.model^)

	switch collider.kind {
	case .BOX:
		collider.size = size * 0.5
	case .CAPSULE:
		radius := max(size.x, size.z) * 0.5
		collider.size = {radius, max(size.y * 0.5 - radius, 0), 0}
	}
	collider.offset = centre
	return true
}

/*
	What a collider read from a file gets for a key that was left out, called
	from `repair_level`.

	The rules live here, with the component, rather than inline in
	`repair_level` beside the shape's: a component's own file is where someone
	changing it will look.

	**A zero friction is repaired to 0.6 rather than kept.** Rejected: keeping
	it, so that a frictionless collider could be written. A level file is meant
	to be hand-editable, and a floor written without a `friction` key would then
	be ice -- a bug with nothing visibly wrong in the file. Something as near
	frictionless as makes no difference is still writable, as 0.001.
*/
@(private)
repair_collider :: proc(collider: ^Collider_Component) {
	if collider.density  == 0 do collider.density  = COLLIDER_DEFAULTS.density
	if collider.friction == 0 do collider.friction = COLLIDER_DEFAULTS.friction

	switch collider.kind {
	case .BOX:
		// Any axis at zero is a plane with no inside, which the solver has
		// nothing to push a body out of.
		for &axis in collider.size {
			if axis == 0 do axis = COLLIDER_DEFAULTS.size
		}
	case .CAPSULE:
		// A zero half-height is a sphere and is allowed; a zero radius is not
		// a shape at all.
		if collider.size.x == 0 do collider.size.x = COLLIDER_DEFAULTS.size
	}
}
