# Tether -- physics

**Tether is a Matchbox package**, `matchbox/tether`, imported as
`import "matchbox/tether"`. It was a repository of its own until 2026-09-17,
when it moved in here along with Eko; `CLAUDE.md` has why, and the short version
is that `level` wants to describe colliders that Tether builds, and a
dependency between two repositories has no good spelling. Nothing about the API
changed in the move.

Tether is a wrapper around Box3D (`vendor:box3d`) to help with physics.

It covers what PsxGame and MBCoffeeGame use Box3D for, and nothing more yet: a
world, box and capsule bodies, collision categories, a closest-ray cast, and
picking a body up and putting it down. A game using Tether does not import
`vendor:box3d` itself.

- [Getting it into a game](#getting-it-into-a-game)
- [Quick start](#quick-start)
- [How Tether thinks](#how-tether-thinks)
- [Guides](#guides)
  - [Floors and walls](#floors-and-walls)
  - [Colliders from Matchbox models](#colliders-from-matchbox-models)
  - [Drawing what the solver moves](#drawing-what-the-solver-moves)
  - [Colliders from a level](#colliders-from-a-level)
  - [A first-person player](#a-first-person-player)
  - [Looking at things](#looking-at-things)
  - [Picking up and putting down](#picking-up-and-putting-down)
  - [The order of a frame](#the-order-of-a-frame)
- [A whole game, with Matchbox](#a-whole-game-with-matchbox)
- [API reference](#api-reference)
- [Pitfalls](#pitfalls)
- [What is not here yet](#what-is-not-here-yet)
- [Coming from raw Box3D](#coming-from-raw-box3d)
- [Checking it](#checking-it)

---

## Getting it into a game

Tether is a folder in the Matchbox repository. Copy `matchbox/` into your game
as you already do, and import the package:

```odin
import "matchbox/tether"
```

It imports nothing from `package matchbox`, so a game may use one without the
other -- which is exactly why it sits beside `matchbox/` rather than inside it.

Box3D comes with Odin as `vendor:box3d`, and on Windows its static library ships
with the compiler, so there is no DLL to copy next to the game. Only a game that
imports `tether` links it at all.

## Quick start

No window, nothing drawn -- a crate dropped onto a floor:

```odin
package physics

import "core:fmt"

import "matchbox/tether"

main :: proc() {
	tether.init()
	defer tether.shutdown()

	// A floor whose top face is y = 0, and a crate five units above it.
	tether.create_box_body(position = {0, -0.5, 0}, half_extents = {50, 0.5, 50})
	crate := tether.create_box_body(position = {0, 5, 0}, half_extents = {0.5, 0.5, 0.5}, type = .DYNAMIC)

	// Three seconds at 60 steps a second.
	for _ in 0 ..< 180 {
		tether.step()
	}

	fmt.println(tether.get_body_position(&crate)) // resting on the floor: about [0, 0.5, 0]
}
```

The standalone repository this came from has a `main.odin` with a longer
version of the same thing -- a player walking into a wall -- which is not
carried here.

---

## How Tether thinks

### One world

`tether.init()` makes the world and `tether.shutdown()` destroys it, along with
every body in it. The world lives in one global, `tether.tpi`, for the same
reason Matchbox keeps `mbi`: every body and every ray belongs to the world, and
passing it to each call would add an argument everywhere for no gain. It also
means one world at a time.

### Bodies

Every body has exactly one shape, a box or a capsule, and comes back as a
`tether.Body`:

| Field | What it is |
| --- | --- |
| `id` | Box3D's handle for the body. What `Ray_Hit.body` is compared against. |
| `shape` | Box3D's handle for its one shape. |
| `offset` | Where the collider's centre sits relative to the `position` you gave. |
| `half_extents` | Half the collider's size. For a capsule, half the size of the box it fits in. |

`offset` and `half_extents` are set when the body is made and never change, so
copying a `Body` is safe. Position, rotation and type live in Box3D and are
always read from there, so they cannot go stale.

Procedures take a pointer: `tether.get_body_position(&crate)`.

### Body types

| Type | Behaviour | Use it for |
| --- | --- | --- |
| `.STATIC` | Never moves. Still collides. **The default.** | Floors, walls, furniture |
| `.KINEMATIC` | Moves only when you move it. Pushes dynamic bodies; nothing pushes it. | A held item |
| `.DYNAMIC` | Moved by the solver: gravity, contacts, velocity. | Props, the player |

### Two positions: the centre and the origin

A model's origin is rarely the middle of its bounds; often it sits at the base.
A collider, though, is centred on the geometry. So a body made from a model has
two useful points:

- **`get_body_position`** is the collider's centre, where the solver has it.
  `set_body_transform` and `hold_body` take this point too.
- **`get_body_origin`** is where to draw the model: the centre with `offset`
  backed out, after turning the offset by the body's rotation. Without the turn,
  a tumbling model would swing around the wrong point.

For a body made without an `offset`, such as the player's capsule, the two are
the same.

### Categories and masks

Name your categories with an enum, make a `bit_set` of it backed by `u64`, and
convert with `category_bits`:

```odin
Category :: enum {
	SCENERY,
	PROP,
	PLAYER,
}
Categories :: bit_set[Category; u64]

scenery := tether.category_bits(Categories{.SCENERY})
seen    := tether.category_bits(Categories{.SCENERY, .PROP})
```

- A body's **`category`** says what it is. The default is every bit, so a body
  given no category is seen by every ray.
- A ray's **`mask`** says what it can see. The default is every bit.
- A ray sees a body when the two share at least one bit.

**Categories filter rays, not collisions.** Every body still collides with every
other body whatever its category.

A `bit_set` that is not backed by `u64` is a compile error at your call, and an
enum can have at most 64 values (0 to 63).

---

## Guides

The Matchbox snippets below are written against the current Matchbox, imported
as `mb`, and are taken from the [whole game](#a-whole-game-with-matchbox) further
down, which compiles as written.

### Floors and walls

Static boxes. `half_extents` is **half** the size on each axis:

```odin
// 40 x 1 x 40, top face at y = 0.
floor := tether.create_box_body(position = {0, -0.5, 0}, half_extents = {20, 0.5, 20}, category = scenery)

// 40 wide, 3 tall, half a unit thick.
wall := tether.create_box_body(position = {0, 1.5, -10}, half_extents = {20, 1.5, 0.25}, category = scenery)
```

To see one, draw a cube of twice the half-extents at the body's position:

```odin
mb.draw_cube(tether.get_body_position(&floor), floor.half_extents * 2, mb.LIGHTGRAY)
```

### Colliders from Matchbox models

A box sized from the model's own bounds, so the box you collide with and the
model you see match by construction:

```odin
Item :: struct {
	model:    mb.Model,
	scale:    f32,
	name:     string,
	body:     tether.Body,
	holdable: bool,
	loaded:   bool,
}

load_item :: proc(path: string, position: [3]f32, scale: f32, type: tether.Body_Type, name: string) -> Item {
	item := Item{scale = scale, name = name, holdable = type == .DYNAMIC}

	err: mb.Error
	item.model, err = mb.load_model(path)
	if err != nil {
		log.errorf("%s: %v", path, err)
		return item
	}
	item.loaded = true

	// A static prop stands on the floor off its own bounds, so y = 0 means "on
	// the floor". A dynamic one keeps its y -- it falls from there.
	position := position
	if type == .STATIC do position.y = -item.model.bounds_min.y * scale

	category := Category.SCENERY if type == .STATIC else .PROP

	item.body = tether.create_box_body(
		position     = position,
		half_extents = mb.model_size(item.model) * scale * 0.5,
		offset       = mb.model_center(item.model) * scale,
		type         = type,
		category     = tether.category_bits(Categories{category}),
	)
	return item
}
```

What each argument is doing:

- **`position`** is where the model is drawn from, its origin.
- **`half_extents`** is half the scaled size. `model_size` is the whole size,
  hence the `* 0.5`.
- **`offset`** is the scaled centre of the model's bounds, so the box sits on the
  geometry rather than on the origin.
- **`type`** must be `.DYNAMIC` for anything that should fall or be picked up.
  The default, `.STATIC`, never moves.

The collider is one box around the **whole** model. That suits a prop, but not
a room or a scene exported as one file: the player would be sealed inside a
solid box. PsxGame ran into this with a 222 x 15 x 222 taco-cart scene. Give
those no body at all, or build their walls from boxes yourself.

### Drawing what the solver moves

Draw from the body's origin and rotation, not from a position stored in the
game. The same code works for static items, which simply never change:

```odin
for &item in items {
	if !item.loaded do continue

	mb.draw_model(item.model, mb.create_transform(
		tether.get_body_origin(&item.body),
		tether.get_body_rotation(&item.body),
		item.scale,
	))
}
```

### Colliders from a level

A level built in Stargate's editor carries a collider on every entity that is
meant to be solid, and `matchbox/level` hands each one over as a
`Collider_Desc`: a world-space description of a body that does not exist yet.
The level package never calls Tether -- Matchbox is a repository of its own, and
a game may clone it without cloning this one -- so making the bodies is the
game's, and this is all of it:

```odin
import mb     "matchbox/matchbox"
import lvl    "matchbox/level"
import "matchbox/tether"

make_level_solid :: proc(current: ^lvl.Level) {
	lvl.update_level(current) // the world matrices the descriptions are read from

	for desc in lvl.level_colliders(current, context.temp_allocator) {
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
}
```

- **`position` and `offset` are handed over separately** for a box, and Tether
  adds them, because a dynamic body is drawn from `get_body_origin` -- which
  backs the offset out again. Pass `desc.center` as the position instead and a
  falling crate is drawn a foot above itself.
- **A capsule takes `desc.center`**, because `create_capsule_body` has no
  offset argument. The description has already worked that point out.
- **`tether.Body_Type(desc.body)` is a cast, not a switch.** `lvl.Collider_Body`
  has Tether's three names in Tether's order on purpose; Stargate's
  `editor/collision_test.odin` asserts they still agree, since neither package
  can import the other to check.
- **Keep the `Body` values if the game needs them later** -- to pick a crate up,
  or to take a level's bodies out with `destroy_body` when the next one loads.
  Scenery that is only ever stood on can be made and forgotten.

A collider is not a `Shape_Component`. A shape is an area the level answers
questions about itself (`shape_contains`, for triggers and spawn points); a
collider is what the solver pushes things out of. An entity can carry both.

### A first-person player

An upright dynamic capsule, standing on the floor:

```odin
Player :: struct {
	rig:  mb.First_Person_Camera,
	body: tether.Body,
	held: ^tether.Body, // nil when the hand is empty
}

player := Player{
	rig  = mb.create_first_person_camera(),
	body = tether.create_capsule_body(
		position    = {0, 0.85, 3},
		radius      = 0.35,
		half_height = 0.5,
		type        = .DYNAMIC,
		category    = tether.category_bits(Categories{.PLAYER}),
		locks       = {.LINEAR_Y, .ANGULAR_X, .ANGULAR_Y, .ANGULAR_Z},
	),
}
```

- **Size.** `half_height` runs from the centre to the centre of each rounded
  end, so the capsule is `2 * (half_height + radius)` tall: 1.7 here, which
  matches Matchbox's default eye height. Its centre is at `0.85`, so its bottom
  touches the floor.
- **Locks.** `.LINEAR_Y` keeps the player's height fixed: no falling, and no
  jumping. The three angular locks keep the capsule from tipping over when it
  clips a corner.
- **Why a capsule.** It has no edges to catch, so it slides around corners
  instead of stopping dead.

Each frame, give the solver the velocity the keys ask for, step, then read the
capsule back and aim the camera from it:

```odin
if mb.is_cursor_locked() {
	mb.first_person_input(&player.rig)
} else {
	player.rig.move = {}
}

tether.set_body_linear_velocity(&player.body, player.rig.move * MOVE_SPEED)
tether.step()

feet := tether.get_body_position(&player.body) - {0, player.body.half_extents.y, 0}
mb.first_person_aim(&player.rig, feet)
```

`first_person_aim` adds the rig's eye height to whatever it is given, and the
body's position is the capsule's middle, so it is handed the feet.

Set the velocity every frame rather than pushing with forces. The solver then
decides where that movement ends up, which is what makes walls stop the player.
Floor friction does not slow a player moved this way: a capsule on the floor at
the default friction covers the same distance as one with none.

**A floor built out of tiles does, and badly.** That measurement above was taken
on one large slab. A floor made of separate colliders -- which is what a level
blocked out in Stargate has, one per floor tile -- catches the capsule's rounded
bottom on the *edge* where two boxes meet, and every seam pushes back against
the walk. Measured, asking for 1.2 units a second over two seconds:

| floor | covered |
| --- | --- |
| one slab | 2.40 |
| 1-metre tiles | 0.48 |
| 1-metre tiles, capsule held 0.02 above them | 2.40 |

Tile thickness makes no difference; the seams do. It is not friction -- setting
the capsule's friction to zero barely helps.

**Hold the capsule clear of the floor.** With `.LINEAR_Y` locked the capsule
never falls, so a two-centimetre gap is free and permanent: make the body that
much higher, and subtract it again when working out where to draw the character.
Take the lock off for a staircase and this has to go with it, since a floating
character cannot be carried down by gravity -- give the room one floor collider
instead of one per tile.

### Looking at things

Cast from the eye along the view, and ask each item whether the ray hit it:

```odin
eye     := player.rig.camera.position
forward := mb.camera3d_forward(player.rig.camera)

look := tether.cast_ray(eye, forward * REACH, mask = seen)

looking_at: ^Item
for &item in items {
	if tether.is_body_hit(look, &item.body) do looking_at = &item
}
```

- **`translation` is direction times reach**, not just a direction. The ray has
  an end.
- **Use `is_body_hit`**, not `look.body == item.body.id`. A miss has a zero body
  id, and so does an item whose model failed to load and never got a body, so
  comparing ids alone "hits" that item on every frame the ray hits nothing.
- **Mask the player out.** A ray ignores a shape it starts inside or exactly on,
  but reports one it starts outside by any amount, even a single float step.
  This guide's capsule is 1.7 tall and Matchbox puts the eye 1.7 above the feet,
  so the eye lands on the capsule's top, and float rounding leaves it a hair
  outside: without the mask, every downward glance would name the player. A
  third-person camera, whose rays start outside the capsule, needs the mask for
  the same reason.

### Picking up and putting down

Click to grab the item you are looking at; click again to set it down on
whatever scenery you are looking at:

```odin
if clicked {
	if player.held == nil {
		if looking_at != nil && looking_at.holdable do player.held = &looking_at.body
	} else {
		ground := tether.cast_ray(eye, forward * REACH, mask = scenery)
		if tether.place_body(player.held, ground) do player.held = nil
	}
}

if player.held != nil {
	hand := eye + forward * HOLD_DISTANCE + mb.camera3d_right(player.rig.camera) * 0.4
	tether.hold_body(player.held, hand, mb.transform_rotation({0, 1, 0}, -player.rig.yaw))
}
```

- **`hold_body` every frame.** It makes the body kinematic, moves it to the hand,
  and zeroes its velocity. A dynamic body teleported each frame would still have
  gravity and contacts fighting it, and would jitter.
- **The placing ray is masked to scenery**, so it passes through the item in
  your hand rather than landing on it. This is why props and scenery are
  separate categories.
- **`place_body` answers whether it put the body down.** On a miss (nothing
  within reach) it returns `false`, moves nothing, and you are still holding.
  On a hit it rests the body against the surface, square to the world, and makes
  it dynamic again.
- **`held` points into `items`.** Keep `items` a fixed array, as the whole game
  does, or at least do not grow a `[dynamic]` one while something is held.
  Appending can move the array and leave `held` pointing at freed memory.
- **Hold far enough out to clear the capsule.** A held body is kinematic, and
  kinematic bodies push dynamic ones, the player included.

### The order of a frame

1. **Input.** Read the keys and mouse.
2. **Velocities, then `step()`.** Set what should move, then let the solver
   move it.
3. **Read back.** Positions from the solver, and the camera from the player's
   new position.
4. **Rays.** From the camera as it now is.
5. **Pick up / put down**, from those rays.
6. **`hold_body`**, after the camera has moved, so the item is drawn exactly at
   the hand and not a frame behind.
7. **Draw**, from `get_body_origin` and `get_body_rotation`.

Keep `step()` at its fixed sixtieth of a second rather than passing the frame's
delta time. Box3D's continuous collision stops even a long step from dropping a
body through a floor, but contacts go soft as the step grows: a crate resting on
a floor ended up 0.05 units into it with half-second steps, and too little to
measure at a sixtieth.

---

## A whole game, with Matchbox

Everything above in one program: a floor, a table, a plate that falls onto it,
a player who can walk around, see what they are looking at, and pick the plate
up and put it down. The two model paths are placeholders; point them at your
own `.glb` files.

```odin
package game

import "core:log"

import mb "matchbox/matchbox"
import "matchbox/tether"

MOVE_SPEED    :: 5
REACH         :: 3
HOLD_DISTANCE :: 1

Category :: enum {
	SCENERY, // static: floors, walls, furniture
	PROP,    // dynamic: things that fall and can be picked up
	PLAYER,
}
Categories :: bit_set[Category; u64]

Item :: struct {
	model:    mb.Model,
	scale:    f32,
	name:     string,
	body:     tether.Body,
	holdable: bool,
	loaded:   bool,
}

Player :: struct {
	rig:  mb.First_Person_Camera,
	body: tether.Body,
	held: ^tether.Body, // nil when the hand is empty
}

load_item :: proc(path: string, position: [3]f32, scale: f32, type: tether.Body_Type, name: string) -> Item {
	item := Item{scale = scale, name = name, holdable = type == .DYNAMIC}

	err: mb.Error
	item.model, err = mb.load_model(path)
	if err != nil {
		log.errorf("%s: %v", path, err)
		return item
	}
	item.loaded = true

	// A static prop stands on the floor off its own bounds, so y = 0 means "on
	// the floor". A dynamic one keeps its y -- it falls from there.
	position := position
	if type == .STATIC do position.y = -item.model.bounds_min.y * scale

	category := Category.SCENERY if type == .STATIC else .PROP

	item.body = tether.create_box_body(
		position     = position,
		half_extents = mb.model_size(item.model) * scale * 0.5,
		offset       = mb.model_center(item.model) * scale,
		type         = type,
		category     = tether.category_bits(Categories{category}),
	)
	return item
}

main :: proc() {
	mb.init("Tether + Matchbox", 1280, 720)
	defer mb.cleanup()
	context.logger = mb.mbi.logger

	mb.set_escape_key(.UNKNOWN)
	mb.set_cursor_locked(true)

	tether.init()
	defer tether.shutdown()

	scenery := tether.category_bits(Categories{.SCENERY})
	seen    := tether.category_bits(Categories{.SCENERY, .PROP})

	floor := tether.create_box_body(position = {0, -0.5, 0}, half_extents = {20, 0.5, 20}, category = scenery)

	items := [?]Item{
		load_item("./assets/models/table.glb", {0, 0, -2}, 1, .STATIC,  "table"),
		load_item("./assets/models/plate.glb", {0, 3, -2}, 1, .DYNAMIC, "plate"),
	}
	defer for &item in items {
		if item.loaded do mb.destroy(&item.model)
	}

	player := Player{
		rig  = mb.create_first_person_camera(),
		body = tether.create_capsule_body(
			position    = {0, 0.85, 3},
			radius      = 0.35,
			half_height = 0.5,
			type        = .DYNAMIC,
			category    = tether.category_bits(Categories{.PLAYER}),
			locks       = {.LINEAR_Y, .ANGULAR_X, .ANGULAR_Y, .ANGULAR_Z},
		),
	}

	for mb.is_running() {
		mb.poll_events()

		// Read before the click below can re-lock the cursor, so the click that
		// takes the mouse back is not also a grab.
		clicked := mb.is_cursor_locked() && mb.is_mouse_pressed(.LEFT)

		if mb.is_key_pressed(.ESCAPE) {
			if mb.is_cursor_locked() do mb.set_cursor_locked(false)
			else                     do mb.mbi.running = false
		}
		if !mb.is_cursor_locked() && mb.is_mouse_pressed(.LEFT) do mb.set_cursor_locked(true)

		// 1. Input
		if mb.is_cursor_locked() {
			mb.first_person_input(&player.rig)
		} else {
			player.rig.move = {}
		}

		// 2. Velocity in, step
		tether.set_body_linear_velocity(&player.body, player.rig.move * MOVE_SPEED)
		tether.step()

		// 3. Read back, aim the camera
		feet := tether.get_body_position(&player.body) - {0, player.body.half_extents.y, 0}
		mb.first_person_aim(&player.rig, feet)

		eye     := player.rig.camera.position
		forward := mb.camera3d_forward(player.rig.camera)

		// 4. Rays
		look := tether.cast_ray(eye, forward * REACH, mask = seen)

		looking_at: ^Item
		for &item in items {
			if tether.is_body_hit(look, &item.body) do looking_at = &item
		}

		// 5. Pick up, put down
		if clicked {
			if player.held == nil {
				if looking_at != nil && looking_at.holdable do player.held = &looking_at.body
			} else {
				ground := tether.cast_ray(eye, forward * REACH, mask = scenery)
				if tether.place_body(player.held, ground) do player.held = nil
			}
		}

		// 6. Hold
		if player.held != nil {
			hand := eye + forward * HOLD_DISTANCE + mb.camera3d_right(player.rig.camera) * 0.4
			tether.hold_body(player.held, hand, mb.transform_rotation({0, 1, 0}, -player.rig.yaw))
		}

		// 7. Draw
		mb.begin_drawing()
		mb.clear_background(mb.SKYBLUE)

		mb.begin_drawing_3d(player.rig.camera)

		mb.draw_cube(tether.get_body_position(&floor), floor.half_extents * 2, mb.LIGHTGRAY)

		for &item in items {
			if !item.loaded do continue

			mb.draw_model(item.model, mb.create_transform(
				tether.get_body_origin(&item.body),
				tether.get_body_rotation(&item.body),
				item.scale,
			))
		}

		mb.end_drawing_3d()

		if looking_at != nil {
			mb.draw_text(&mb.mbi.font, looking_at.name, 40, f32(mb.mbi.height) * 0.5 + 60, mb.WHITE)
		}

		mb.end_drawing()
	}
}
```

---

## API reference

Every procedure's doc comment in [tether/tether.odin](tether/tether.odin) goes
further into the why; this is the what.

### The world

| Procedure | Does |
| --- | --- |
| `init(gravity: [3]f32 = {0, -10, 0})` | Makes the world. Call once, before anything else. |
| `shutdown()` | Destroys the world and every body in it. Their ids stop being valid. `destroy_body` removes just one. Safe to call twice, or with no world. |
| `step(time_step: f32 = 1.0 / 60.0, sub_steps: i32 = 4)` | Advances the simulation one step. More `sub_steps` costs more and settles stacks and fast bodies better. |
| `category_bits(categories: bit_set[E; u64]) -> u64` | Turns your categories into the `u64` that `category` and `mask` take. |

### Making bodies

```odin
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
) -> Body

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
) -> Body
```

Every argument is defaulted; name the ones you need.

| Argument | Meaning |
| --- | --- |
| `position` | Box: the origin, with the collider centred at `position + offset`. Capsule: the capsule's centre. |
| `half_extents` | Half the box's size on each axis. |
| `offset` | Box only. Collider centre relative to `position`, usually `model_center * scale`. |
| `radius` | Capsule only. Radius of the rounded ends and the body. |
| `half_height` | Capsule only. Centre to the centre of each rounded end. Total height is `2 * (half_height + radius)`. |
| `type` | `.STATIC`, `.KINEMATIC` or `.DYNAMIC`. Defaults to `.STATIC`, which never moves. |
| `category` | What this body is, from `category_bits`. Defaults to every bit. |
| `density` | Defaults to 1, what both games used, not Box3D's 1000. Only matters relative to other bodies: how hard things push each other. |
| `friction` | Defaults to 0.6, Box3D's own default. |
| `locks` | Ways the body may not move: `.LINEAR_X/Y/Z`, `.ANGULAR_X/Y/Z`. |
| `rotation` | How the body is turned where it stands. A box turns its `offset` with it; a capsule's axis is +Y, so a quarter turn about Z lays it down. |

### Reading and moving bodies

| Procedure | Does |
| --- | --- |
| `get_body_position(body: ^Body) -> [3]f32` | The collider's centre. |
| `get_body_rotation(body: ^Body) -> quaternion128` | How the body is turned. |
| `get_body_origin(body: ^Body) -> [3]f32` | Where to draw: the centre with the rotated `offset` backed out. |
| `set_body_transform(body: ^Body, position: [3]f32, rotation: quaternion128 = 1)` | Teleports the collider's centre. Nothing in between is collided with. |
| `set_body_type(body: ^Body, type: Body_Type)` | Changes what the solver does with the body. |
| `set_body_linear_velocity(body: ^Body, velocity: [3]f32)` | Units per second. |
| `set_body_angular_velocity(body: ^Body, velocity: [3]f32)` | Radians per second about each axis. |
| `destroy_body(body: ^Body)` | Takes one body out of the world and zeroes the `Body`, leaving the rest standing. |

### Rays

| Procedure | Does |
| --- | --- |
| `cast_ray(origin: [3]f32, translation: [3]f32, mask: u64 = max(u64)) -> Ray_Hit` | The first body along `origin` to `origin + translation` whose category shares a bit with `mask`. |
| `is_body_hit(hit: Ray_Hit, body: ^Body) -> bool` | Whether the ray hit this body. Safe for a body that was never created. |

`Ray_Hit` has `hit: bool`, `body: Body_Id`, `shape: Shape_Id`, `point: [3]f32`
and `normal: [3]f32`. Every field is zero on a miss.

### Holding and placing

| Procedure | Does |
| --- | --- |
| `hold_body(body: ^Body, point: [3]f32, rotation: quaternion128 = 1)` | Makes the body kinematic, moves its centre to `point`, and zeroes its velocity. Call every frame it is held. |
| `place_body(body: ^Body, hit: Ray_Hit) -> bool` | Rests the body against the surface `hit` found, unrotated, dynamic and still. Returns `false` and does nothing on a miss. |

### Types

| Type | What it is |
| --- | --- |
| `Body` | `id`, `shape`, `offset`, `half_extents`. See [Bodies](#bodies). |
| `Body_Type` | `STATIC`, `KINEMATIC`, `DYNAMIC`. |
| `Motion_Lock`, `Motion_Locks` | `LINEAR_X`, `LINEAR_Y`, `LINEAR_Z`, `ANGULAR_X`, `ANGULAR_Y`, `ANGULAR_Z`, and a `bit_set` of them. |
| `Ray_Hit` | What `cast_ray` returns. |
| `Body_Id`, `Shape_Id` | Box3D's handles, named so a game can store them without importing Box3D. |
| `Tether_Instance`, `tpi` | The global holding the world. |

---

## Pitfalls

- **The body never moves.** `type` defaults to `.STATIC`. Pass `type = .DYNAMIC`.
- **The collider is twice as big as the model.** `half_extents` wants half the
  size: `mb.model_size(model) * scale * 0.5`.
- **The model is drawn off to one side of where it lands.** It is being drawn at
  `get_body_position`. Draw at `get_body_origin`.
- **Looking at nothing names an item.** That's an id comparison without checking
  `hit`. Use `is_body_hit`.
- **Two bodies in different categories still collide.** Categories only filter
  rays.
- **The player spawns stuck.** A whole-scene model became one solid box around
  the spawn point. Give it no body.
- **Things sink into the floor after a hitch.** `step` was given the frame's
  delta time, and long steps make contacts soft. Keep the fixed step.
- **The player walks at a fraction of its speed, and snags on nothing.** The
  floor is many colliders rather than one, and the capsule is catching on the
  seams between them. Hold it a couple of centimetres above the floor, or give
  the room one floor collider. See [A first-person player](#a-first-person-player).
- **`held` points at garbage.** The array it points into grew. Keep items in a
  fixed array.
- **A held item shoves the player.** It overlaps the capsule. Hold it further
  out.
- **Tests fail at random.** They were run in parallel against the one world.
  Add `-define:ODIN_TEST_THREADS=1`.

## What is not here yet

Tether wraps what the two games used, and stops there. Not yet:

- spheres, meshes, convex hulls other than boxes, or several shapes on one body
- joints
- contact, sensor or hit events
- a shape mask, meaning which categories a body collides with
- jumping, stairs and gravity for the player: the recommended locks fix its
  height
- more than one world

Each arrives when a game needs it.

---

## Coming from raw Box3D

| The games wrote | Tether |
| --- | --- |
| `DefaultWorldDef`, set `gravity`, `CreateWorld` | `init(gravity)` |
| `DestroyWorld` | `shutdown()` |
| `World_Step(world, 1.0 / 60.0, 4)` | `step()` |
| `DefaultBodyDef`, `CreateBody`, `MakeBoxHull`, `DefaultShapeDef`, `CreateHullShape` | `create_box_body(...)` |
| the same with `Capsule` and `CreateCapsuleShape` | `create_capsule_body(...)` |
| `body_def.motionLocks = {linearY = true, ...}` | `locks = {.LINEAR_Y, ...}` |
| `transmute(u64)Categories{...}` | `category_bits(Categories{...})` |
| `DefaultQueryFilter`, set `maskBits`, `World_CastRayClosest`, `Shape_GetBody` | `cast_ray(origin, translation, mask)` |
| `hit.hit && item.shape == hit.shapeId` | `is_body_hit(hit, &item.body)` |
| `Body_GetPosition` | `get_body_position` |
| `Body_GetPosition - quaternion128_mul_vector3(Body_GetRotation, center)` | `get_body_origin` |
| `Body_GetRotation` | `get_body_rotation` |
| `Body_SetTransform` | `set_body_transform` |
| `Body_SetType` | `set_body_type` |
| `Body_SetLinearVelocity`, `Body_SetAngularVelocity` | `set_body_linear_velocity`, `set_body_angular_velocity` |
| pick up: `SetType(.kinematicBody)`, `SetTransform`, zero both velocities | `hold_body(&body, point, rotation)` |
| put down: lift along the normal by the half-extents, `SetTransform`, `SetType(.dynamicBody)`, zero both velocities | `place_body(&body, hit)` |
| `MakeQuatFromAxisAngle(axis, angle)` | not wrapped: `mb.transform_rotation(axis, angle)` or `linalg.quaternion_angle_axis_f32(angle, axis)` |

The games also stood their player's capsule in mid-air at eye height and wrote
that height into the camera by hand. The [player guide](#a-first-person-player)
stands it on the floor instead and lets Matchbox's rig add the eye height, so the
capsule also bumps into things lower than its old floating bottom edge.

## Checking it

```
odin check tether -no-entry-point
odin test tether -define:ODIN_TEST_THREADS=1
```

Run both from the Matchbox repository root.

The tests share the one world in `tpi`, so they run one at a time.
