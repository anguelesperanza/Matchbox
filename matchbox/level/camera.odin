package level

/*
	Cameras
	-------
	A camera on an entity: where a shot is taken from, and what it can see.
	Stargate's `level_editor_plan.md` section 5.20 is the design.

	**A camera is its entity's transform plus a lens**, the way a light is
	(draw.odin). Where it stands and which way it looks come from the entity's
	world matrix, so the move and rotate gizmos aim a camera exactly as they
	aim anything else, and there is no second direction to keep in step with
	the first. What the component holds is only what a transform cannot say:
	the field of view and the two clip planes.

	**Looking down -Z, with the entity's own up.** That is the convention
	everything else in Matchbox uses (math3d.odin:203), so an entity with no
	rotation looks the way an unrotated anything looks. The up is taken from
	the entity rather than fixed at +Y, so that rolling the entity rolls the
	shot -- a camera that could not be rolled would be a rotate gizmo with one
	axis that silently does nothing.

	**Scale is ignored**, as it is for a light. A camera twice as large is not
	a camera with a different lens, and a shot that changed its framing because
	somebody scaled a parent would be a surprise with no use.

	**The level package answers; it does not draw.** `camera_from_entity` hands
	back an `mb.Camera3D` ready for `begin_drawing_3d`; the editor draws the
	frustum, and a game does what it likes with the camera.
*/

import "core:math/linalg"

import mb ".."

/*
	What a transform cannot say about a camera.

	Every field may be left at zero: `camera3d_defaults` fills in 70 degrees,
	0.1 and 1000 for exactly the fields left unset (camera3d.odin), so a camera
	component written by hand as `{}` is the same camera `create_camera3d`
	makes. That is why there is no "is this configured" flag -- there is no
	unconfigured state to be in.
*/
Camera_Component :: struct {
	fov:  f32, // vertical, in degrees
	near: f32,
	far:  f32,
}

// What Matchbox fills in for a field left at zero, repeated here so the editor
// can show the number that will actually be used rather than a zero.
CAMERA_DEFAULTS :: Camera_Component{fov = 70, near = 0.1, far = 1000}

/*
	The `mb.Camera3D` an entity's camera component makes, placed and aimed by
	the entity's world matrix.

	Needs `update_level` to have run, like everything that reads a world
	placement. False when the entity has no camera component.

		if camera, ok := level.camera_from_entity(entity); ok {
			mb.begin_drawing_3d(camera)
		}
*/
camera_from_entity :: proc(entity: Entity) -> (camera: mb.Camera3D, ok: bool) {
	component := entity.camera.? or_return

	world   := mb.transform_from_matrix(entity.world)
	forward := linalg.normalize(linalg.quaternion_mul_vector3(world.rotation, [3]f32{0, 0, -1}))
	up      := linalg.normalize(linalg.quaternion_mul_vector3(world.rotation, [3]f32{0, 1, 0}))

	return mb.Camera3D{
		position   = world.position,
		target     = world.position + forward,
		up         = up,
		fov        = component.fov,
		projection = .PERSPECTIVE,
		near       = component.near,
		far        = component.far,
	}, true
}

/*
	The same, for the entity with this name -- what a game reads while it is
	setting up, beside `get_level_entity_transform` and
	`get_level_shape_bounds`.

		camera, ok := level.get_level_camera(&yard, "hall_shot")

	A name with a slash in it is a path through the tree
	(`find_entity_path`), which is how the `camera` inside one group is named
	when every group has one:

		camera, ok := level.get_level_camera(&yard, "fixed_angle_one/camera")
*/
get_level_camera :: proc(level: ^Level, name: string) -> (camera: mb.Camera3D, ok: bool) {
	handle := find_entity_path(level, name) or_else Entity_Handle{}

	entity := get_entity(level, handle)
	if entity == nil do return {}, false

	return camera_from_entity(entity^)
}

