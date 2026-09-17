package level

/*
	Where entities are
	------------------
	An entity's saved transform is relative to its parent (Stargate's
	`level_editor_plan.md`, 5.11). Drawing, lights and a game asking where the
	spawn point is all want the world, so `update_level` resolves a world
	matrix for every entity once a frame and everything reads that.

	**Everything that asks where an entity is reads its world matrix, and
	everything that moves one writes through `set_world_transform`**, so no
	caller has to know whether the entity has a parent.
*/

import "base:runtime"
import "core:math/linalg"
import "core:strings"

import mb "../matchbox"

/*
	A way to refer to an entity that notices when it has gone.

	The index is where the entity was, which is quick; the id is which entity
	it was, which is right. An index alone silently names whatever later took
	its slot, and a pointer dangles as soon as the entity list grows. Ids are
	unique within a level -- `unmarshal_level` repairs any that are not -- so a
	handle whose index no longer holds its id is looked up by id, and one
	whose id is nowhere names an entity that is gone.
*/
Entity_Handle :: struct {
	index: int,
	id:    u64,
}

// The first entity with this name. Names are for people and need not be
// unique; ids are what is unique.
find_entity :: proc(level: ^Level, name: string) -> (handle: Entity_Handle, found: bool) {
	for entity, i in level.entities {
		if entity.name == name do return {index = i, id = entity.id}, true
	}
	return {}, false
}

/*
	The first child of `parent` with this name.

	**Because a name is only unique where the level-builder made it so**, and a
	group built by duplicating another is exactly where they did not: a fixed
	camera shot is an empty entity holding a `camera` and a `bounds`, so a level
	with four shots in it has four entities called `camera`. `find_entity` can
	only ever reach the first of them, which is why this exists.

	Only the direct children are looked at, not the whole subtree. A name is
	found where it was put rather than somewhere below it, so adding a group
	deeper down cannot change what a lookup already answered.
*/
find_child :: proc(level: ^Level, parent: Entity_Handle, name: string) -> (handle: Entity_Handle, found: bool) {
	owner := get_entity(level, parent)
	if owner == nil do return {}, false

	// Read before the loop: `owner` points into the entity list, and the id is
	// what the children name.
	id := owner.id

	for entity, i in level.entities {
		if entity.parent == id && entity.name == name do return {index = i, id = entity.id}, true
	}
	return {}, false
}

// What separates one name from the next in a path (`find_entity_path`). A
// slash, because a level's entities are a tree and everyone already reads a
// slash that way.
ENTITY_PATH_SEPARATOR :: '/'

/*
	The entity a path of names leads to -- `"fixed_angle_one/camera"`.

	The first name is looked up anywhere in the level, as `find_entity` does;
	every name after it is looked up among the children of the one before. So a
	path is as long as it needs to be to say which entity is meant, and no
	longer: the group is named because there are four `camera`s, and the group's
	own parent is not because there is one `fixed_angle_one`.

	A name with no separator in it is exactly `find_entity`, which is why the
	procedures a game calls by name -- `get_level_camera`,
	`get_level_shape_bounds`, `get_level_entity_transform` -- all read a path
	now: an existing call means what it always meant.

	An empty path, or an empty name inside one, is not found. `"a//b"` is a
	typo, and quietly reading it as `"a/b"` would hide it.
*/
find_entity_path :: proc(level: ^Level, path: string) -> (handle: Entity_Handle, found: bool) {
	if path == "" do return {}, false

	rest    := path
	matched := false

	for {
		name := rest

		// Whether a separator was cut, rather than whether anything is left
		// after it: those differ for exactly the trailing separator in
		// `"a/"`, whose empty last name is the typo this has to catch.
		more := false
		if cut := strings.index_byte(rest, ENTITY_PATH_SEPARATOR); cut >= 0 {
			name = rest[:cut]
			rest = rest[cut + 1:]
			more = true
		}

		if name == "" do return {}, false

		step: bool
		if matched {
			handle, step = find_child(level, handle, name)
		} else {
			handle, step = find_entity(level, name)
		}
		if !step do return {}, false

		matched = true
		if !more do return handle, true
	}
}

