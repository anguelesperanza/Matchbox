package shader_3ds_all

// S8-5 of docs/game_shaders_3ds_plan.md: every one of the user's test shaders (games/shaders/*) loaded from romfs and
// drawn on the 3DS, with the framebuffer read back and asserted on. 3DS only: 3ds_build.bat examples\shader-3ds-all, run
// it in Azahar. Results print on the bottom screen (and to Azahar's log).
//
// Each page loads one shader (or two for dreamcast_water, which the game draws with sand), draws a scene made to show
// what the shader's own comments say the 3DS keeps and drops, and runs a few phases of SETTLE frames each: the shader with
// one game-uniform value, the shader with another, and the built-in as a control. At the end of a phase the top screen's
// framebuffer is sampled on a 4 pixel grid, and the page's facts are asserted on the samples. When every page has run,
// the program cycles through the pages for the eye (screenshots), one phase 0 at a time.
//
// The facts are what the .mbs comments promise, not what the first run happened to print; where one was wrong, the
// comment beside it says what was measured instead and why.

import "core:fmt"
import "core:math"
import "core:math/linalg"
import "core:strings"

import mb "../../matchbox"
import "../../matchbox/o3dx/ctru"

SCREEN_WIDTH :: 400
SCREEN_HEIGHT :: 240
SAMPLE_STEP :: 4
SNAP_WIDTH :: SCREEN_WIDTH / SAMPLE_STEP
SNAP_HEIGHT :: SCREEN_HEIGHT / SAMPLE_STEP
SETTLE :: 12 // frames a phase draws before its samples are taken
SHOW_FRAMES :: 300 // frames a page is held for the eye once the checks are done
MAX_PHASES :: 6
SHOW_PHASE :: #config(SHOW_PHASE, 0) // which phase a page draws while it is held and in the cycle for the eye (1 is often the second setting or the control)
HOLD_FRAMES :: #config(HOLD_FRAMES, 0) // frames a page is held after its results, for a person to read them; A moves on at once
FIRST_PAGE :: #config(FIRST_PAGE, 0) // a page to start at (with HOLD_FRAMES high it stays on that page's results), for finding which one stops a run: odin build ... -define:FIRST_PAGE=2

Page :: enum {
	TOON,
	CRT,
	HAZE,
	LAVA_HAZE, // games/shaders/haze's own lava.mbs, not the same as lava's
	LAVA,
	DISSOLVE,
	HOLOGRAM,
	SHIELD,
	SNOW,
	WATER,
	DREAMCAST_WATER,
	SAND,
}

// What a phase draws: the shader or the built-in, and the page's main uniform value (heat, progress, wave height...)
Phase :: struct {
	name:       string,
	use_shader: bool,
	value:      f32,
	frames:     int, // 0 = SETTLE
}

Snapshot :: struct {
	pixels: [SNAP_WIDTH * SNAP_HEIGHT][3]u8,
	column: [SCREEN_HEIGHT][3]u8, // the middle column at full resolution: the grid is 4 pixels apart and misses a thin outline
	gpu_ms: f32,
	cpu_ms: f32,
}

Assets :: struct {
	shader:  mb.Shader, // the page's shader
	other:   mb.Shader, // dreamcast_water's sand
	models:  [4]mb.Model,
	count:   int,
}

Run :: struct {
	assets:    Assets,
	target:    mb.Render_Target, // crt and haze draw the scene into this, then the picture through the shader
	phases:    [MAX_PHASES]Phase,
	phase_count: int,
	snapshots: [MAX_PHASES]Snapshot,
	failures:  int,
	page_failures: int,
	quiet: bool, // the checks are done: nothing more is printed, so the summary stays on the bottom screen
	first_failure: string, // the first failed check of the page, for its summary line
	summaries: [Page]string,
}

PAGE_FILES := [Page]string {
	.TOON            = "toon",
	.CRT             = "crt",
	.HAZE            = "haze",
	.LAVA_HAZE       = "lava_haze",
	.LAVA            = "lava",
	.DISSOLVE        = "dissolve",
	.HOLOGRAM        = "hologram",
	.SHIELD          = "shield",
	.SNOW            = "snow",
	.WATER           = "water",
	.DREAMCAST_WATER = "dreamcast_water",
	.SAND            = "sand",
}

// ---- reading the screen ----------------------------------------------------------------------------------------------

// The panel is 240 wide, 400 tall, scanned up from the player's bottom-left
read_pixel :: proc(pixels: [^]u8, width, x, y: int) -> [3]u8 {
	offset := (x * width + (width - 1 - y)) * 3
	return {pixels[offset + 2], pixels[offset + 1], pixels[offset + 0]} // stored B, G, R
}

