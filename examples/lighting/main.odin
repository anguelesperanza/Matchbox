package lighting_example

/*
	A campfire in the dark, which is stage 5 and is PsxGame's opening scene.

	The lighting model is that game's, ported constant for constant -- the same
	attenuation curve, the same specular exponent, the same ambient divided by
	ten, gamma applied before the fog so the fog colour is the colour you asked
	for. Its `campfire_light` flicker is reproduced here line for line, because
	the flicker is the thing that makes a fire look like a fire rather than an
	orange lamp.

	Things to try:

	  - **walk backwards.** The fog is dark blue from 3 units to 12, so the
	    world does not end at a black wall, it fades. Turn it off with F and
	    watch how much worse an unlit scene reads without it
	  - **press L.** That clears the lights, which is not the same as having
	    lights that are off: with none set at all, Matchbox falls back to the
	    fixed shading every 3D draw used before stage 5, so the scene goes
	    flat-lit rather than black. Every example written before this one is
	    still running down that path
	  - **watch the shadows on the stove.** They move, because the light does.
	    The flicker offsets the position by a few centimetres on two different
	    sine waves and the specular highlight follows it
	  - **press K** for a second, cold, directional light -- a moon. Four are
	    allowed; both games use one

	Models are PsxGame's own, loaded by stage 4.
*/

import "core:fmt"
import "core:math"

import mb "../../matchbox"

ASSETS :: "../../../games/PsxGame/assets/models/"

// PsxGame's deep amber red, and its fog.
EMBER     :: [4]f32{1.0, 0.2, 0.0, 1}
FOG_COLOR :: [4]f32{0.04, 0.04, 0.18, 1}
FOG_START :: f32(3)
FOG_END   :: f32(12)

Prop :: struct {
	path:     string,
	position: [3]f32,
	scale:    f32,
	model:    mb.Model,
	loaded:   bool,
}

main :: proc() {
	mb.init("Lighting", 1280, 720)
	defer mb.cleanup()

	mb.set_escape_key(.UNKNOWN)

	props := []Prop{
		{path = ASSETS + "campfireV1.gltf", position = { 0, 0,  0}, scale = 3},
		{path = ASSETS + "stove.gltf",      position = {-4, 0, -3}, scale = 3},
		{path = ASSETS + "pot.gltf",        position = { 3, 0, -2}, scale = 3},
		{path = ASSETS + "cube.gltf",       position = { 2, 0,  3}, scale = 3},
	}

	for &prop in props {
		model, err := mb.load_model(prop.path)
		if err != nil {
			fmt.eprintfln("could not load %s: %v", prop.path, err)
			continue
		}

		prop.model, prop.loaded = model, true
		prop.position.y = -prop.model.bounds_min.y * prop.scale
	}

	defer for &prop in props {
		if prop.loaded do mb.destroy(&prop.model)
	}

	// Standing five back with the eye 1.8 up, looking down at the campfire --
	// the same opening view this had before the rig existed.
	player := [3]f32{0, 0, 5}

	rig := mb.create_first_person_camera(
		position   = player,
		facing     = -math.PI * 0.5,
		pitch      = math.atan2(f32(-1.0), f32(5.0)),
		eye_offset = {0, 1.8, 0},
	)

	lights_on := true
	fog_on    := true
	moon_on   := false

	mb.set_ambient({0.35, 0.35, 0.55, 1})
	mb.set_fog(FOG_COLOR, FOG_START, FOG_END)

	mb.set_cursor_locked(true)

	for mb.is_running() {
		mb.poll_events()
		time := f32(mb.get_time())

		if mb.is_key_pressed(.ESCAPE) {
			if mb.is_cursor_locked() do mb.set_cursor_locked(false)
			else                 do mb.mbi.running = false
		}
		if !mb.is_cursor_locked() && mb.is_mouse_pressed(.LEFT) do mb.set_cursor_locked(true)

		if mb.is_key_pressed(.L) do lights_on = !lights_on
		if mb.is_key_pressed(.K) do moon_on   = !moon_on

		if mb.is_key_pressed(.F) {
			fog_on = !fog_on
			if fog_on do mb.set_fog(FOG_COLOR, FOG_START, FOG_END)
			else      do mb.disable_fog()
		}

		if mb.is_cursor_locked() {
			mb.first_person_walk(&rig, &player, 4, mb.get_delta_time())
		}

		if lights_on {
			// PsxGame's flicker, unchanged. Two sines that do not divide into
			// each other, so the fire never repeats on a beat you can hear.
			flicker := 1.0 + math.sin(time * 1.0) * 0.1 + math.sin(time * 0.5) * 0.05

			fire := mb.create_point_light(
				{math.sin(time * 8.0) * 0.05, 1.0, math.cos(time * 6.0) * 0.05},
				{
					clamp(EMBER.r * flicker, 0, 1),
					clamp(EMBER.g * flicker, 0, 0.31), // green capped much lower,
					0,                                 // or it drifts to yellow
					1,
				})

			if moon_on {
				moon := mb.create_directional_light({-0.4, -1, -0.3}, {0.18, 0.20, 0.40, 1})
				mb.set_lights({fire, moon})
			} else {
				mb.set_lights({fire})
			}
		} else {
			// Not four disabled lights -- none at all, which is what puts the
			// fallback shading back.
			mb.clear_lights()
		}

		mb.begin_drawing()
		mb.clear_background(FOG_COLOR if fog_on else {0.02, 0.02, 0.05, 1})

		mb.begin_drawing_3d(rig.camera)

		mb.draw_plane({0, 0, 0}, {60, 60}, {0.30, 0.26, 0.22, 1})

		for prop in props {
			if prop.loaded do mb.draw_model_at(prop.model, prop.position, prop.scale)
		}

		// Something to catch the light further out, so the fog has a gradient
		// to work across rather than a single object and then nothing.
		for i in 0 ..< 9 {
			angle := f32(i) * math.TAU / 9
			radius := 7 + f32(i % 3) * 2.5
			mb.draw_cube(
				{math.cos(angle) * radius, 0.6, math.sin(angle) * radius},
				{1.2, 1.2, 1.2},
				{0.55, 0.5, 0.45, 1})
		}

		mb.end_drawing_3d()

		font := &mb.mbi.font
		mb.draw_text(font, "L lights, K moon, F fog, WASD walk, ESC pointer", 20, 40, mb.WHITE)
		mb.draw_text(font, fmt.tprintf("lights %v   moon %v   fog %v",
			"on" if lights_on else "off (fallback shading)",
			"on" if moon_on else "off",
			"on" if fog_on else "off"), 20, 70, mb.WHITE)

		cx := f32(mb.mbi.width) * 0.5
		cy := f32(mb.mbi.height) * 0.5
		mb.draw_rect({position = {cx, cy}, size = {12, 2}, color = mb.WHITE})
		mb.draw_rect({position = {cx, cy}, size = {2, 12}, color = mb.WHITE})

		mb.end_drawing()
	}

	mb.wait_idle()
}