/*
	Every entity whose parent is this one, in the order the level lists them.

	For walking a group the level-builder filled rather than naming each member
	-- a `cameras` empty holding however many shots the room turned out to need,
	so adding a fifth is a thing done in the editor and nowhere else.

	`delete` the slice when finished.
*/
level_children :: proc(level: ^Level, parent: Entity_Handle, allocator := context.allocator) -> []Entity_Handle {
	owner := get_entity(level, parent)
	if owner == nil do return nil

	id := owner.id

	children := make([dynamic]Entity_Handle, 0, 4, allocator)
	for entity, i in level.entities {
		if entity.parent == id do append(&children, Entity_Handle{index = i, id = entity.id})
	}
	return children[:]
}

// The entity a handle names, or nil when it is no longer in the level. The
// pointer is good until the entity list next changes.
get_entity :: proc(level: ^Level, handle: Entity_Handle) -> ^Entity {
	if handle.id == 0 do return nil

	if handle.index >= 0 && handle.index < len(level.entities) && level.entities[handle.index].id == handle.id {
		return &level.entities[handle.index]
	}

	return entity_by_id(level, handle.id)
}

/*
	Works out every entity's world matrix: its parent's world matrix times its
	own transform. Call once a frame, after anything has moved and before
	drawing, `level_lights` or `get_world_transform`.

	**Parents need not come before their children in the list.** Each entity
	is resolved by walking up to the nearest ancestor already resolved this
	frame, or to the root, and back down. Requiring parents first would make
	the loop simpler and make attaching an entity reorder the file.

	A parent id that names nothing, or a loop, makes that entity a root here
	rather than hanging. `unmarshal_level` repairs both on load and reports
	them; this only has to not fall over if something has built one since.
*/
update_level :: proc(level: ^Level) {
	n  := len(level.entities)
	rt := &level.runtime
	allocator := level_allocator(level)

	if rt.index_of == nil do rt.index_of = make(map[u64]int, allocator)
	clear(&rt.index_of)
	for entity, i in level.entities do rt.index_of[entity.id] = i

	if rt.resolve_state.allocator.procedure == nil do rt.resolve_state = make([dynamic]Resolve_State, allocator)
	if rt.resolve_chain.allocator.procedure == nil do rt.resolve_chain = make([dynamic]int, allocator)

	resize(&rt.resolve_state, n)
	for &state in rt.resolve_state do state = .UNRESOLVED

	for start in 0 ..< n {
		if rt.resolve_state[start] == .RESOLVED do continue

		// Up, until a parent that is already resolved, or none, or one this
		// walk has already passed through -- a loop.
		clear(&rt.resolve_chain)
		current := start
		for {
			append(&rt.resolve_chain, current)
			rt.resolve_state[current] = .ON_THIS_WALK

			parent_id := level.entities[current].parent
			if parent_id == 0 do break

			parent, found := rt.index_of[parent_id]
			if !found || rt.resolve_state[parent] != .UNRESOLVED do break

			current = parent
		}

		// Down. The top of the chain hangs off an already-resolved parent or
		// off nothing; every entity below it off the one resolved just before.
		top := len(rt.resolve_chain) - 1
		for k := top; k >= 0; k -= 1 {
			i      := rt.resolve_chain[k]
			entity := &level.entities[i]
			local  := mb.transform_matrix(transform_from_level_transform(entity.transform))

			if k < top {
				entity.world = level.entities[rt.resolve_chain[k + 1]].world * local
			} else if parent, found := rt.index_of[entity.parent]; entity.parent != 0 && found && rt.resolve_state[parent] == .RESOLVED {
				entity.world = level.entities[parent].world * local
			} else {
				entity.world = local
			}

			rt.resolve_state[i] = .RESOLVED
		}
	}
}

