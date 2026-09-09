package model_example

/*
	Loading a model from a file, which is stage 4.

	The parsing is `matchbox/gltf2`, a vendored package -- Matchbox does not
	write a glTF importer, it reads accessors out of one. What `load_model` adds
	is the part after parsing: flattening the node hierarchy, pulling vertices
	out of buffer views, decoding the embedded textures, and putting all of it
	on the GPU.

	Things to look at:

	  - **the campfire is the right way up and in one piece.** Its mesh sits
	    under a node rotated ninety degrees, inside another node that moves it,
	    and the stove is nine meshes across a tree of them. `load_model` walks
	    that tree and bakes each node's transform into its vertices, so what
	    comes back needs no arranging. Skip that step and a model arrives as a
	    heap of parts at the origin, each facing its own way
	  - **the textures are sharp, not smoothed.** Every one of these files asks
	    for `magFilter` 9728, which is NEAREST, because they are pixel art. The
	    loader honours it by using the same sampler sprites use
	  - **press B** for each model's bounds. Those come off the vertices at load
	    -- it is what you would measure a `b3.MakeBoxHull` from, and the only
	    thing resembling a collision feature that Matchbox has (D7)
	  - **press T** to tint everything red. The tint multiplies the texture
	    rather than replacing it, the same way it does for a sprite

	Models are the ones from PsxGame, which is the game stages 4 to 6 are for.
*/

import "core:fmt"
import "core:math"

import mb "../../matchbox"

ASSETS :: "../../../games/PsxGame/assets/models/"

Prop :: struct {
	path:     string,
	position: [3]f32,
	scale:    f32,
	model:    mb.Model,
	loaded:   bool,
}

main :: proc() {
	mb.init("Model", 1280, 720)
	defer mb.cleanup()

	/*
		The sun this example is lit by. It used not to need saying: a scene that set
		no lights got a hard-coded direction inside the shader, and that implicit
		fallback is gone -- see `lighting_rework.md` section 1 for why an
		emergent "lighting is on" was worth removing. Stating it is the
		replacement, and it is two lines.

		The direction is the way the light travels, so a sun overhead points
		down. Ambient is divided by ten inside `brdf/blinn_phong.hlsli` -- 3.5
		here is 0.35 reaching the surface -- which is what keeps the faces
		turned away from the sun off pure black.
	*/
	mb.set_lighting({enabled = true, ambient = {color = {3.5, 3.5, 3.5, 1}}, exposure = 1})
	mb.set_lights({mb.create_directional_light({0.4, -1, -0.7}, {0.65, 0.65, 0.65, 1})})

	mb.set_escape_key(.UNKNOWN)

	SCALE :: 3.0

	props := []Prop{
		{path = ASSETS + "campfireV1.gltf", position = { 0, 0, 0}, scale = SCALE},
		{path = ASSETS + "cube.gltf",       position = { 4, 0, 0}, scale = SCALE},
		{path = ASSETS + "pot.gltf",        position = {-4, 0, 0}, scale = SCALE},
		{path = ASSETS + "stove.gltf",      position = {-9, 0, 0}, scale = SCALE},
	}

	for &prop in props {
		model, err := mb.load_model(prop.path)
		if err != nil {
			fmt.eprintfln("could not load %s: %v", prop.path, err)
			continue
		}
		prop.model, prop.loaded = model, true

		// Sat on the ground using the model's own bounds rather than by hand.
		// These files are authored around all sorts of origins -- the pot's is
		// in the middle of it, the campfire's is at its feet -- so without this
		// half of them float and the other half sink.
		prop.position.y = -prop.model.bounds_min.y * prop.scale

		size := mb.model_size(prop.model)
		fmt.printfln("%s: %v parts, %.3f x %.3f x %.3f",
			prop.path, len(prop.model.parts), size.x, size.y, size.z)
	}

	defer for &prop in props {
		if prop.loaded do mb.destroy(&prop.model)
	}

	// Well back and high up, looking down the line of props.
	player := [3]f32{-2, 0, 18}

	rig := mb.create_first_person_camera(
		position   = player,
		facing     = -math.PI * 0.5,
		pitch      = math.atan2(f32(-3.5), f32(18.0)),
		eye_offset = {0, 5, 0},
	)

	show_bounds := false
	tinted      := false

	mb.set_cursor_locked(true)

	for mb.is_running() {
		mb.poll_events()

		if mb.is_key_pressed(.ESCAPE) {
			if mb.is_cursor_locked() do mb.set_cursor_locked(false)
			else                 do mb.mbi.running = false
		}
		if !mb.is_cursor_locked() && mb.is_mouse_pressed(.LEFT) do mb.set_cursor_locked(true)

		if mb.is_key_pressed(.B) do show_bounds = !show_bounds
		if mb.is_key_pressed(.T) do tinted      = !tinted

		if mb.is_cursor_locked() {
			mb.first_person_walk(&rig, &player, 5, mb.get_delta_time())
		}

		tint := mb.RED if tinted else mb.WHITE

		mb.begin_drawing()
		mb.clear_background({0.10, 0.11, 0.16, 1})

		mb.begin_drawing_3d(rig.camera)

		mb.draw_plane({0, 0, 0}, {40, 40}, {0.22, 0.24, 0.26, 1})
		mb.draw_grid(40, 1, {1, 1, 1, 0.15})

		for prop in props {
			if !prop.loaded do continue

			mb.draw_model_at(prop.model, prop.position, prop.scale, tint)

			if show_bounds {
				// The model's own extents, scaled and moved the same way the
				// model was. Not a collision test -- a measurement.
				mb.draw_bounds_wires(
					prop.position + prop.model.bounds_min * prop.scale,
					prop.position + prop.model.bounds_max * prop.scale,
					mb.LIME_GREEN)
			}
		}

		mb.end_drawing_3d()

		font := &mb.mbi.font
		mb.draw_text(font, "gltf models, node transforms baked, textures embedded", 20, 40, mb.WHITE)
		mb.draw_text(font, "B bounds, T tint, WASD walk, ESC pointer", 20, 70, mb.WHITE)

		y: f32 = 110
		for prop in props {
			line := fmt.tprintf("%s  %v parts",
				prop.path[len(ASSETS):], len(prop.model.parts)) if prop.loaded \
				else fmt.tprintf("%s  FAILED", prop.path[len(ASSETS):])

			mb.draw_text(font, line, 20, y, mb.WHITE if prop.loaded else mb.RED)
			y += 26
		}

		cx := f32(mb.mbi.width) * 0.5
		cy := f32(mb.mbi.height) * 0.5
		mb.draw_rect({position = {cx, cy}, size = {12, 2}, color = mb.WHITE})
		mb.draw_rect({position = {cx, cy}, size = {2, 12}, color = mb.WHITE})

		mb.end_drawing()
	}

	mb.wait_idle()
}
