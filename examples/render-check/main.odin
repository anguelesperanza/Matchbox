package render_check

// Draws a known scene and reads the top screen's framebuffer back at chosen points, so the
// 3DS renderer is checked by numbers: orientation, depth, blending, vertex colour.
// The camera is 12 units tall on a 240 pixel screen, so 1 unit = 20 pixels, origin at the
// centre (200, 120), +y up.
//
// 3DS only (it reads the framebuffer through ctru): 3ds_build.bat examples\render-check, run
// it in Azahar, and the results print on the bottom screen. Citra's 2024 nightly is no use
// for this: it hangs on C3D_DrawElements and ignores the uniforms, where Azahar does
// neither. The scene keeps drawing so it can be looked at as well as measured.

import "core:fmt"
import "core:math"
import "core:math/linalg"

import mb "../../matchbox"
import "../../matchbox/o3dx/ctru"

Probe :: struct {
	name:string,
	x, y:int, // screen pixels as the player sees them, y down from the top
	expected:[3]u8,
}

main :: proc() {
	mb.init("render check", 400, 240)
	defer mb.cleanup()

	camera := mb.create_camera_2d(12)

	probes := [?]Probe {
		{"red only (x -7.5)", 50, 120, {255, 0, 0}},
		{"red+green overlap, green nearer, drawn first", 150, 120, {0, 255, 0}},
		{"green only", 190, 120, {0, 255, 0}},
		{"white 50% over blue", 300, 120, {128, 128, 255}},
		{"yellow marker top-left", 20, 20, {255, 255, 0}},
		{"magenta marker bottom-right", 380, 220, {255, 0, 255}},
		{"background top-right", 380, 20, {0, 0, 255}},
		{"background bottom-left", 20, 220, {0, 0, 255}},
		{"quad facing the camera, cull BACK: drawn", 300, 30, {255, 128, 0}},
		{"quad mirrored (facing away), cull BACK: culled", 340, 30, {0, 0, 255}},

		// Textures (Phase D). Each sprite is 12 x 20 image pixels at 10 a unit, so 24 x 40 screen
		// pixels, and shows four colours: red top left, green top right, yellow bottom left,
		// cyan bottom right. POINT filtering, so every pixel is exact
		{"loaded .t3x, top left", 54, 200, {255, 0, 0}},
		{"loaded .t3x, top right", 66, 200, {0, 255, 0}},
		{"loaded .t3x, bottom left", 54, 220, {255, 255, 0}},
		{"loaded .t3x, bottom right", 66, 220, {0, 255, 255}},
		{"made from pixels, top left", 114, 200, {255, 0, 0}},
		{"made from pixels, top right", 126, 200, {0, 255, 0}},
		{"made from pixels, bottom left", 114, 220, {255, 255, 0}},
		{"made from pixels, bottom right", 126, 220, {0, 255, 255}},
		{"frame 3 of the .meta grid", 180, 210, {0, 255, 255}},
		{"flip_x, top left shows top right", 234, 200, {0, 255, 0}},
		{"flip_x, bottom right shows bottom left", 246, 220, {255, 255, 0}},
	}

	// The same 12 x 20 picture the .t3x holds, made in memory, so both texture paths are
	// checked against one set of probes
	quadrant_pixels:[12 * 20 * 4]u8
	quadrant_colors := [4][4]u8{{255, 0, 0, 255}, {0, 255, 0, 255}, {255, 255, 0, 255}, {0, 255, 255, 255}}
	for y in 0 ..< 20 {
		for x in 0 ..< 12 {
			color := quadrant_colors[int(y >= 10) * 2 + int(x >= 6)]
			for c in 0 ..< 4 do quadrant_pixels[(y * 12 + x) * 4 + c] = color[c]
		}
	}

	// From examples/render-check/assets/images, in a subfolder to check the build keeps it,
	// and with a .meta (a 2 x 2 grid, ppu 10)
	loaded := mb.load_texture("checks/quadrants.png", .POINT)
	defer mb.destroy_texture(loaded)
	made := mb.create_texture_from_pixels(&quadrant_pixels, 12, 20, .POINT)
	defer mb.destroy_texture(made)
	// Two squares with a transparent gap and no .meta, so its frames are guessed
	guessed := mb.load_texture("guessed.png", .POINT)
	defer mb.destroy_texture(guessed)

	whole := [4]f32{0, 0, 12, 20}
	loaded_sprite := mb.create_sprite(loaded, {-7, -4.5, 0})
	loaded_sprite.source = whole
	made_sprite := mb.create_sprite(made, {-4, -4.5, 0}, 10)
	made_sprite.source = whole
	frame_sprite := mb.create_sprite(loaded, {-1, -4.5, 0})
	frame_sprite.frame = 3
	flipped_sprite := mb.create_sprite(loaded, {2, -4.5, 0})
	flipped_sprite.source = whole
	flipped_sprite.flip_x = true

	// The shared override.png is a 16 x 8 strip with a .meta of 2 columns at ppu 10. The 3DS
	// has its own 8 x 8 override.png and no .meta, so the build must leave the shared one out:
	// read with it, an 8 pixel image would be split into two 4 pixel frames at the wrong size
	override := mb.load_texture("override.png", .POINT)
	defer mb.destroy_texture(override)

	// Text (F2): the console's system font on the 3DS. Baked at 20 pixels with 20 pixels to the
	// unit, so glyphs land 1:1 on screen. Descenders and capitals, to catch a glyph cut short
	font := mb.create_font(mb.DEFAULT_FONT_BYTES, 20, 20, .POINT)
	defer mb.destroy_font(font)
	text :: "Matchbox gjy|ABC!"
	text_position := [3]f32{-7, 4, 0} // baseline at screen (60, 40)

	// What the .meta and the guess say, checked as numbers
	Fact :: struct {
		name:string,
		got, expected:i32,
	}
	facts := [?]Fact {
		{"loaded width", loaded.width, 12},
		{"loaded height", loaded.height, 20},
		{"loaded ppu", i32(loaded.pixels_per_unit), 10},
		{"loaded frames", loaded.frame_count, 4},
		{"guessed columns", guessed.guessed_meta.columns, 2},
		{"guessed rows", guessed.guessed_meta.rows, 1},
		{"guessed frames", guessed.guessed_meta.frame_count, 2},
		{"3DS override width", override.width, 8},
		{"3DS override ignores shared .meta: frames", override.frame_count, 1},
		{"3DS override ignores shared .meta: ppu", i32(override.pixels_per_unit), 1},
		{"font has glyphs (ascent above 0)", i32(font.ascent > 0), 1},
	}

	frames := 0
	for mb.is_running() {
		mb.poll_events()
		mb.render_start()
		mb.clear_background({0, 0, 1, 1})

		mb.camera_start(camera)
		mb.render_rectangle({-3, 0, 1}, {6, 6}, {0, 1, 0, 1}) // green, nearer, submitted first
		mb.render_rectangle({-5, 0, 0}, {6, 6}, {1, 0, 0, 1}) // red, farther, submitted second
		mb.render_rectangle({5, 0, 0.5}, {6, 6}, {1, 1, 1, 0.5}) // white, half see-through
		mb.render_rectangle({-9, 5, 0}, {1, 1}, {1, 1, 0, 1}) // yellow, top left
		mb.render_rectangle({9, -5, 0}, {1, 1}, {1, 0, 1, 1}) // magenta, bottom right
		// Orange quads through render_mesh, which culls BACK: one as built, one mirrored in x,
		// which turns its winding round so it faces away and must not be drawn
		mb.render_mesh(mb.mbi.sprite_mesh, linalg.matrix4_translate_f32({5, 4.5, 0}), {1, 0.5, 0, 1})
		mb.render_mesh(mb.mbi.sprite_mesh, linalg.matrix4_translate_f32({7, 4.5, 0}) * linalg.matrix4_scale_f32({-1, 1, 1}), {1, 0.5, 0, 1})
		mb.render_sprite(loaded_sprite)
		mb.render_sprite(made_sprite)
		mb.render_sprite(frame_sprite)
		mb.render_sprite(flipped_sprite)
		mb.render_text(font, text, text_position)
		mb.camera_end()

		mb.render_end()
		frames += 1

		if frames == 30 {
			width, height:u16
			pixels := ([^]u8)(ctru.gfxGetFramebuffer(.TOP, .LEFT, &width, &height))
			mb.print("check: framebuffer", width, "x", height)
			failures := 0
			for probe in probes {
				// The panel is 240 wide, 400 tall, scanned up from the player's bottom-left
				offset := (probe.x * int(width) + (int(width) - 1 - probe.y)) * 3
				got := [3]u8{pixels[offset + 2], pixels[offset + 1], pixels[offset + 0]} // stored B, G, R
				close := abs(int(got.r) - int(probe.expected.r)) <= 2 && abs(int(got.g) - int(probe.expected.g)) <= 2 && abs(int(got.b) - int(probe.expected.b)) <= 2
				// Only failures get a line: the console holds about 30, and the passes would push
				// the failures off the top
				if !close {
					failures += 1
					mb.print(fmt.tprintf("check: FAIL %s at (%d, %d): got %v, expected %v", probe.name, probe.x, probe.y, got, probe.expected))
				}
			}
			for fact in facts {
				if fact.got != fact.expected {
					failures += 1
					mb.print(fmt.tprintf("check: FAIL %s: got %d, expected %d", fact.name, fact.got, fact.expected))
				}
			}
			// The text: white pixels inside the box the shared measuring gives it (with 2 pixels of
			// slack for edges), and nothing but background in an 8 pixel ring around that
			text_size := mb.calculate_text_size(font, text)
			box_left := 60
			box_right := 60 + int(math.ceil(text_size.x * 20))
			box_top := 40 - int(math.ceil(font.ascent / font.pixels_per_unit * 20))
			box_bottom := 40 + int(math.ceil(font.descent / font.pixels_per_unit * 20))
			lit, stray := 0, 0
			for y in box_top - 8 ..< box_bottom + 8 {
				for x in box_left - 8 ..< box_right + 8 {
					offset := (x * int(width) + (int(width) - 1 - y)) * 3
					red := pixels[offset + 2]
					inside := x >= box_left - 2 && x < box_right + 2 && y >= box_top - 2 && y < box_bottom + 2
					if inside && red > 128 do lit += 1
					if !inside && red > 40 do stray += 1
				}
			}
			if lit == 0 {
				failures += 1
				mb.print("check: FAIL text drew nothing inside its box")
			}
			if stray > 0 {
				failures += 1
				mb.print(fmt.tprintf("check: FAIL text has %d pixels outside its box", stray))
			}
			mb.print(fmt.tprintf("check: text box %v..%v x %v..%v, %d lit", box_left, box_right, box_top, box_bottom, lit))
			mb.print(fmt.tprintf("check: %d probes, %d facts, text, failures %d", len(probes), len(facts), failures))
		}
	}
}