/*
	A fixed-angle shot assembled from a group of entities: an empty entity
	holding a camera and the area that camera covers.

	**A shot is two things in two places, and the level is where they are put
	together.** `mb.Camera_Shot` is a placement plus a box of the world, and
	those are two different entities in the editor -- one an empty with a camera
	component on it, the other an empty with a box shape. Both are moved by the
	same gizmo as anything else, and the group they hang off is what says they
	belong to each other. So the editor has no shot tool and needs none, and a
	game reads the shot back in one call:

		shot, ok := level.get_level_camera_shot(&house, "fixed_angle_one")
		if ok do mb.fixed_camera_add_shot(&rig, shot)

	**Which child is which is decided by component, not by name.** The camera is
	the group's own camera component, or the first child that has one. The zone
	is the first child with a shape and no camera -- the camera's child carries a
	shape of its own, because that is the marker the editor draws it as, and
	taking the first shape it found would frame every shot on a half-metre cube.
	Naming the children `camera` and `bounds` is then a convenience for a person
	reading the file rather than something this depends on.

	**False unless both were found.** A shot with no zone contains nothing, so
	`fixed_camera_follow` would never pick it and the camera would simply never
	cut there -- a level-building mistake that shows as nothing at all. A game
	wanting the placement alone has `get_level_camera`.

	`aim` is not in the level file. A shot that tracks is a decision about how
	the game plays rather than about where the camera stands, and the editor has
	nowhere to show the difference -- a tracked shot drawn in the editor is a
	frustum pointed at a character who is not there. Pass `.TRACK` for the
	corridors.

	Needs `update_level` to have run, like everything that reads a world
	placement.
*/
get_level_camera_shot :: proc(
	level: ^Level,
	name:  string,
	aim:   mb.Camera_Shot_Aim = .FIXED,
) -> (shot: mb.Camera_Shot, ok: bool) {
	return camera_shot_from_entity(level, find_entity_path(level, name) or_else Entity_Handle{}, aim)
}

// The same, for a group already found -- what walking `level_children` over a
// `cameras` empty reads, so a level gains a shot without the game being told
// its name.
camera_shot_from_entity :: proc(
	level:  ^Level,
	handle: Entity_Handle,
	aim:    mb.Camera_Shot_Aim = .FIXED,
) -> (shot: mb.Camera_Shot, ok: bool) {
	group := get_entity(level, handle)
	if group == nil do return {}, false

	lens := handle
	if !has_camera(group^) {
		lens = find_child_camera(level, handle) or_return
	}

	entity := get_entity(level, lens)
	if entity == nil do return {}, false

	camera := camera_from_entity(entity^) or_return
	zone   := find_child_zone(level, handle, lens) or_return

	low, high := shape_bounds(level, zone) or_return

	return mb.Camera_Shot{
		position = camera.position,
		target   = camera.target,

		// Filled in rather than left at whatever the component holds, so that a
		// shot reads back the angle it will be rendered at. A zero would be 70
		// by the time it was drawn and 0 to anything that looked.
		fov      = camera_settings(entity.camera.? or_else {}).fov,
		aim      = aim,

		zone_min = low,
		zone_max = high,
	}, true
}

// The first child of `parent` carrying a camera component.
@(private)
find_child_camera :: proc(level: ^Level, parent: Entity_Handle) -> (handle: Entity_Handle, found: bool) {
	owner := get_entity(level, parent)
	if owner == nil do return {}, false

	id := owner.id
	for entity, i in level.entities {
		if entity.parent == id && has_camera(entity) do return {index = i, id = entity.id}, true
	}
	return {}, false
}

// The first child of `parent` that marks out an area rather than the shot: a
// shape, on an entity that is not the camera and has no camera of its own.
@(private)
find_child_zone :: proc(level: ^Level, parent, lens: Entity_Handle) -> (handle: Entity_Handle, found: bool) {
	owner := get_entity(level, parent)
	if owner == nil do return {}, false

	id := owner.id
	for entity, i in level.entities {
		if entity.parent != id || entity.id == lens.id || has_camera(entity) do continue
		if _, has_shape := entity.shape.?; has_shape do return {index = i, id = entity.id}, true
	}
	return {}, false
}

/*
	A camera component with every field it left at zero filled in.

	What the editor shows and what the frustum is drawn from, so that a field
	left unset reads as the 70 degrees it will actually be rendered at rather
	than as a zero that would draw a frustum with no angle.
*/
camera_settings :: proc(component: Camera_Component) -> Camera_Component {
	filled := component

	if filled.fov <= 0           do filled.fov = CAMERA_DEFAULTS.fov
	if filled.near <= 0          do filled.near = CAMERA_DEFAULTS.near
	if filled.far <= filled.near do filled.far = CAMERA_DEFAULTS.far

	return filled
}

// Whether the entity has a camera on it -- for a caller that wants the
// question without the camera.
has_camera :: proc(entity: Entity) -> bool {
	_, ok := entity.camera.?
	return ok
}
