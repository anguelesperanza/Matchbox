package post_example

/*
	The scene rendered into a texture, then drawn back through a filter. Stage 6,
	and the last piece PsxGame needs.

	The shape of a frame here is the shape its main loop already has:

		begin_drawing_target(&scene)
			clear_background(...)
			begin_drawing_3d(camera)
				... the world ...
			end_drawing_3d()
		end_drawing_target()

		draw_post(scene, effect)
		... the HUD, crisp, over the top ...

	The reason for the target is that a filter needs the finished picture: you
	cannot read the pixels under a draw while you are making them. So the scene
	goes into a texture, and one full-screen quad reads that texture and writes
	the window.

	Press 1, 2, 3:

	  - **1 — none.** The target drawn back as it is. Still a full-screen pass,
	    and the honest baseline to judge the other two against
	  - **2 — VHS.** Barrel curve, tape wobble, a tracking band that moves a
	    couple of times a second, chroma smeared sideways, grain, and head noise
	    in the strip at the bottom
	  - **3 — PSX.** Sampled on a coarse grid, dithered with a Bayer matrix, cut
	    to five bits a channel, and scanlined. Press [ and ] to make the grid
	    coarser or finer -- 320x240 is a PlayStation

	**The HUD is drawn after the effect and is not filtered**, which is
	deliberate and is what PsxGame does: the world is a video signal and the
	text on top of it is not. Switch to PSX and read this line -- it stays sharp
	while everything behind it turns to mush.
*/

import "core:fmt"
import "core:math"

import mb "../../matchbox"

ASSETS :: "../../../games/PsxGame/assets/models/"

FOG_COLOR :: [4]f32{0.04, 0.04, 0.18, 1}
EMBER     :: [4]f32{1.0, 0.2, 0.0, 1}

Prop :: struct {
	path:     string,
	position: [3]f32,
	scale:    f32,
	model:    mb.Model,
	loaded:   bool,
}

main :: proc() {
	mb.init("Post Processing", 1280, 720)
	defer mb.cleanup()

	mb.set_escape_key(.UNKNOWN)

	// At the window's size. It does not follow a resize -- see the note on
	// Render_Target -- and for a game with a filter over it a fixed resolution
	// is usually the point anyway.
	scene, scene_err := mb.create_render_target()
	if scene_err != nil do return
	defer mb.destroy(&scene)

	props := []Prop{
		{path = ASSETS + "campfireV1.gltf", position = { 0, 0,  0}, scale = 3},
		{path = ASSETS + "stove.gltf",      position = {-4, 0, -3}, scale = 3},
		{path = ASSETS + "pot.gltf",        position = { 3, 0, -2}, scale = 3},
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

	// The same opening view as examples/lighting, which this scene is.
	player := [3]f32{0, 0, 5}

	rig := mb.create_first_person_camera(
		position   = player,
		facing     = -math.PI * 0.5,
		pitch      = math.atan2(f32(-1.0), f32(5.0)),
		eye_offset = {0, 1.8, 0},
	)

	effect := mb.Post_Effect.PSX
	grid   := [2]f32{320, 240}

	mb.set_lighting({
		enabled  = true,
		ambient  = {color = {0.35, 0.35, 0.55, 1}},
		fog      = {enabled = true, color = FOG_COLOR, start = 3, end = 12},
		exposure = 1,
	})
	mb.set_cursor_locked(true)

	for mb.is_running() {
		mb.poll_events()
		time := f32(mb.get_time())

		if mb.is_key_pressed(.ESCAPE) {
			if mb.is_cursor_locked() do mb.set_cursor_locked(false)
			else                 do mb.mbi.running = false
		}
		if !mb.is_cursor_locked() && mb.is_mouse_pressed(.LEFT) do mb.set_cursor_locked(true)

		if mb.is_key_pressed(._1) do effect = .NONE
		if mb.is_key_pressed(._2) do effect = .VHS
		if mb.is_key_pressed(._3) do effect = .PSX

		if mb.is_key_pressed(.LEFTBRACKET)  do grid = {max(grid.x * 0.5, 40),  max(grid.y * 0.5, 30)}
		if mb.is_key_pressed(.RIGHTBRACKET) do grid = {min(grid.x * 2, 1280), min(grid.y * 2, 720)}

		if mb.is_cursor_locked() {
			mb.first_person_walk(&rig, &player, 4, mb.get_delta_time())
		}

		// PsxGame's campfire flicker, from stage 5.
		flicker := 1.0 + math.sin(time * 1.0) * 0.1 + math.sin(time * 0.5) * 0.05
		mb.set_lights({mb.create_point_light(
			{math.sin(time * 8.0) * 0.05, 1.0, math.cos(time * 6.0) * 0.05},
			{clamp(EMBER.r * flicker, 0, 1), clamp(EMBER.g * flicker, 0, 0.31), 0, 1},
		)})

		mb.begin_drawing()

		// --- the world, into the texture ---
		mb.begin_drawing_target(&scene)
		mb.clear_background(FOG_COLOR)

		mb.begin_drawing_3d(rig.camera)

		mb.draw_plane({0, 0, 0}, {60, 60}, {0.30, 0.26, 0.22, 1})

		for prop in props {
			if prop.loaded do mb.draw_model_at(prop.model, prop.position, prop.scale)
		}

		for i in 0 ..< 9 {
			angle  := f32(i) * math.TAU / 9
			radius := 7 + f32(i % 3) * 2.5
			mb.draw_cube({math.cos(angle) * radius, 0.6, math.sin(angle) * radius},
				{1.2, 1.2, 1.2}, {0.55, 0.5, 0.45, 1})
		}

		mb.end_drawing_3d()
		mb.end_drawing_target()

		// --- the texture, back to the window, through the filter ---
		mb.draw_post(scene, effect, grid)

		// --- the HUD, after the filter, unfiltered ---
		font := &mb.mbi.font
		mb.draw_text(font, "1 none, 2 VHS, 3 PSX   [ ] grid   WASD walk, ESC pointer", 20, 40, mb.WHITE)

		name := "none"
		switch effect {
		case .PSX:  name = fmt.tprintf("PSX  grid %.0f x %.0f", grid.x, grid.y)
		case .VHS:  name = "VHS"
		case .NONE: name = "none"
		}
		mb.draw_text(font, fmt.tprintf("effect: %s", name), 20, 70, mb.WHITE)
		mb.draw_text(font, "this text is drawn after the effect, so it stays sharp", 20, 100, mb.WHITE)

		mb.end_drawing()
	}

	mb.wait_idle()
}
