package shader_3ds_check

// Checks game shaders on the 3DS (S8-3 and S8-4 of docs/game_shaders_3ds_plan.md): load_shader reads
// hologram, shield, toon, lava and haze from romfs (3ds_build.bat copied them from assets\3ds\shaders),
// and the frame is measured by reading the top screen's framebuffer back, as examples/render-check does.
// 3DS only: 3ds_build.bat examples\shader-3ds-check, run it in Azahar, and the results print on the
// bottom screen. Camera as render-check's: 12 units tall on 240 pixels, so 1 unit = 20 pixels, origin at
// the centre (200, 120), +y up. The clear colour is grey so that a see-through shader changes it.
//
// What each probe proves is written beside it. The two that need numbers worked out: a toon patch under
// the render-check sun comes out as the built-in's lit patch does, (61, 93, 155), because toon's plan is
// diffuse * colour and the patch is flat and faces the camera (no rim, no outline); and the same patch
// with lighting off must be the built-in's unlit (102, 153, 255), which only happens if the shader gave way

import "core:fmt"
import "core:math"

import mb "../../matchbox"
import "../../matchbox/o3dx/ctru"

Probe :: struct {
	name:     string,
	x, y:     int, // screen pixels as the player sees them, y down from the top
	expected: [3]u8,
}

GREY :: 128

// The panel is 240 wide, 400 tall, scanned up from the player's bottom-left
read_pixel :: proc(pixels: [^]u8, width, x, y: int) -> [3]u8 {
	offset := (x * width + (width - 1 - y)) * 3
	return {pixels[offset + 2], pixels[offset + 1], pixels[offset + 0]} // stored B, G, R
}

is_close :: proc(got, expected: [3]u8, slack: int) -> bool {
	return abs(int(got.r) - int(expected.r)) <= slack && abs(int(got.g) - int(expected.g)) <= slack && abs(int(got.b) - int(expected.b)) <= slack
}

// How far a pixel is from the clear colour, summed over the channels
distance_from_grey :: proc(pixel: [3]u8) -> int {
	return abs(int(pixel.r) - GREY) + abs(int(pixel.g) - GREY) + abs(int(pixel.b) - GREY)
}

