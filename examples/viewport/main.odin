package viewport_example

/*
	A lit 3D scene drawn into part of the window, the way an editor's viewport
	or one player's half of a split screen is.

	The scene goes into a `Render_Target`, and `draw_render_target` puts that
	target into the rectangle left between three panels. The panels are flat
	rectangles standing in for whatever a real program puts there.

	Things to try:

	  - resize the window. The viewport rectangle changes and the target is
	    remade to match it -- the readout shows the rectangle's size in pixels
	    and the target's agreeing
	  - press S to stop remaking the target, then resize. The picture still
	    fills the rectangle, but stretched: grow the window and it goes soft,
	    shrink it and the cube's edges start to crawl. That is a target no
	    longer the size of what it is drawn into
	  - press B to outline the same rectangle with `draw_rect_border`. It lines
	    up with the picture's edges, because `dest` is in the same coordinates
	    as every other 2D draw
	  - the shadow, the hemisphere ambient and the ACES curve all happen inside
	    the target. A 3D pass resolves into whatever target is bound, so none
	    of it needs the whole window
*/

import "core:fmt"

import mb "../../matchbox"

PANEL_COLOR :: [4]f32{0.16, 0.17, 0.20, 1}
SKY_COLOR   :: [4]f32{0.35, 0.45, 0.60, 1}

main :: proc() {
	mb.init("Viewport", 1280, 720)
	defer mb.cleanup()

	context.logger = mb.mbi.logger

	settings := mb.Lighting_Settings{
		enabled  = true,
		exposure = 1,
		tonemap  = .ACES,
		ambient  = {kind = .HEMISPHERE, color = {0.45, 0.5, 0.6, 1}, ground_color = {0.2, 0.18, 0.15, 1}},
		shadows  = mb.SHADOW_DEFAULTS,
	}
	mb.set_lighting(settings)

	camera := mb.create_camera3d({6, 5, 8}, {0, 0.5, 0})

	scene: mb.Render_Target
	defer mb.destroy_render_target(&scene)

	remake := true
	border := false
	angle: f32

	for mb.is_running() {
		mb.poll_events()
		angle += mb.get_delta_time()

		if mb.is_key_pressed(.S) do remake = !remake
		if mb.is_key_pressed(.B) do border = !border

		viewport := viewport_rect()

		// In pixels, not in the coordinates the rectangle is laid out in: on a
		// high-density display the two differ, and a target sized in layout
		// units would be stretched up to fill the pixels.
		pixels := mb.screen_size(viewport.size)
		want   := [2]i32{max(i32(pixels.x), 1), max(i32(pixels.y), 1)}

		// Remade only when the size actually changes. A window dragged from its
		// corner changes size every frame of the drag, and a target has no
		// resize -- only a new one.
		if scene.texture == nil || (remake && (scene.width != want.x || scene.height != want.y)) {
			mb.destroy_render_target(&scene)

			target, err := mb.create_render_target(want.x, want.y)
			if err != nil {
				fmt.eprintfln("could not make the viewport's target: %v", err)
				break
			}
			scene = target
		}

		sun := mb.create_directional_light({-0.5, -1, -0.3}, {1, 0.95, 0.85, 1}, casts_shadow = true)
		mb.set_lights([]mb.Light{sun})

		mb.begin_drawing()

		// The window first, while its pass is the one open. Binding the target
		// below ends that pass, and the panels drawn after it reopen the
		// window's without clearing it again.
		mb.clear_background({0.05, 0.05, 0.06, 1})

		mb.begin_drawing_target(&scene)
		{
			mb.clear_background(SKY_COLOR)

			spin := mb.transform_rotation({0, 1, 0}, angle)
			mb.draw_cube({0, 0.75, 0}, {1.5, 1.5, 1.5}, {0.8, 0.35, 0.25, 1}, spin, casts_shadow = true)

			mb.begin_drawing_3d(camera)
			mb.draw_plane({0, 0, 0}, {20, 20}, {0.55, 0.55, 0.5, 1})
			mb.end_drawing_3d()
		}
		mb.end_drawing_target()

		draw_panels()
		mb.draw_render_target(scene, viewport)

		if border do mb.draw_rect_border(viewport, mb.WHITE, 2)

		font := &mb.mbi.font
		mb.draw_text(font, fmt.tprintf("viewport %.0fx%.0f px", pixels.x, pixels.y), 16, 40, mb.WHITE)
		mb.draw_text(font, fmt.tprintf("target   %dx%d px", scene.width, scene.height), 16, 72, mb.WHITE)
		mb.draw_text(font, fmt.tprintf("S remake: %s", "on" if remake else "off"), 16, 120, mb.WHITE)
		mb.draw_text(font, fmt.tprintf("B border: %s", "on" if border else "off"), 16, 152, mb.WHITE)

		mb.end_drawing()
		free_all(context.temp_allocator)
	}

	mb.wait_idle()
}

// The panel sizes, in the coordinates 2D is laid out in. A struct rather than
// three loose constants, per CLAUDE.md.
Panels :: struct {
	left, right, bottom: f32,
}

PANELS :: Panels{left = 260, right = 280, bottom = 160}

// What is left of the window after the panels. Worked out again every frame,
// so a resize needs no handling of its own.
viewport_rect :: proc() -> mb.Rectangle {
	w := f32(mb.mbi.width)
	h := f32(mb.mbi.height)

	return {
		position = {PANELS.left, 0},
		size     = {max(w - PANELS.left - PANELS.right, 1), max(h - PANELS.bottom, 1)},
		pivot    = {0.5, 0.5}, // `position` is the top-left corner
	}
}

draw_panels :: proc() {
	w := f32(mb.mbi.width)
	h := f32(mb.mbi.height)

	mb.draw_rect({position = {0, 0}, size = {PANELS.left, h}, color = PANEL_COLOR, pivot = {0.5, 0.5}})
	mb.draw_rect({position = {w - PANELS.right, 0}, size = {PANELS.right, h}, color = PANEL_COLOR, pivot = {0.5, 0.5}})
	mb.draw_rect({
		position = {PANELS.left, h - PANELS.bottom},
		size     = {w - PANELS.left - PANELS.right, PANELS.bottom},
		color    = {0.13, 0.14, 0.17, 1},
		pivot    = {0.5, 0.5},
	})
}