capture :: proc(snapshot: ^Snapshot) {
	width, height: u16
	pixels := ([^]u8)(ctru.gfxGetFramebuffer(.TOP, .LEFT, &width, &height))
	for j in 0 ..< SNAP_HEIGHT {
		for i in 0 ..< SNAP_WIDTH {
			snapshot.pixels[j * SNAP_WIDTH + i] = read_pixel(pixels, int(width), i * SAMPLE_STEP + SAMPLE_STEP / 2, j * SAMPLE_STEP + SAMPLE_STEP / 2)
		}
	}
	for y in 0 ..< SCREEN_HEIGHT do snapshot.column[y] = read_pixel(pixels, int(width), SCREEN_WIDTH / 2, y)
	times := mb.get_gpu_times()
	snapshot.cpu_ms = times[0]
	snapshot.gpu_ms = times[1]
}

at :: proc(snapshot: ^Snapshot, x, y: int) -> [3]u8 {
	return snapshot.pixels[clamp(y / SAMPLE_STEP, 0, SNAP_HEIGHT - 1) * SNAP_WIDTH + clamp(x / SAMPLE_STEP, 0, SNAP_WIDTH - 1)]
}

distance :: proc(a, b: [3]u8) -> int {
	return abs(int(a.r) - int(b.r)) + abs(int(a.g) - int(b.g)) + abs(int(a.b) - int(b.b))
}

luminance :: proc(p: [3]u8) -> int {
	return (int(p.r) * 299 + int(p.g) * 587 + int(p.b) * 114) / 1000
}

to_u8 :: proc(colour: [4]f32) -> [3]u8 {
	return {u8(colour.r * 255 + 0.5), u8(colour.g * 255 + 0.5), u8(colour.b * 255 + 0.5)}
}

Region :: struct {
	x0, y0, x1, y1: int,
}

WHOLE :: Region{0, 0, SCREEN_WIDTH, SCREEN_HEIGHT}

// Mean over the region of the summed channel distance between two snapshots, times ten (an integer with one decimal)
mean_difference :: proc(a, b: ^Snapshot, region := WHOLE) -> f32 {
	total, count := 0, 0
	for y := region.y0; y < region.y1; y += SAMPLE_STEP {
		for x := region.x0; x < region.x1; x += SAMPLE_STEP {
			total += distance(at(a, x, y), at(b, x, y))
			count += 1
		}
	}
	return f32(total) / f32(max(count, 1))
}

max_difference :: proc(a, b: ^Snapshot, region := WHOLE) -> int {
	biggest := 0
	for y := region.y0; y < region.y1; y += SAMPLE_STEP {
		for x := region.x0; x < region.x1; x += SAMPLE_STEP {
			biggest = max(biggest, distance(at(a, x, y), at(b, x, y)))
		}
	}
	return biggest
}

mean_luminance :: proc(a: ^Snapshot, region := WHOLE) -> f32 {
	total, count := 0, 0
	for y := region.y0; y < region.y1; y += SAMPLE_STEP {
		for x := region.x0; x < region.x1; x += SAMPLE_STEP {
			total += luminance(at(a, x, y))
			count += 1
		}
	}
	return f32(total) / f32(max(count, 1))
}

mean_channel :: proc(a: ^Snapshot, channel: int, region := WHOLE) -> f32 {
	total, count := 0, 0
	for y := region.y0; y < region.y1; y += SAMPLE_STEP {
		for x := region.x0; x < region.x1; x += SAMPLE_STEP {
			total += int(at(a, x, y)[channel])
			count += 1
		}
	}
	return f32(total) / f32(max(count, 1))
}

// How many samples in the region are not the background (further than `slack` from it)
count_object :: proc(a: ^Snapshot, background: [3]u8, slack: int, region := WHOLE) -> int {
	count := 0
	for y := region.y0; y < region.y1; y += SAMPLE_STEP {
		for x := region.x0; x < region.x1; x += SAMPLE_STEP {
			if distance(at(a, x, y), background) > slack do count += 1
		}
	}
	return count
}

// How many different luminance values the column has between two rows: smooth shading has many, flat bands have few
count_levels :: proc(a: ^Snapshot, x, y0, y1: int) -> int {
	seen: [256]bool
	count := 0
	for y := y0; y < y1; y += SAMPLE_STEP {
		level := luminance(at(a, x, y))
		if !seen[level] {
			seen[level] = true
			count += 1
		}
	}
	return count
}

// The first row going up (or down) from `y` in column `x` that is the background again: the edge of what is drawn there
find_edge :: proc(a: ^Snapshot, background: [3]u8, x, y, step: int) -> int {
	row := y
	for row > 0 && row < SCREEN_HEIGHT - 1 && distance(at(a, x, row), background) > 24 {
		row += step
	}
	return row
}

// Prints, and draws a frame so the line is on the bottom screen before whatever comes next (a crash does not draw it)
say :: proc(run: ^Run, text: string) {
	if !run.quiet do mb.print(text)
	mb.render_start()
	mb.clear_background({0, 0, 0, 1})
	mb.render_end()
}

check :: proc(run: ^Run, ok: bool, text: string) {
	if !ok {
		run.failures += 1
		run.page_failures += 1
		if run.page_failures == 1 do run.first_failure = text
		mb.print("  FAIL", text)
	}
}

