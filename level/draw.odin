package level

/*
	Drawing a level, and its lights
	-------------------------------
	A level keeps nothing on the GPU of its own. Every frame it makes the calls
	a hand-written game would -- `render_model`, and the list for `set_lights` --
	from its entities' world matrices, so call `update_level` first.
*/

import "core:math/linalg"

import mb "../matchbox"

// What a model that could not be loaded is drawn as instead: a box this
// colour where it would have been, so a missing file is a visible gap.
MISSING_MODEL_COLOR :: [4]f32{1, 0.25, 0.25, 1}

/*
	The `mb.Light` an entity's light component makes, placed and aimed by the
	entity's world matrix: its position, its -Z as the direction the light
	points, and for an area light its +X as the width. Scale is ignored -- a
	light under a scaled parent is not brighter or larger for it (plan 5.11).

	`intensity` multiplies the colour's red, green and blue; alpha is kept.
*/
get_entity_light :: proc(entity: Entity) -> (light: mb.Light, ok: bool) {
	component := entity.light.? or_return

	world   := transform_from_matrix(entity.world)
	forward := linalg.normalize(linalg.quaternion128_mul_vector3(world.rotation, [3]f32{0, 0, -1}))

	i := component.intensity
	color := [4]f32{component.color.r * i, component.color.g * i, component.color.b * i, component.color.a}

	switch component.kind {
	case .DIRECTIONAL:
		light = mb.create_directional_light(forward, color)
	case .POINT:
		light = mb.create_point_light(world.position, color)
	case .SPOT:
		light = mb.create_spot_light(world.position, forward, color, component.inner_angle, component.outer_angle)
	case .AREA_RECT, .AREA_DISK:
		// Matchbox has no area lights: a point light at the same place is the nearest it can do, and a bright
		// one where an area light was meant to spread. Shadows are not cast either, so `casts_shadow` is not read
		light = mb.create_point_light(world.position, color)
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
get_level_lights :: proc(level: ^Level, allocator := context.allocator) -> [dynamic]mb.Light {
	lights := make([dynamic]mb.Light, 0, 8, allocator)
	for entity in level.entities {
		if light, ok := get_entity_light(entity); ok do append(&lights, light)
	}
	return lights
}

/*
	Draws every model, and a `MISSING_MODEL_COLOR` box for every model component whose file could not be loaded. Call it
	inside `camera_start`, after `update_level`.

	**`casts_shadow` is read from the file and ignored**: Matchbox has no shadow maps yet, so a caster is drawn like any other
	model. The old `draw_level_shadow_casters` is gone with them.

	The missing-model box is a solid cube and not the wire box `main` drew: no wire draw exists here (see `docs/the_game_port_plan.md`)
*/
render_level :: proc(level: ^Level) {
	for entity in level.entities {
		component, has_model := entity.model.?
		if !has_model do continue

		transform := transform_from_matrix(entity.world)

		if component.model == nil {
			if level.runtime.missing_box.parts == nil do level.runtime.missing_box = mb.create_cube_model(1)
			mb.render_model(level.runtime.missing_box, transform, MISSING_MODEL_COLOR)
			continue
		}

		mb.render_model(component.model^, transform, component.tint)
	}
}