main :: proc() {
	mb.init("shader 3ds check", 400, 240)
	defer mb.cleanup()
	mb.print("check: started (shader-3ds-check, S8-3)")

	camera := mb.create_camera_2d(12)

	// Between frames, as load_shader asks. A name with no files is ok = false, with the reason printed, not a stop
	_, missing_ok := mb.load_shader_checked("no_such_shader")
	hologram := mb.load_shader("hologram")
	shield := mb.load_shader("shield")
	toon := mb.load_shader("toon")
	lava := mb.load_shader("lava")
	haze := mb.load_shader("haze")
	has_shield := true

	texture := mb.load_texture("checks/quadrants.png", .POINT)
	defer mb.destroy_texture(texture)
	whole := [4]f32{0, 0, 12, 20}
	// Black tint: the built-in's MODULATE gives black, haze's REPLACE TEXTURE0 gives the picture
	haze_sprite := mb.create_sprite(texture, {0, -4.5, 0})
	haze_sprite.source = whole
	haze_sprite.tint = {0, 0, 0, 1}
	plain_sprite := haze_sprite
	plain_sprite.position = {1.5, -4.5, 0}

	turn := mb.calculate_rotation_axis_angle({1, 0, 0}, math.PI / 2) // a plane faces up; this stands it facing +Z
	small := mb.create_plane_model(1.2) // 24 pixels square
	big := mb.create_plane_model(3) // 60 pixels square
	small.parts[0].material = {shininess = 1, specular_strength = 0, lighting = .PER_PIXEL}
	patch_y: f32 = -4.4 // screen y 208
	big_y: f32 = 3 // screen y 60
	tint := [4]f32{0.4, 0.6, 1, 1}
	white := [4]f32{1, 1, 1, 1}
	mb.set_lights({mb.create_directional_light({-1, -2, -1})})

	mb.set_shader_value("heat", f32(1), lava)
	mb.set_shader_value("glitch", f32(1), hologram)

	probes := [?]Probe {
		// Lighting on: toon through the lighting unit gives the same patch the built-in does
		{"toon, lit patch", 60, 208, {61, 93, 155}},
		{"built-in lit patch (control)", 88, 208, {61, 93, 155}},
		// Lighting off: a shader that uses the unit gives way to the built-in, which draws it unlit
		{"toon, lighting off: the built-in draws it", 116, 208, {102, 153, 255}},
		{"lava, lighting off: the built-in draws it", 144, 208, {102, 153, 255}},
		// haze draws a sprite (it reads no normal) with REPLACE TEXTURE0; the control is the built-in
		{"haze sprite, top left", 194, 200, {255, 0, 0}},
		{"haze sprite, top right", 206, 200, {0, 255, 0}},
		{"haze sprite, bottom left", 194, 220, {255, 255, 0}},
		{"haze sprite, bottom right", 206, 220, {0, 255, 255}},
		{"built-in sprite, same tint: black (control)", 224, 200, {0, 0, 0}},
		{"background", 20, 120, {GREY, GREY, GREY}},
	}
	// Drawn by a shader whose colour is worked out per vertex from the clock and uniforms: checked as "not the background"
	moved := [?]Probe {
		{"hologram plane differs from the background", 80, 60, {}},
		{"lava plane differs from the background", 280, 60, {}},
	}

	failures := 0
	shield_before := [3]u8{}
	frames := 0
	for mb.is_running() {
		mb.poll_events()
		mb.render_start()
		mb.clear_background({0.5, 0.5, 0.5, 1})

		// Pass 1, lighting on: the lit patches and the lava plane, which reads the lighting unit
		mb.set_lighting({enabled = true, ambient = {0.2, 0.2, 0.2, 1}})
		mb.camera_start(camera)
		mb.set_shader(toon)
		mb.render_model(small, mb.create_transform({-7, patch_y, 0}, turn), tint)
		mb.set_shader({})
		mb.render_model(small, mb.create_transform({-5.6, patch_y, 0}, turn), tint)
		mb.set_shader(lava)
		mb.render_model(big, mb.create_transform({4, big_y, 0}, turn), white)
		mb.set_shader({})
		mb.camera_end()

		// Pass 2, lighting off: the two that fall back, and what needs no unit
		mb.set_lighting({enabled = false})
		mb.camera_start(camera)
		mb.set_shader(toon)
		mb.render_model(small, mb.create_transform({-4.2, patch_y, 0}, turn), tint)
		mb.set_shader(lava)
		mb.render_model(small, mb.create_transform({-2.8, patch_y, 0}, turn), tint)
		mb.set_shader(hologram)
		mb.render_model(big, mb.create_transform({-6, big_y, 0}, turn), white)
		if has_shield {
			mb.set_shader(shield)
			mb.render_model(big, mb.create_transform({-1, big_y, 0}, turn), white)
		}
		mb.set_shader(haze)
		mb.render_sprite(haze_sprite)
		mb.set_shader({})
		mb.render_sprite(plain_sprite)
		mb.camera_end()

		mb.render_end()
		frames += 1

		width, height: u16
		pixels := ([^]u8)(ctru.gfxGetFramebuffer(.TOP, .LEFT, &width, &height))

		if frames == 30 || frames == 60 {
			for probe in probes {
				got := read_pixel(pixels, int(width), probe.x, probe.y)
				if !is_close(got, probe.expected, 2) {
					failures += 1
					mb.print("check: FAIL", probe.name, "got", int(got.r), int(got.g), int(got.b), "expected", int(probe.expected.r), int(probe.expected.g), int(probe.expected.b))
				}
			}
			for probe in moved {
				got := read_pixel(pixels, int(width), probe.x, probe.y)
				mb.print("check:", probe.name, int(got.r), int(got.g), int(got.b))
				if distance_from_grey(got) < 15 {
					failures += 1
					mb.print("check: FAIL", probe.name)
				}
			}
			if missing_ok {
				failures += 1
				mb.print("check: FAIL load_shader_checked of a missing shader said ok")
			}
		}

		// The game uniform reaches the registers: the shield plane's centre with no hit, then with a hit whose
		// ring (age 0.606 at 3.5 units a second) is on the plane's corners. The shield's vertex program does not
		// read the clock, so nothing but the uniform can change the pixel
		if frames == 30 do shield_before = read_pixel(pixels, int(width), 180, 60)
		if frames == 31 do mb.set_shader_value("hit_a", [4]f32{-1, 3, 0, 0.606}, shield)
		if frames == 36 {
			after := read_pixel(pixels, int(width), 180, 60)
			change := abs(int(after.r) - int(shield_before.r)) + abs(int(after.g) - int(shield_before.g)) + abs(int(after.b) - int(shield_before.b))
			mb.print("check: shield centre", int(shield_before.r), int(shield_before.g), int(shield_before.b), "then", int(after.r), int(after.g), int(after.b))
			if change < 10 {
				failures += 1
				mb.print("check: FAIL set_shader_value hit_a did not change the shield")
			}
		}

		// Destroyed while it is the shader set and the pipeline last bound: the draws after it must carry on with the
		// built-ins, and the state must not point at a freed shader
		if frames == 40 {
			mb.set_shader(shield)
			mb.destroy_shader(shield)
			has_shield = false
			if mb.mbi.shader_state.current.data != nil {
				failures += 1
				mb.print("check: FAIL destroy_shader left the current shader set")
			}
		}
		if frames == 60 {
			mb.print(fmt.tprintf("check: %d probes, %d moved, shield set and destroyed, failures %d", len(probes), len(moved), failures))
		}
	}
	mb.destroy_shader(hologram)
	mb.destroy_shader(toon)
	mb.destroy_shader(lava)
	mb.destroy_shader(haze)
}
