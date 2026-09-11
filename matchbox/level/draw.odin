package level

/*
	Drawing a level, and its lights
	-------------------------------
	A level keeps nothing on the GPU of its own. Every frame it makes the calls
	a hand-written game would -- `draw_model`, and the list for `set_lights` --
	from its entities' world matrices, so call `update_level` first.
*/

import "core:math/linalg"

import mb ".."

// What a model that could not be loaded is drawn as instead: a wire box this
// colour where it would have been, so a missing file is a visible gap.
MISSING_MODEL_COLOR :: [4]f32{1, 0.25, 0.25, 1}

/*
	The `mb.Light` an entity's light component makes, placed and aimed by the
	entity's world matrix: its position, its -Z as the direction the light
	points, and for an area light its +X as the width. Scale is ignored -- a
	light under a scaled parent is not brighter or larger for it (plan 5.11).

	`intensity` multiplies the colour's red, green and blue; alpha is kept.
*/
light_from_entity :: proc(entity: Entity) -> (light: mb.Light, ok: bool) {
	component := entity.light.? or_return

	world   := mb.transform_from_matrix(entity.world)
	forward := linalg.normalize(linalg.quaternion_mul_vector3(world.rotation, [3]f32{0, 0, -1}))
	right   := linalg.normalize(linalg.quaternion_mul_vector3(world.rotation, [3]f32{1, 0, 0}))

	i := component.intensity
	color := [4]f32{component.color.r * i, component.color.g * i, component.color.b * i, component.color.a}

	switch component.kind {
	case .DIRECTIONAL:
		light = mb.create_directional_light(forward, color, component.casts_shadow)
	case .POINT:
		light = mb.create_point_light(world.position, color, component.casts_shadow)
	case .SPOT:
		light = mb.create_spot_light(world.position, forward, color, component.inner_angle, component.outer_angle, component.casts_shadow)
	case .AREA_RECT:
		// The component keeps half-extents, as mb.Light does; the constructor
		// takes the whole width and height.
		light = mb.create_area_rect_light(world.position, forward, right, component.area_size.x * 2, component.area_size.y * 2, color)
	case .AREA_DISK:
		light = mb.create_area_disk_light(world.position, forward, component.area_size.x, color)
	}

	return light, true
}

/*
	Every light in the level, in list order, ready for `mb.set_lights`.

	Handed back rather than set, because `set_lights` replaces the whole list:
	a level that set it would erase the game's own lights, or the game's call
	would erase the level's. Append the game's lights to this and make the one
	call.
*/
level_lights :: proc(level: ^Level, allocator := context.allocator) -> [dynamic]mb.Light {
	lights := make([dynamic]mb.Light, 0, 8, allocator)
	for entity in level.entities {
		if light, ok := light_from_entity(entity); ok do append(&lights, light)
	}
	return lights
}

/*
	Submits every loaded model marked `casts_shadow`. Call it **before**
	`begin_drawing_3d`, and `draw_level` inside the pass.

	Matchbox holds a model submitted this way and draws it twice itself --
	into each shadow map that wants it, then into the scene -- so `draw_level`
	leaves casters out. Drawing a caster in both would draw it into the scene
	twice.
*/
draw_level_shadow_casters :: proc(level: ^Level) {
	for entity in level.entities {
		component, has_model := entity.model.?
		if !has_model || !component.casts_shadow || component.model == nil do continue

		mb.draw_model(component.model^, mb.transform_from_matrix(entity.world), component.tint, nil, casts_shadow = true)
	}
}

/*
	Draws every model that does not cast a shadow, and a `MISSING_MODEL_COLOR`
	wire box for every model component whose file could not be loaded. Call it
	inside `begin_drawing_3d`, after `draw_level_shadow_casters` has run
	before the pass.

	A missing model is drawn here even when it was marked to cast a shadow: a
	wire box casts none, and it has to be drawn inside a pass.
*/
draw_level :: proc(level: ^Level) {
	for entity in level.entities {
		component, has_model := entity.model.?
		if !has_model do continue

		transform := mb.transform_from_matrix(entity.world)

		if component.model == nil {
			mb.draw_cube_wires(transform.position, transform.scale, MISSING_MODEL_COLOR, transform.rotation)
			continue
		}

		if component.casts_shadow do continue
		mb.draw_model(component.model^, transform, component.tint)
	}
}