// ---- the scenes ------------------------------------------------------------------------------------------------------

// A flat square of `size` units centred on the origin, facing up, cut into `cells` x `cells` squares: the games' own
create_grid :: proc(size: f32, cells: int) -> mb.Model {
	side := cells + 1
	vertices := make([]mb.Lit_Vertex, side * side, context.temp_allocator)
	indices := make([]u16, cells * cells * 6, context.temp_allocator)
	white := [4]f32{1, 1, 1, 1}
	for row in 0 ..< side {
		for column in 0 ..< side {
			u := f32(column) / f32(cells)
			v := f32(row) / f32(cells)
			vertices[row * side + column] = {
				vertex = {position = {(u - 0.5) * size, 0, (v - 0.5) * size}, uv = {u, v}, color = white},
				normal = {0, 1, 0},
			}
		}
	}
	i := 0
	for row in 0 ..< cells {
		for column in 0 ..< cells {
			top_left := u16(row * side + column)
			top_right := top_left + 1
			bottom_left := top_left + u16(side)
			bottom_right := bottom_left + 1
			indices[i + 0], indices[i + 1], indices[i + 2] = bottom_left, bottom_right, top_right
			indices[i + 3], indices[i + 4], indices[i + 5] = bottom_left, top_right, top_left
			i += 6
		}
	}
	return mb.create_model_from_mesh(vertices, indices)
}

// Per pixel lighting with no highlight, so the shader and the built-in are the same lighting to compare
set_plain_material :: proc(model: ^mb.Model) {
	for &part in model.parts do part.material = {shininess = 1, specular_strength = 0, lighting = .PER_PIXEL}
}

add_model :: proc(assets: ^Assets, model: mb.Model) -> mb.Model {
	assets.models[assets.count] = model
	assets.count += 1
	return model
}

phase :: proc(run: ^Run, name: string, use_shader: bool, value: f32 = 0, frames := 0) {
	run.phases[run.phase_count] = {name, use_shader, value, frames}
	run.phase_count += 1
}

// Loads the page's shader(s) and models, and lists its phases. Between frames, as load_shader asks
begin_page :: proc(run: ^Run, page: Page) {
	run.phase_count = 0
	run.page_failures = 0
	assets := &run.assets
	assets^ = {}
	assets.shader = mb.load_shader(PAGE_FILES[page])
	say(run, "  shader loaded")
	switch page {
	case .TOON:
		add_model(assets, mb.create_sphere_model(1.2, 24, 48))
		phase(run, "toon", true)
		phase(run, "built-in", false)
	case .CRT, .HAZE:
		add_model(assets, mb.create_sphere_model(1.2, 24, 48))
		add_model(assets, mb.create_cylinder_model(0.8, 2.4, 32))
		add_model(assets, mb.create_cube_model())
		add_model(assets, mb.create_plane_model(30))
		phase(run, "shader, tint black", true)
		phase(run, "built-in, tint white", false, 1)
		phase(run, "built-in, tint black", false, 0)
	case .LAVA_HAZE, .LAVA:
		add_model(assets, create_grid(40, 128))
		phase(run, "heat 1", true, 1)
		phase(run, "heat 0", true, 0)
		phase(run, "built-in", false)
		phase(run, "heat 1 later", true, 1, 50)
	case .DISSOLVE:
		add_model(assets, mb.create_sphere_model(1.2, 32, 64))
		phase(run, "progress 0", true, 0)
		phase(run, "progress 0.25", true, 0.25)
		phase(run, "progress 0.5", true, 0.5)
		phase(run, "progress 0.75", true, 0.75)
		phase(run, "progress 1", true, 1)
		phase(run, "built-in", false)
	case .HOLOGRAM:
		sphere := add_model(assets, mb.create_sphere_model(1.2, 32, 64))
		for &part in assets.models[0].parts do part.blend = .ALPHA
		_ = sphere
		phase(run, "hologram", true)
		phase(run, "built-in", false)
		phase(run, "hologram later", true, 0, 45)
	case .SHIELD:
		add_model(assets, mb.create_sphere_model(2.6, 48, 96))
		for &part in assets.models[0].parts do part.blend = .ALPHA
		add_model(assets, mb.create_cylinder_model(0.6, 1.8, 32))
		add_model(assets, mb.create_sphere_model(0.5, 24, 48))
		phase(run, "no hit", true, 0)
		phase(run, "hit", true, 0.15)
		phase(run, "no shield", false)
	case .SNOW:
		add_model(assets, mb.create_sphere_model(1.2, 32, 64))
		phase(run, "snow 0", true, 0)
		phase(run, "snow 0.5", true, 0.5)
		phase(run, "built-in", false)
		phase(run, "snow 1", true, 1)
	case .WATER:
		add_model(assets, create_grid(40, 128))
		for &part in assets.models[0].parts do part.blend = .ALPHA
		add_model(assets, mb.create_cube_model(2.5))
		phase(run, "wave 0.05", true, 0.05)
		phase(run, "wave 1.5", true, 1.5)
		phase(run, "built-in", false)
		phase(run, "wave 0.05 later", true, 0.05, 45)
	case .DREAMCAST_WATER:
		add_model(assets, create_grid(60, 64))
		for &part in assets.models[0].parts do part.blend = .ALPHA
		add_model(assets, mb.create_sphere_model(4, 16, 32))
		assets.other = mb.load_shader("sand")
		phase(run, "island 3.67", true, 3.67)
		phase(run, "no island", true, 0)
		phase(run, "built-in", false)
		phase(run, "island 3.67 later", true, 3.67, 45)
	case .SAND:
		add_model(assets, mb.create_sphere_model(4, 16, 32))
		phase(run, "sand", true)
		phase(run, "built-in", false)
	}
	say(run, "  models made")
	for index in 0 ..< assets.count do set_plain_material(&assets.models[index])
}

