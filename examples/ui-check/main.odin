package ui_check

/*
	A window to see matchbox/ui and the 3D editor pieces working together. Run from the repository root:
	`odin run examples/ui-check`. Escape quits.

	What should show: a dark window. On the left a panel with a button, a ticked toggle, a text field (click it and type), a number
	field (drag it sideways, or click and type), a dropdown (its list opens over everything) and a status line. Under them a scroll
	view of 40 rows, which the wheel scrolls and whose bar can be dragged; the rows are cut off cleanly at the view's edges. On the
	right a 3D viewport drawn into a render target and put in a rectangle: a ground grid with the two axes brighter, a wire box
	standing on it, and a small green square that follows the pointer over the ground (the ray from the pointer meets the floor).
	The title line says where.
*/

import "core:fmt"

import mb "../../matchbox"
import ui "../../matchbox/ui"

State :: struct {
	toggle_value:  bool,
	number_value:  f32,
	number_field:  ui.Number_Field,
	text_field:    ui.Text_Field,
	dropdown:      ui.Dropdown,
	scroll:        ui.Scroll_View,
	status:        ui.Status_Line,
	hit:           [3]f32,
	hit_valid:     bool,
}

OPTIONS := []string{"Move", "Rotate", "Scale"}

main :: proc() {
	mb.init("ui check", 1280, 720)
	defer ui.shutdown()

	state := State{toggle_value = true, number_value = 1.5}
	state.text_field.placeholder = "name"
	state.text_field.label = "Name"
	ui.set_status(&state.status, "Ready", .GOOD)

	viewport_size := [2]f32{560, 420}
	target := mb.create_render_target({width = i32(viewport_size.x), height = i32(viewport_size.y)})
	camera := mb.create_camera_3d({6, 6, 8}, {0, 0, 0}, 50)

	for mb.is_running() {
		mb.poll_events()
		if mb.is_key_pressed(.ESCAPE) do mb.stop_running()

		ui.begin_frame()
		screen := ui.get_screen_rectangle()

		// The 3D view
		viewport := ui.create_rectangle({screen.max.x - viewport_size.x - 20, screen.max.y - 60}, viewport_size)
		ray := mb.calculate_ray_from_screen(camera, ui.get_pointer_position(), viewport.min, viewport.max)
		distance, hit := mb.calculate_ray_plane(ray, {0, 0, 0}, {0, 1, 0})
		state.hit_valid = hit && ui.is_point_in_rectangle(ui.get_pointer_position(), viewport)
		if state.hit_valid do state.hit = mb.calculate_ray_point(ray, distance)

		mb.render_start()
		mb.render_target_start(&target, [4]f32{0.12, 0.13, 0.17, 1})
		mb.camera_start(camera)
		mb.render_grid(20, 1, {0.5, 0.5, 0.55, 0.5})
		mb.render_bounds_wires({-1, 0, -1}, {1, 2, 1}, {1, 0.8, 0.2, 1})
		if state.hit_valid do mb.render_bounds_wires(state.hit - {0.25, 0, 0.25}, state.hit + {0.25, 0.01, 0.25}, {0.3, 1, 0.4, 1})
		mb.camera_end()
		mb.render_target_end()

		mb.clear_background({0.08, 0.08, 0.1, 1})
		mb.screen_start()

		// The widgets, down the left from a top edge
		x := screen.min.x + 20
		top := screen.max.y - 60
		ui.render_text(ui.default_font(), "matchbox/ui check", {x, screen.max.y - 40}, ui.WHITE)

		if ui.button(ui.create_rectangle({x, top}, {160, 32}), "Click me") {
			ui.set_status(&state.status, "Button clicked", .INFO, 3)
		}
		top -= 44
		if ui.toggle(ui.create_rectangle({x, top}, {200, 24}), &state.toggle_value, "A toggle") {
			ui.set_status(&state.status, fmt.tprintf("Toggle is %v", state.toggle_value), .WARN, 3)
		}
		top -= 40

		ui.place_text_field(&state.text_field, {x, top}, {240, 30})
		ui.update_text_field(&state.text_field)
		ui.render_text_field(&state.text_field)
		top -= ui.calculate_text_field_height(&state.text_field, 30) + 12

		ui.number_field(&state.number_field, ui.create_rectangle({x, top}, {240, 30}), &state.number_value)
		top -= 42

		ui.dropdown(&state.dropdown, ui.create_rectangle({x, top}, {240, 30}), OPTIONS)
		top -= 46

		// A scroll view of rows, clipped to its panel
		panel := ui.create_rectangle({x, top}, {300, 220})
		ui.render_rectangle(panel, {0.14, 0.14, 0.18, 1})
		origin := ui.begin_scroll(&state.scroll, panel, 40 * 28)
		for row in 0 ..< 40 {
			row_rectangle := ui.create_rectangle({origin.x, origin.y - f32(row) * 28}, {280, 26})
			ui.render_rectangle(row_rectangle, {0.2, 0.22, 0.3, 1} if row % 2 == 0 else {0.17, 0.18, 0.25, 1})
			ui.render_text(ui.default_font(), fmt.tprintf("Row %d", row), {row_rectangle.min.x + 8, ui.calculate_baseline_centred(ui.default_font(), row_rectangle)}, ui.WHITE)
		}
		ui.end_scroll(&state.scroll)

		ui.render_status(&state.status, {x, panel.min.y - 12})

		// The viewport
		ui.render_texture(target.texture, viewport)
		ui.render_rectangle_border(viewport, {0.4, 0.4, 0.5, 1}, 1)
		text := "Move the pointer over the ground"
		if state.hit_valid do text = fmt.tprintf("Ground at x %.2f  z %.2f", state.hit.x, state.hit.z)
		ui.render_text(ui.default_font(), text, {viewport.min.x, viewport.min.y - 28}, ui.WHITE)

		// Last, so it is on top: the dropdown's open list
		ui.render_dropdown_overlay(&state.dropdown, OPTIONS)

		mb.screen_end()
		mb.render_end()
		ui.end_frame()
		free_all(context.temp_allocator)
	}
}