/*
	Where an entity is in the world, as of the last `update_level`.

	Position is exact. Rotation and scale are exact unless a parent is
	stretched unevenly above a turned child: that makes a skew, which
	`transform_from_matrix` cannot describe and approximates. `get_world_matrix`
	is always exact.
*/
get_world_transform :: proc(level: ^Level, handle: Entity_Handle) -> (transform: mb.Transform, ok: bool) {
	entity := get_entity(level, handle)
	if entity == nil do return {}, false
	return mb.transform_from_matrix(entity.world), true
}

// The entity's world matrix as of the last `update_level`.
get_world_matrix :: proc(level: ^Level, handle: Entity_Handle) -> (world: matrix[4, 4]f32, ok: bool) {
	entity := get_entity(level, handle)
	if entity == nil do return {}, false
	return entity.world, true
}

/*
	Places an entity in the world, whatever its parent: the parent's world
	matrix is undone, and what is left is saved as the entity's own transform.

	The entity's own world matrix is updated at once, so reading it straight
	back gives what was asked. **Its children's are not** until the next
	`update_level` -- a gizmo drag sets, updates, then draws. The parent's world
	matrix is the one from the last `update_level` too.

	Returns false and changes nothing when the entity is gone, or when its
	parent is scaled to zero on some axis: that parent's matrix has no
	inverse, and there is no transform that would put a child anywhere else.
	Under a parent stretched unevenly above a turn, what is saved is the
	nearest placement without skew.
*/
set_world_transform :: proc(level: ^Level, handle: Entity_Handle, transform: mb.Transform) -> bool {
	entity := get_entity(level, handle)
	if entity == nil do return false

	parent_world: matrix[4, 4]f32 = 1
	if parent := entity_by_id(level, entity.parent); parent != nil && parent != entity {
		parent_world = parent.world
	}

	if abs(linalg.determinant(parent_world)) < 1e-12 do return false

	local := linalg.matrix4_inverse(parent_world) * mb.transform_matrix(transform)

	entity.transform = level_transform_from_transform(mb.transform_from_matrix(local))
	entity.world     = parent_world * mb.transform_matrix(transform_from_level_transform(entity.transform))
	return true
}

// A saved transform as the `mb.Transform` drawing wants. The rotation is
// stored x y z w, real part last.
transform_from_level_transform :: proc(t: Level_Transform) -> mb.Transform {
	return mb.Transform{
		position = t.position,
		rotation = quaternion(x = t.rotation.x, y = t.rotation.y, z = t.rotation.z, w = t.rotation.w),
		scale    = t.scale,
	}
}

// An `mb.Transform` in the shape a level saves, since JSON cannot hold a
// quaternion.
level_transform_from_transform :: proc(t: mb.Transform) -> Level_Transform {
	return Level_Transform{
		position = t.position,
		rotation = {t.rotation.x, t.rotation.y, t.rotation.z, t.rotation.w},
		scale    = t.scale,
	}
}

/*Gets the transform information of an entity in a provided level, by the entity name or path (`find_entity_path`)*/
get_level_entity_transform :: proc(level_instance: ^Level, name:string) -> [3]f32 {
	entity := find_entity_path(level_instance, name) or_else Entity_Handle{}
	if t, ok := get_world_transform(level_instance, entity); ok do return t.position
	return {0, 0, 0}
}

@(private)
Resolve_State :: enum u8 {
	UNRESOLVED,
	ON_THIS_WALK,
	RESOLVED,
}

@(private)
entity_by_id :: proc(level: ^Level, id: u64) -> ^Entity {
	if id == 0 do return nil

	if index, found := level.runtime.index_of[id]; found && index < len(level.entities) && level.entities[index].id == id {
		return &level.entities[index]
	}

	for &entity in level.entities {
		if entity.id == id do return &entity
	}
	return nil
}

// The allocator the level was made with. A level read from a file with no
// entities in it has an entity list that never allocated, and so no
// allocator of its own to report.
@(private)
level_allocator :: proc(level: ^Level) -> runtime.Allocator {
	if level.entities.allocator.procedure != nil do return level.entities.allocator
	return context.allocator
}