end_page :: proc(run: ^Run) {
	// A frame first: the GPU may still be reading what is about to be freed (without it a freed mesh broke the next load in Azahar)
	say(run, "  ending page")
	mb.set_shader({})
	mb.destroy_shader(run.assets.shader)
	mb.destroy_shader(run.assets.other)
	for index in 0 ..< run.assets.count do mb.destroy(run.assets.models[index])
	run.assets = {}
}

SUN :: [3]f32{1, -0.8, -0.5}

// One frame of a page in one phase
draw_page :: proc(run: ^Run, page: Page, current: Phase) {
	assets := &run.assets
	shader := assets.shader if current.use_shader else mb.Shader{}
	time := f32(mb.get_time())
	white := [4]f32{1, 1, 1, 1}

	switch page {
	case .TOON:
		mb.set_lights({mb.create_directional_light(SUN)})
		mb.set_lighting({enabled = true, ambient = {0.08, 0.08, 0.12, 1}})
		mb.clear_background({0.75, 0.88, 1, 1})
		mb.camera_start(mb.create_camera_3d({0, 1, 4.5}, {0, 1, 0}))
		mb.set_shader(shader)
		mb.render_model(assets.models[0], mb.create_transform({0, 1, 0}), {0.9, 0.3, 0.25, 1})
		mb.set_shader({})
		mb.camera_end()

	case .CRT, .HAZE:
		mb.set_lights({mb.create_directional_light(SUN)})
		mb.set_lighting({enabled = true, ambient = {0.3, 0.3, 0.35, 1}})
		mb.render_target_start(&run.target, [4]f32{0.55, 0.75, 0.95, 1})
		mb.camera_start(mb.create_camera_3d({0, 3, 8}, {0, 1, 0}))
		mb.render_model(assets.models[3], [3]f32{0, -0.01, 0}, {0.3, 0.7, 0.35, 1})
		mb.render_model(assets.models[0], [3]f32{-3.2, 1.2, 0}, {0.95, 0.3, 0.25, 1})
		mb.render_model(assets.models[1], [3]f32{0, 1.2, 0}, {0.3, 0.55, 0.95, 1})
		mb.render_model(assets.models[2], mb.create_transform({3.2, 1, 0}, scale = 2), {0.95, 0.8, 0.25, 1})
		mb.camera_end()
		mb.render_target_end()
		mb.clear_background({0, 0, 0, 1})
		// The shader ignores the tint (crt says so itself; haze's REPLACE reads the picture only); the control's tint is the phase's
		tint := [4]f32{0, 0, 0, 1} if current.use_shader else [4]f32{current.value, current.value, current.value, 1}
		mb.render_upscaled_target(run.target, .STRETCH, tint, shader)

	case .LAVA_HAZE, .LAVA:
		mb.set_lights({mb.create_directional_light({0.6, -1, -0.4})})
		mb.set_lighting({enabled = true, ambient = {0.12, 0.08, 0.08, 1}})
		if current.use_shader do mb.set_shader_value("heat", current.value, assets.shader)
		mb.clear_background({0.12, 0.05, 0.04, 1})
		mb.camera_start(mb.create_camera_3d({0, 3.5, 11}, {0, 0, 0}))
		mb.set_shader(shader)
		mb.render_model(assets.models[0], [3]f32{0, 0, 0})
		mb.set_shader({})
		mb.camera_end()

	case .DISSOLVE:
		mb.set_lights({mb.create_directional_light(SUN)})
		mb.set_lighting({enabled = true, ambient = {0.25, 0.25, 0.3, 1}})
		if current.use_shader do mb.set_shader_value("progress", current.value, assets.shader)
		mb.clear_background({0.12, 0.13, 0.18, 1})
		mb.camera_start(mb.create_camera_3d({0, 0.5, 5}, {0, 0.5, 0}))
		mb.set_shader(shader)
		mb.render_model(assets.models[0], [3]f32{0, 0.5, 0}, {0.9, 0.3, 0.25, 1})
		mb.set_shader({})
		mb.camera_end()

	case .HOLOGRAM:
		mb.set_lights({mb.create_directional_light(SUN)})
		mb.set_lighting({enabled = true, ambient = {0.25, 0.25, 0.3, 1}})
		if current.use_shader do mb.set_shader_value("glitch", f32(1), assets.shader)
		mb.clear_background({0.02, 0.03, 0.06, 1})
		mb.camera_start(mb.create_camera_3d({0, 1, 4.5}, {0, 1, 0}))
		mb.set_shader(shader)
		mb.render_model(assets.models[0], [3]f32{0, 1, 0})
		mb.set_shader({})
		mb.camera_end()

	case .SHIELD:
		mb.set_lights({mb.create_directional_light(SUN)})
		mb.set_lighting({enabled = true, ambient = {0.25, 0.25, 0.3, 1}})
		if current.use_shader {
			mb.set_shader_value("hit_a", [4]f32{0, 1.5, 2.6, current.value}, assets.shader)
			mb.set_shader_value("hit_b", [4]f32{}, assets.shader)
			mb.set_shader_value("hit_c", [4]f32{}, assets.shader)
		}
		mb.clear_background({0.03, 0.04, 0.08, 1})
		mb.camera_start(mb.create_camera_3d({0, 3.5, 9}, {0, 1.4, 0}))
		mb.render_model(assets.models[1], [3]f32{0, 0.9, 0}, {0.8, 0.6, 0.3, 1})
		mb.render_model(assets.models[2], [3]f32{0, 2.2, 0}, {0.9, 0.75, 0.6, 1})
		// Last, so the figure behind it is already in the picture for the blend to go over
		mb.set_shader(shader)
		if current.use_shader do mb.render_model(assets.models[0], [3]f32{0, 1.5, 0})
		mb.set_shader({})
		mb.camera_end()

	case .SNOW:
		mb.set_lights({mb.create_directional_light({0.5, -1, -0.6})})
		mb.set_lighting({enabled = true, ambient = {0.35, 0.38, 0.5, 1}})
		if current.use_shader {
			mb.set_shader_value("snow_amount", current.value, assets.shader)
			mb.set_shader_value("snow_depth", f32(0.07), assets.shader)
		}
		mb.clear_background({0.55, 0.65, 0.8, 1})
		mb.camera_start(mb.create_camera_3d({0, 4.5, 9}, {0, 1, 0}))
		mb.set_shader(shader)
		mb.render_model(assets.models[0], [3]f32{0, 1.2, 0}, {0.55, 0.3, 0.25, 1})
		mb.set_shader({})
		mb.camera_end()

	case .WATER:
		mb.set_lights({mb.create_directional_light({-1, -1.5, -0.6})})
		mb.set_lighting({enabled = true, ambient = {0.35, 0.35, 0.4, 1}})
		if current.use_shader do mb.set_shader_value("wave_height", current.value, assets.shader)
		mb.clear_background({0.65, 0.8, 0.95, 1})
		mb.camera_start(mb.create_camera_3d({0, 5, 14}, {0, 0, 0}))
		mb.render_model(assets.models[1], [3]f32{0, -1.5, 0}, {0.9, 0.3, 0.2, 1}) // under the surface: seen through the alpha, or not at all
		mb.set_shader(shader)
		mb.render_model(assets.models[0], [3]f32{0, 0, 0}, {0.25, 0.5, 0.75, 1})
		mb.set_shader({})
		mb.camera_end()

	case .DREAMCAST_WATER:
		mb.set_lights({mb.create_directional_light({-1, -1.5, -0.6})})
		mb.set_lighting({enabled = true, ambient = {0.55, 0.55, 0.6, 1}})
		if current.use_shader do mb.set_shader_value("island", [3]f32{0, 0, current.value}, assets.shader)
		mb.clear_background({0.55, 0.82, 0.98, 1})
		mb.camera_start(mb.create_camera_3d({math.sin(f32(0.6)) * 15, 8, math.cos(f32(0.6)) * 15}, {0, 0, 0}))
		island := mb.create_transform({0, -0.4, 0})
		island.scale = {1, 0.25, 1}
		mb.set_shader(assets.other if current.use_shader else mb.Shader{})
		mb.render_model(assets.models[1], island, {0.95, 0.85, 0.55, 1})
		mb.set_shader(shader)
		mb.render_model(assets.models[0], [3]f32{0, 0, 0})
		mb.set_shader({})
		mb.camera_end()

	case .SAND:
		mb.set_lights({mb.create_directional_light({-1, -1.5, -0.6})})
		mb.set_lighting({enabled = true, ambient = {0.55, 0.55, 0.6, 1}})
		mb.clear_background({0.55, 0.82, 0.98, 1})
		mb.camera_start(mb.create_camera_3d({0, 4, 8}, {0, 0.3, 0}))
		island := mb.create_transform({0, -0.4, 0})
		island.scale = {1, 0.25, 1}
		mb.set_shader(shader)
		mb.render_model(assets.models[0], island, {0.95, 0.85, 0.55, 1})
		mb.set_shader({})
		mb.camera_end()
	}
	_ = time
	_ = white
}

