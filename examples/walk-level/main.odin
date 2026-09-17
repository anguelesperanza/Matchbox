package walk_level_example

/*
	A level from a file, walked around.

	Everything in the yard except the player is `levels/yard.json`: the
	ground, the crates, a wall, a turntable with a lamp post on it, a campfire,
	the moon, and where the player starts. This file loads it, turns the
	turntable, and draws. The frame is the four calls a game makes with any
	level:

		level.update_level(&yard)                        where everything is
		level.level_lights(&yard, ...) -> mb.set_lights  the level's lights, plus any of the game's
		level.draw_level_shadow_casters(&yard)           before the 3D pass
		level.draw_level(&yard)                          inside it

	The only model is `assets/cube.gltf`, a white unit cube written by
	`assets/make_cube.py`, placed, scaled and tinted per entity.

	Things to try:

	  - watch the turntable. Only the turntable is turned. The disc, the post,
	    the lamp head and the spot light are its children in the file, and
	    follow because the level works out each entity's place from its parent
	    every frame -- the lamp's light and its shadow go round with it
	  - the small crate is a child of the big one: move the big crate in the
	    file and both move
	  - press R to reload the file. Edit yard.json in a text editor while this
	    runs -- move a crate, change the fire's colour -- and press R
	  - press F5 to save to levels/yard_saved.json, then compare it with
	    yard.json. The only difference is the turntable's rotation, which has
	    moved on since it loaded
	  - change a model path in the file to one that is not there and press R:
	    that entity is a red wire box, and the log says which file was missing
	  - change a light's "kind" to "LASER", or a parent to an id that is not in
	    the file, and press R: the log says what was repaired, and the rest of
	    the level loads anyway
*/

import "core:fmt"
import "core:log"
import "core:math"

import mb    "../../matchbox"
import level "../../matchbox/level"

LEVEL_PATH :: "levels/yard.json"
SAVE_PATH  :: "levels/yard_saved.json"

// The one entity this example moves, and the rotation it loaded with. Turned
// from that rotation every frame rather than a little more each frame, so an
// hour of turning does not pile up rounding error.
Turntable :: struct {
	handle: level.Entity_Handle,
	start:  quaternion128,
}

main :: proc() {
	mb.init("Walk a level", 1280, 720)
	defer mb.cleanup()

	context.logger = mb.mbi.logger
	mb.set_escape_key(.UNKNOWN)

	yard, err := level.load_level(LEVEL_PATH)
	if err != nil {
		log.errorf("could not load %s: %v", LEVEL_PATH, err)
		return
	}
	defer level.destroy_level(&yard)

	mb.set_lighting(yard.settings.lighting)

	player := spawn_position(&yard)
	rig := mb.create_first_person_camera(position = player, facing = -math.PI * 0.5, eye_offset = {0, 1.7, 0})
	mb.set_cursor_locked(true)

	turntable := find_turntable(&yard)
	spin: f32

	status_buffer: [256]u8
	status := fmt.bprintf(status_buffer[:], "loaded %s", LEVEL_PATH)

	for mb.is_running() {
		mb.poll_events()
		dt := mb.get_delta_time()

		if mb.is_key_pressed(.ESCAPE) {
			if mb.is_cursor_locked() do mb.set_cursor_locked(false)
			else                     do mb.mbi.running = false
		}
		if !mb.is_cursor_locked() && mb.is_mouse_pressed(.LEFT) do mb.set_cursor_locked(true)

		if mb.is_key_pressed(.R) {
			// Loaded beside the old level and swapped in only once it has
			// loaded, so a file broken mid-edit leaves the yard as it was.
			if reloaded, reload_err := level.load_level(LEVEL_PATH); reload_err == nil {
				level.destroy_level(&yard)
				yard = reloaded
				mb.set_lighting(yard.settings.lighting)
				turntable = find_turntable(&yard)
				status = fmt.bprintf(status_buffer[:], "reloaded %s", LEVEL_PATH)
			} else {
				status = fmt.bprintf(status_buffer[:], "could not reload %s (%v); kept the old one", LEVEL_PATH, reload_err)
			}
		}

		if mb.is_key_pressed(.F5) {
			if save_err := level.save_level(yard, SAVE_PATH); save_err == nil {
				status = fmt.bprintf(status_buffer[:], "saved %s", SAVE_PATH)
			} else {
				status = fmt.bprintf(status_buffer[:], "could not save %s (%v)", SAVE_PATH, save_err)
			}
		}

		if mb.is_cursor_locked() do mb.first_person_walk(&rig, &player, 4, dt)

		spin += dt * 0.5
		if entity := level.get_entity(&yard, turntable.handle); entity != nil {
			t := level.transform_from_level_transform(entity.transform)
			t.rotation = mb.transform_rotation({0, 1, 0}, spin) * turntable.start
			entity.transform = level.level_transform_from_transform(t)
		}

		level.update_level(&yard)

		lights := level.level_lights(&yard, context.temp_allocator)
		mb.set_lights(lights[:])

		mb.begin_drawing()
		mb.clear_background(yard.settings.background)

		level.draw_level_shadow_casters(&yard)

		mb.begin_drawing_3d(rig.camera)
		level.draw_level(&yard)
		mb.end_drawing_3d()

		font := &mb.mbi.font
		mb.draw_text(font, "WASD walk, mouse look, R reload yard.json, F5 save a copy, ESC pointer", 20, 40, mb.WHITE)
		mb.draw_text(font, fmt.tprintf("%d entities, %d lights, %d models missing",
			len(yard.entities), len(lights), count_missing_models(&yard)), 20, 72, mb.WHITE)
		mb.draw_text(font, status, 20, 104, mb.WHITE)

		mb.end_drawing()
		free_all(context.temp_allocator)
	}

	mb.wait_idle()
}

// The marker entity called "player_spawn", or the origin when the file has
// none. Its world position, so a spawn point parented to something still
// works.
spawn_position :: proc(yard: ^level.Level) -> [3]f32 {
	spawn := level.find_entity(yard, "player_spawn") or_else level.Entity_Handle{}
	if t, ok := level.get_world_transform(yard, spawn); ok do return t.position
	return {0, 0, 0}
}

find_turntable :: proc(yard: ^level.Level) -> (turntable: Turntable) {
	turntable.handle = level.find_entity(yard, "turntable") or_else level.Entity_Handle{}
	turntable.start  = 1

	if entity := level.get_entity(yard, turntable.handle); entity != nil {
		turntable.start = level.transform_from_level_transform(entity.transform).rotation
	}
	return
}

count_missing_models :: proc(yard: ^level.Level) -> (missing: int) {
	for entity in yard.entities {
		if model, ok := entity.model.?; ok && model.model == nil do missing += 1
	}
	return
}
