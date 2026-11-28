package ui_bench

/*
	Phase 6 of the Stargate plan (B6): is one draw per glyph and per rectangle fast enough for an editor? A 1920 by 1080 window with
	a screen's worth of editor in it, drawn through matchbox/ui and timed, at 1, 2, 4 and 8 times that amount. Run from the repository
	root: `odin run examples/ui-bench -o:speed`. It prints one line a load, to the console, and quits by itself.

	One load is: three panels of 50 text rows (about 1500 glyphs each), 12 widgets, 300 plain rectangles for rows and borders, a
	scroll view clipped to its panel, and a 3D viewport with an 82-line grid in a render target. That is an inspector with a long
	entity list, which is the heaviest screen the editor has.

	Present waits for the monitor (vsync), so the frame time cannot go under one refresh. The numbers that show the cost are the
	CPU's: `build` (the UI calls, which queue draws), `submit` (camera_end, which sorts and issues them) and the draw count. A frame
	time that stays at one refresh while those are small means the GPU is not the limit either; one that climbs above it is.
*/

import "core:fmt"
import "core:time"

import mb "../../matchbox"
import ui "../../matchbox/ui"

FRAMES_PER_LOAD :: 120
LOADS := [?]int{1, 2, 4, 8}

draw_editor :: proc(load: int, scroll: ^ui.Scroll_View, dropdown: ^ui.Dropdown) {
	screen := ui.get_screen_rectangle()
	font := ui.default_font()
	for copy in 0 ..< load {
		for panel_index in 0 ..< 3 {
			left := screen.min.x + 10 + f32(panel_index) * 300
			panel := ui.create_rectangle({left, screen.max.y - 10 - f32(copy) * 4}, {290, 900})
			ui.render_rectangle(panel, {0.14, 0.14, 0.18, 1})
			origin := ui.begin_scroll(scroll, panel, 50 * 18)
			for row in 0 ..< 50 {
				row_rectangle := ui.create_rectangle({origin.x, origin.y - f32(row) * 18}, {280, 17})
				ui.render_rectangle(row_rectangle, {0.2, 0.22, 0.3, 1} if row % 2 == 0 else {0.17, 0.18, 0.25, 1})
				ui.render_text(font, "Entity 0123 - Crate (Prop)", {row_rectangle.min.x + 4, ui.calculate_baseline_centred(font, row_rectangle)}, ui.WHITE)
			}
			ui.end_scroll(scroll)
		}
	}
	for index in 0 ..< 12 {
		ui.button(ui.create_rectangle({screen.min.x + 920, screen.max.y - 10 - f32(index) * 34}, {200, 30}), "Button")
	}
	_ = dropdown
}

main :: proc() {
	mb.init("ui bench", 1920, 1080)
	defer ui.shutdown()

	target := mb.create_render_target({width = 800, height = 600})
	camera := mb.create_camera_3d({8, 8, 10}, {0, 0, 0}, 50)
	scroll: ui.Scroll_View
	dropdown: ui.Dropdown

	for load in LOADS {
		build_total, submit_total, frame_total: f64
		items := 0
		for frame in 0 ..< FRAMES_PER_LOAD {
			frame_start := time.tick_now()
			mb.poll_events()
			ui.begin_frame()

			mb.render_start()
			mb.render_target_start(&target, [4]f32{0.1, 0.1, 0.12, 1})
			mb.camera_start(camera)
			mb.render_grid(40, 1, {0.5, 0.5, 0.55, 0.5})
			mb.render_bounds_wires({-1, 0, -1}, {1, 2, 1}, {1, 0.8, 0.2, 1})
			mb.camera_end()
			mb.render_target_end()

			mb.clear_background({0.08, 0.08, 0.1, 1})
			mb.screen_start()
			build_start := time.tick_now()
			draw_editor(load, &scroll, &dropdown)
			ui.render_texture(target.texture, ui.create_rectangle({ui.get_screen_rectangle().max.x - 810, ui.get_screen_rectangle().max.y - 10}, {800, 600}))
			build_total += time.duration_milliseconds(time.tick_since(build_start))

			items = len(mb.mbi.opaque_items) + len(mb.mbi.transparent_items)
			submit_start := time.tick_now()
			mb.screen_end()
			submit_total += time.duration_milliseconds(time.tick_since(submit_start))

			mb.render_end() // waits for the monitor
			ui.end_frame()
			free_all(context.temp_allocator)
			if frame >= 10 do frame_total += time.duration_milliseconds(time.tick_since(frame_start))
		}
		n := f64(FRAMES_PER_LOAD)
		fmt.printfln("load x%d: %d draws a frame | build %.2f ms | submit %.2f ms | whole frame %.2f ms (one refresh: 16.67 at 60 Hz, 8.33 at 120 Hz)", load, items, build_total / n, submit_total / n, frame_total / (n - 10))
	}
}