// ---- the facts -------------------------------------------------------------------------------------------------------

f :: proc(value: f32) -> string {
	return fmt.tprintf("%.1f", value)
}

evaluate :: proc(run: ^Run, page: Page) {
	s := &run.snapshots
	c := Region{0, 0, SCREEN_WIDTH, SCREEN_HEIGHT}
	_ = c
	switch page {
	case .TOON:
		// The toon shader's plan is diffuse * colour: on the sphere's middle, which faces the camera (no rim, no outline),
		// that is the built-in's lit pixel. The PC's three flat bands are dropped: the shading is smooth, many levels
		bg := to_u8({0.75, 0.88, 1, 1})
		centre, control := at(&s[0], 200, 120), at(&s[1], 200, 120)
		check(run, distance(centre, bg) > 60, "toon: the sphere is not there")
		check(run, distance(centre, control) <= 12, fmt.tprintf("toon centre %v is not the built-in's lit %v", centre, control))
		levels := count_levels(&s[0], 200, 80, 160)
		check(run, levels >= 10, fmt.tprintf("toon is banded: %d luminance levels down the sphere", levels))
		// The outline: within a few pixels of the silhouette the colour is inked near-black, which the built-in does not do
		// (the ring is thin: the vertex rings of a 24 x 48 sphere are a few pixels apart there)
		top := find_edge(&s[1], bg, 200, 120, -SAMPLE_STEP)
		darkest, control_darkest := 255, 255
		for y in top - 4 ..< top + 20 {
			darkest = min(darkest, luminance(s[0].column[y]))
			control_darkest = min(control_darkest, luminance(s[1].column[y]))
		}
		mb.print("  toon: edge row", top, "darkest", darkest, "built-in darkest", control_darkest, "levels", levels)
		check(run, darkest < control_darkest - 8, "toon: no outline darkening near the silhouette")

	case .CRT:
		// texture * vertex colour: the picture, times the flicker (1 +- 1.2%) and nothing else. No curvature, scanlines or vignette
		worst := max_difference(&s[0], &s[1])
		corner := distance(at(&s[0], 12, 12), at(&s[1], 12, 12))
		mb.print("  crt: worst difference from the plain picture", worst, "corner", corner, "mean lum", f(mean_luminance(&s[0])))
		check(run, mean_luminance(&s[0]) > 40, "crt: the picture is not there")
		check(run, worst <= 12, fmt.tprintf("crt: differs from the plain picture by up to %d (flicker is 1.2%% only)", worst))
		check(run, corner <= 12, "crt: the corners are darker (a vignette)")
		check(run, mean_luminance(&s[2]) < 3, "crt: the control's black tint was not black")

	case .HAZE:
		// REPLACE TEXTURE0: the picture exactly, unmoved, and the tint is ignored (a black tint still draws it)
		worst := max_difference(&s[0], &s[1])
		mb.print("  haze: worst difference from the plain picture", worst, "mean lum", f(mean_luminance(&s[0])))
		check(run, mean_luminance(&s[0]) > 40, "haze: the picture is not there (the tint was applied)")
		check(run, worst <= 6, fmt.tprintf("haze: the picture is not the plain one (%d)", worst))
		check(run, mean_luminance(&s[2]) < 3, "haze: the control's black tint was not black")

	case .LAVA_HAZE, .LAVA:
		// The cracks glow with `heat`; at 0 there is a dark lit crust. Lit as if flat on the 3DS, so no swell shading
		bg := to_u8({0.12, 0.05, 0.04, 1})
		lake := Region{0, 170, SCREEN_WIDTH, SCREEN_HEIGHT}
		hot_red, cold_red := mean_channel(&s[0], 0, lake), mean_channel(&s[1], 0, lake)
		hot_max, cold_max := 0, 0
		for y := lake.y0; y < lake.y1; y += SAMPLE_STEP {
			for x := 0; x < SCREEN_WIDTH; x += SAMPLE_STEP {
				hot_max = max(hot_max, int(at(&s[0], x, y).r))
				cold_max = max(cold_max, int(at(&s[1], x, y).r))
			}
		}
		moved := mean_difference(&s[0], &s[3], lake)
		mb.print("  red mean hot", f(hot_red), "cold", f(cold_red), "max", hot_max, cold_max, "later diff", f(moved))
		check(run, count_object(&s[0], bg, 20, lake) > 500, "lava: the lake is not there")
		check(run, hot_red > cold_red + 3, "lava: heat 1 is not redder than heat 0 (the uniform did not arrive, or no cracks)")
		// games/shaders/haze's lava floods the whole lake with dark red at any heat on the 3DS (magma(0) is RED, added outside the
		// cracks): its mean red is 161 cold, so only lava.mbs has the dark crust to compare against
		// (not the maximum: the cold lake's hairline cracks still glow to 239..244 red, so the maximum cannot tell hot from cold)
		if page == .LAVA do check(run, hot_red > cold_red * 2, "lava: the heat 0 crust is not dark against heat 1")
		check(run, mean_difference(&s[1], &s[2], lake) > 1, "lava: the heat 0 lake is the built-in's")

	case .DISSOLVE:
		// Alpha carries the burn and the alpha test throws away what is under 0.9: discarded pixels are the background exactly
		bg := to_u8({0.12, 0.13, 0.18, 1})
		counts: [6]int
		for index in 0 ..< 6 do counts[index] = count_object(&s[index], bg, 6)
		mb.print("  object samples by progress 0..1, built-in:", counts[0], counts[1], counts[2], counts[3], counts[4], counts[5])
		check(run, counts[5] > 300, "dissolve: the control sphere is not there")
		check(run, counts[0] * 100 >= counts[5] * 90, "dissolve: progress 0 is not the whole sphere")
		check(run, counts[4] == 0, "dissolve: progress 1 left pixels behind (alpha test did not discard)")
		for index in 0 ..< 4 do check(run, counts[index + 1] <= counts[index], "dissolve: more of the sphere at a higher progress")
		check(run, counts[2] * 10 > counts[5] && counts[2] * 10 < counts[5] * 9, "dissolve: progress 0.5 is not partly gone")

	case .HOLOGRAM:
		// Everything per vertex, in the colour, blended: cyan, see-through (the middle is nearly the background), animated
		bg := to_u8({0.02, 0.03, 0.06, 1})
		visible := count_object(&s[0], bg, 12)
		blue, red := mean_channel(&s[0], 2), mean_channel(&s[0], 0)
		centre, control := at(&s[0], 200, 120), at(&s[1], 200, 120)
		changed := mean_difference(&s[0], &s[2])
		mb.print("  hologram visible", visible, "mean r b", f(red), f(blue), "centre", centre, "control", control, "later diff", f(changed))
		check(run, visible > 100, "hologram: nothing is drawn")
		check(run, distance(centre, bg) < distance(control, bg), "hologram: the middle is as solid as the built-in's")
		check(run, changed > 0.05, "hologram: no change over time")

	case .SHIELD:
		// Nearly clear in the middle (alpha 0.03: the figure shows), a rim that glows, a hit that lights a ring
		centre, control := at(&s[0], 200, 120), at(&s[2], 200, 120)
		rim := max_difference(&s[0], &s[2])
		hit := max_difference(&s[1], &s[0], Region{120, 80, 280, 170})
		hit_mean := mean_difference(&s[1], &s[0], Region{120, 80, 280, 170})
		mb.print("  shield centre", centre, "no shield", control, "rim max", rim, "hit max/mean", hit, f(hit_mean))
		check(run, distance(centre, control) <= 24, "shield: the figure behind does not show through the middle")
		check(run, rim >= 25, "shield: nothing of it is drawn")
		check(run, hit >= 30, "shield: the hit did not change the picture (hit_a did not arrive)")

	case .SNOW:
		// At 0.5: whiter where the surface faces up, by world up, and unchanged where it faces down. At 1 everything is covered
		bg := to_u8({0.55, 0.65, 0.8, 1})
		top := find_edge(&s[2], bg, 200, 120, -SAMPLE_STEP)
		bottom := find_edge(&s[2], bg, 200, 120, SAMPLE_STEP)
		upper, lower := top + 12, bottom - 12
		gain := luminance(at(&s[1], 200, upper)) - luminance(at(&s[0], 200, upper))
		change := abs(luminance(at(&s[1], 200, lower)) - luminance(at(&s[0], 200, lower)))
		bare := distance(at(&s[0], 200, 120), at(&s[2], 200, 120))
		mb.print("  snow top row", top, "bottom row", bottom, "gain on top", gain, "change below", change, "bare vs built-in", bare)
		check(run, bottom - top > 40, "snow: the sphere is not there")
		check(run, gain >= 25, "snow: the top is not whiter with snow_amount 1")
		check(run, change <= 12, "snow: the underside changed")
		check(run, bare <= 24, "snow: with no snow it is not the built-in's lighting")
		// Amount 1 is "buried": the limit falls below every surface, so the underside is covered too (shader's own comment)
		buried := luminance(at(&s[3], 200, lower)) - luminance(at(&s[0], 200, lower))
		mb.print("  snow 1: the underside gains", buried)
		check(run, buried >= 25, "snow: amount 1 did not cover the underside")

	case .WATER:
		// Waves move with the clock and the wave_height uniform, the colour is per vertex, and the alpha shows what is under it
		surface := Region{0, 170, SCREEN_WIDTH, SCREEN_HEIGHT}
		bg := to_u8({0.65, 0.8, 0.95, 1})
		wave := mean_difference(&s[0], &s[1], surface)
		time := mean_difference(&s[0], &s[3], surface)
		buoy_shader, buoy_plain := at(&s[0], 200, 140), at(&s[2], 200, 140)
		warm_shader := int(buoy_shader.r) - int(buoy_shader.b)
		warm_plain := int(buoy_plain.r) - int(buoy_plain.b)
		mb.print("  water: wave diff", f(wave), "time diff", f(time), "buoy warmth", warm_shader, "vs opaque", warm_plain)
		check(run, count_object(&s[0], bg, 20, surface) > 500, "water: the surface is not there")
		check(run, wave > 1, "water: wave_height does not change the picture")
		check(run, time > 0.3, "water: the waves do not move with the clock")
		check(run, warm_shader > warm_plain + 8, "water: the buoy does not show through (alpha)")

	case .DREAMCAST_WATER:
		surface := Region{0, 130, SCREEN_WIDTH, SCREEN_HEIGHT}
		shore := mean_difference(&s[0], &s[1], surface)
		replaced := mean_difference(&s[0], &s[2], surface)
		time := mean_difference(&s[0], &s[3], surface)
		mb.print("  dreamcast: island uniform diff", f(shore), "vs built-in", f(replaced), "time", f(time))
		check(run, replaced > 8, "dreamcast_water: the picture is the built-in's")
		check(run, shore > 0.3, "dreamcast_water: the island uniform does not change the picture")
		check(run, time > 0.1, "dreamcast_water: nothing moves with the clock")

	case .SAND:
		// Lit sand: the island's colour, warm, like the built-in's lit pixel at the top; wetter and darker at the waterline
		bg := to_u8({0.55, 0.82, 0.98, 1})
		top, control := at(&s[0], 200, 125), at(&s[1], 200, 125)
		warm := int(top.r) - int(top.b)
		lower := mean_luminance(&s[0], Region{0, 150, SCREEN_WIDTH, SCREEN_HEIGHT}) - mean_luminance(&s[1], Region{0, 150, SCREEN_WIDTH, SCREEN_HEIGHT})
		mb.print("  sand: top", top, "built-in", control, "lower band lum minus built-in", f(lower))
		check(run, distance(top, bg) > 60, "sand: the island is not there")
		check(run, warm > 25, "sand: the island is not sand coloured")
		check(run, distance(top, control) <= 30, "sand: the top is not close to the built-in's lit sand")
	}
}

