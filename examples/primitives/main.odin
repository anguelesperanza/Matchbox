package primitives_example

/*
	Everything Matchbox can draw in 3D without loading a file.

	This is stage 3, and it is deliberately the shape `CoffeeGame` is: coloured
	boxes with black wireframes over them, a ground, and a grid you can read
	distance off. That game draws nothing else.

	Things to look at:

	  - **the wireframes.** Every solid box has its own edges drawn over it, at
	    exactly the depth of the faces that meet there. Without a depth bias in
	    the line pipeline the two would be equal and the outline would come out
	    stippled and crawling as you move. Walk right up to one and look along a
	    face
	  - **the grid, through the boxes.** It is drawn first and the boxes are
	    solid, so it stops where they start. That is the depth buffer doing the
	    same job it did in `examples/cube`, on lines this time
	  - **the sphere.** Sixteen rings of twenty-four, which is the default. The
	    seam where longitude wraps has two vertices at the same place so the
	    texture does not run backwards across it -- not that there is a texture
	    until stage 4
	  - **the red outline round the tall box.** That is `draw_bounds_wires`,
	    given two corners rather than a centre and a size. It is what you point
	    at a Box3D AABB, and the reason it takes plain vectors is that Matchbox
	    has no bounding box type and is not getting one
	  - **press G** to turn the grid off, **B** for the bounds outline

	Movement is a `First_Person_Camera`, which is one struct holding the camera,
	the two angles and the eye height. `first_person_walk` moves the player
	itself; a game with collision calls `first_person_input` and
	`first_person_aim` either side of its solver instead. See
	examples/first-person for that split written out.
*/

import "core:fmt"
import "core:math"

import mb "../../matchbox"

EYE_HEIGHT :: 1.7
WALK_SPEED :: 7.0

Box :: struct {
	position: [3]f32,
	size:     [3]f32,
	color:    [4]f32,
}

// The same shape CoffeeGame's static_obstacles list is: a position, a size and
// a colour, with both the solid and its outline generated from the one entry.
boxes := []Box{
	{{  5, 1.0,  3}, {1, 2, 1},   mb.LIME_GREEN},
	{{ -4, 1.5, -2}, {2, 3, 2},   mb.CORNFLOWER_BLUE},
	{{  0, 1.0, -6}, {6, 0.6, 1}, mb.RED},
	{{ -6, 1.0,  4}, {1, 2, 6},   mb.PUMPKIN_ORANGE},
	{{  8, 2.5, -4}, {2, 5, 2},   mb.WHITE},
}

main :: proc() {
	mb.init("Primitives", 1280, 720)
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
	mb.set_lighting({enabled = true, ambient = {color = {3.5, 3.5, 3.5, 1}}})
	mb.set_lights({mb.create_directional_light({0.4, -1, -0.7}, {0.65, 0.65, 0.65, 1})})

	mb.set_escape_key(.UNKNOWN)

	// Ten back, level, looking along -z at the boxes.
	player := [3]f32{0, 0, 10}

	rig := mb.create_first_person_camera(
		position   = player,
		facing     = -math.PI * 0.5,
		eye_offset = {0, EYE_HEIGHT, 0},
	)

	show_grid   := true
	show_bounds := true

	mb.set_cursor_locked(true)

	for mb.is_running() {
		mb.poll_events()

		if mb.is_key_pressed(.ESCAPE) {
			if mb.is_cursor_locked() do mb.set_cursor_locked(false)
			else                 do mb.mbi.running = false
		}
		if !mb.is_cursor_locked() && mb.is_mouse_pressed(.LEFT) do mb.set_cursor_locked(true)

		if mb.is_key_pressed(.G) do show_grid   = !show_grid
		if mb.is_key_pressed(.B) do show_bounds = !show_bounds

		if mb.is_cursor_locked() {
			mb.first_person_walk(&rig, &player, WALK_SPEED, mb.get_delta_time())
		}

		mb.begin_drawing()
		mb.clear_background({0.53, 0.68, 0.85, 1})

		mb.begin_drawing_3d(rig.camera)

		// Ground first, then the grid just above it. A plane and a grid at the
		// same height would fight over every pixel of every line, and the depth
		// bias only has so much to give.
		mb.draw_plane({0, 0, 0}, {60, 60}, {0.42, 0.47, 0.40, 1})
		if show_grid do mb.draw_grid(slices = 40, spacing = 1)

		for box in boxes {
			mb.draw_cube(box.position, box.size, box.color)
			mb.draw_cube_wires(box.position, box.size, mb.BLACK)
		}

		mb.draw_sphere({2, 1.2, 2}, 1.2, {0.85, 0.75, 0.35, 1})
		mb.draw_sphere({-2, 0.6, 6}, 0.6, mb.RED)

		// Corners rather than centre and size, which is the form a physics
		// library reports. The tall white box, given the long way round.
		if show_bounds {
			tall := boxes[4]
			mb.draw_bounds_wires(
				tall.position - tall.size * 0.5 - {0.15, 0.15, 0.15},
				tall.position + tall.size * 0.5 + {0.15, 0.15, 0.15},
				mb.RED)
		}

		mb.end_drawing_3d()

		font := &mb.mbi.font
		mb.draw_text(font, "cubes, wires, a plane, spheres and a grid", 20, 40, mb.WHITE)
		mb.draw_text(font, "G grid, B bounds, ESC pointer", 20, 70, mb.WHITE)
		mb.draw_text(font, fmt.tprintf("at %.1f, %.1f, %.1f",
			rig.camera.position.x, rig.camera.position.y, rig.camera.position.z), 20, 110, mb.WHITE)

		cx := f32(mb.mbi.width) * 0.5
		cy := f32(mb.mbi.height) * 0.5
		mb.draw_rect({position = {cx, cy}, size = {14, 2}, color = mb.WHITE})
		mb.draw_rect({position = {cx, cy}, size = {2, 14}, color = mb.WHITE})

		mb.end_drawing()
	}

	mb.wait_idle()
}
