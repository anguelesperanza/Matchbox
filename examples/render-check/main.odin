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
				if !close do failures += 1
				mb.print(fmt.tprintf("check: %s %s at (%d, %d): got %v, expected %v", "ok  " if close else "FAIL", probe.name, probe.x, probe.y, got, probe.expected))
			}
			mb.print("check: failures", failures)
		}
	}
}
