package level

/*
	Shapes
	------
	A box or a sphere on an entity: a spawn point, an area that triggers
	something, the zone a fixed camera shot is framed in. Stargate's
	`level_editor_plan.md` section 5.15 is the design.

	**A shape is its entity's transform plus a size**, in half-extents, rather
	than a pair of corners. Moving, turning and scaling it is then the same job
	as moving anything else, and nothing has to keep two corners in step with
	each other. A game wants corners, and `shape_bounds` gives them.

	**The level package stores and answers; it does not draw.** The editor draws
	shapes, and a game that wants to see its own triggers has
	`mb.draw_bounds_wires` for exactly the pair `shape_bounds` returns.
*/

import "core:math/linalg"

Shape_Kind :: enum {
	POINT,  // no size: the marker an entity with no components already is
	BOX,    // `size` is the half-extent on each axis
	SPHERE, // `size.x` is the radius
}

Shape_Component :: struct {
	kind:  Shape_Kind,
	size:  [3]f32,
	color: [4]f32, // what the editor draws it in
}

Shape_Defaults :: struct {
	size:  f32,
	color: [4]f32,
}

// Half a metre, and a green that is not a light's white or a selection's
// yellow. What a shape with nothing filled in gets on load.
SHAPE_DEFAULTS :: Shape_Defaults{size = 0.5, color = {0.35, 0.85, 0.55, 1}}

/*
	The world-space corners of the box a shape takes up: the pair
	`mb.Camera_Shot` reads as `zone_min` and `zone_max`, and the pair
	`mb.draw_bounds_wires` draws.

		shot: mb.Camera_Shot
		shot.zone_min, shot.zone_max, _ = level.get_level_shape_bounds(&yard, "hall")

	A turned box answers with the upright box around it, since that is what a
	pair of corners can say; `shape_contains` is the exact test. Needs
	`update_level` to have run, like everything that reads a world placement.
*/
shape_bounds :: proc(level: ^Level, handle: Entity_Handle) -> (low, high: [3]f32, ok: bool) {
	entity := get_entity(level, handle)
	if entity == nil do return {}, {}, false

	shape, has_shape := entity.shape.?
	if !has_shape do return {}, {}, false

	centre := shape_position(entity.world)

	switch shape.kind {
	case .POINT:
		return centre, centre, true

	case .SPHERE:
		radius := shape.size.x * largest_scale(entity.world)
		return centre - radius, centre + radius, true

	case .BOX:
		// Every corner of the box through the world matrix, and the upright
		// box around those eight points.
		for corner in 0 ..< 8 {
			local := [4]f32{
				shape.size.x if corner & 1 == 0 else -shape.size.x,
				shape.size.y if corner & 2 == 0 else -shape.size.y,
				shape.size.z if corner & 4 == 0 else -shape.size.z,
				1,
			}
			point := (entity.world * local).xyz

			if corner == 0 {
				low, high = point, point
				continue
			}
			low  = {min(low.x, point.x), min(low.y, point.y), min(low.z, point.z)}
			high = {max(high.x, point.x), max(high.y, point.y), max(high.z, point.z)}
		}
		return low, high, true
	}
	return {}, {}, false
}

// The same, for the entity with this name -- what a game reads while it is
// setting up, beside `get_level_entity_transform`.
get_level_shape_bounds :: proc(level: ^Level, name: string) -> (low, high: [3]f32, ok: bool) {
	handle := find_entity(level, name) or_else Entity_Handle{}
	return shape_bounds(level, handle)
}

/*
	Whether a point in the world is inside the shape -- what a trigger asks.

	A box is tested in its own space, so a turned box is exact rather than the
	upright box around it. A point shape contains nothing: it has no inside.
*/
shape_contains :: proc(level: ^Level, handle: Entity_Handle, point: [3]f32) -> bool {
	entity := get_entity(level, handle)
	if entity == nil do return false

	shape, has_shape := entity.shape.?
	if !has_shape do return false

	switch shape.kind {
	case .POINT:
		return false

	case .SPHERE:
		radius := shape.size.x * largest_scale(entity.world)
		return linalg.length(point - shape_position(entity.world)) <= radius

	case .BOX:
		if abs(linalg.determinant(entity.world)) < 1e-12 do return false

		local := (linalg.matrix4_inverse(entity.world) * [4]f32{point.x, point.y, point.z, 1}).xyz
		return abs(local.x) <= shape.size.x && abs(local.y) <= shape.size.y && abs(local.z) <= shape.size.z
	}
	return false
}

// Where a world matrix puts its origin.
@(private)
shape_position :: proc(world: matrix[4, 4]f32) -> [3]f32 {
	return {world[0, 3], world[1, 3], world[2, 3]}
}

// The largest a world matrix stretches any axis: what a sphere grows by under
// a scaled parent, since a sphere has one radius and no way to be an ellipse.
@(private)
largest_scale :: proc(world: matrix[4, 4]f32) -> f32 {
	x := linalg.length([3]f32{world[0, 0], world[1, 0], world[2, 0]})
	y := linalg.length([3]f32{world[0, 1], world[1, 1], world[2, 1]})
	z := linalg.length([3]f32{world[0, 2], world[1, 2], world[2, 2]})
	return max(x, y, z)
}

// What a shape is drawn in: its own colour, or the default when it has none.
shape_color :: proc(shape: Shape_Component) -> [4]f32 {
	return shape.color if shape.color != {} else SHAPE_DEFAULTS.color
}