// ---- the run ---------------------------------------------------------------------------------------------------------

main :: proc() {
	mb.init("shader 3ds all", SCREEN_WIDTH, SCREEN_HEIGHT)
	defer mb.cleanup()
	mb.print("check: started (shader-3ds-all, S8-5)")

	run := new(Run)
	// Made here, between frames: a render target made in a frame kills a real 3DS
	run.target = mb.create_render_target({filter = .LINEAR})
	defer mb.destroy(&run.target)

	page := Page(FIRST_PAGE)
	checking := true
	began := false
	phase_index := 0
	frames := 0

	holding := false // the page's results are on the bottom screen and its shader is drawn, until A is pressed (or HOLD_FRAMES pass)
	held := 0

	for mb.is_running() {
		mb.poll_events()
		if !began {
			if checking do mb.print(fmt.tprintf("page %v: loading %s", page, PAGE_FILES[page]))
			begin_page(run, page)
			began = true
			phase_index = 0
			frames = 0
		}
		shown := min(SHOW_PHASE, run.phase_count - 1)
		current := run.phases[phase_index if checking && !holding else shown]

		mb.render_start()
		draw_page(run, page, current)
		mb.render_end()
		frames += 1

		if checking && !holding {
			settle := current.frames if current.frames > 0 else SETTLE
			if frames == settle {
				capture(&run.snapshots[phase_index])
				snap := &run.snapshots[phase_index]
				mb.print(fmt.tprintf("  %s: cpu %.1f gpu %.1f ms", current.name, snap.cpu_ms, snap.gpu_ms))
			}
			if frames > settle {
				frames = 0
				phase_index += 1
				if phase_index == run.phase_count {
					say(run, "  evaluating")
					evaluate(run, page)
					first := &run.snapshots[0]
					text := run.first_failure
					if len(text) > 44 do text = text[:44]
					if run.page_failures == 0 {
						run.summaries[page] = strings.clone(fmt.tprintf("%v ok  cpu %.0f gpu %.1f ms", page, first.cpu_ms, first.gpu_ms))
					} else {
						run.summaries[page] = strings.clone(fmt.tprintf("%v FAIL %s", page, text))
					}
					mb.print(fmt.tprintf("page %v: %s", page, "ok" if run.page_failures == 0 else "FAILED"))
					holding = true
					held = 0
				}
			}
		} else if checking && holding {
			held += 1
			if mb.is_gamepad_pressed(.FACE_RIGHT) || held > HOLD_FRAMES {
				holding = false
				end_page(run)
				began = false
				if page == max(Page) {
					mb.print("---- summary ----")
					for line in run.summaries do if line != "" do mb.print(line)
					mb.print(fmt.tprintf("check: %d pages, failures %d", len(Page), run.failures))
					checking = false
					run.quiet = true
					page = Page(0)
				} else {
					page = Page(int(page) + 1)
				}
			}
		} else if frames >= SHOW_FRAMES {
			end_page(run)
			began = false
			page = Page((int(page) + 1) % len(Page))
		}
	}
	_ = linalg.PI
}
