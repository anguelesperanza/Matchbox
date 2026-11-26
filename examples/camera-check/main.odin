package camera_check

/*
	G3's check: the first-person, third-person, drift and fixed cameras and tank / camera-relative steering, in
	one scene. Run from the repository root: `odin run examples/camera-check` on PC, or
	`3ds_build.bat examples\camera-check` / `vita_build.bat examples\camera-check`.

	At start it runs a self-check of numbers worked out by hand or in Python (view matrices, camera positions,
	the drift anchor, the fixed cuts, the steering directions) and shows "checks: N passed, M failed" on the HUD.
	That runs on the target itself, so on the 3DS it exercises the soft-float maths too.

	Controls (PC key / 3DS button / Vita button):
	- C / B / Cross: next camera: first person, third person, drift, fixed. The character stays where it was
	- T / Y / Square: tank or camera-relative steering (drift and fixed only; the first and third person cameras
	  steer by their own camera)
	- R / X / Triangle: put the character back at the start and snap the cameras onto it
	- walk: WASD or arrows / left stick (circle pad) / d-pad
	- look: hold a mouse button and drag / right stick (C-stick) / drag on the touch screen. L and R zoom the third
	  person camera; so does the wheel
	- Escape / SELECT quits

	What should show: a grey floor, six blocks of different heights, a yellow character (a cylinder with a red
	nose on the side it faces), and a lit scene. In the fixed camera the character crosses at x = 2..4 from one shot to
	another and the HUD says CUT for that frame. In drift the camera trails behind a walking character and
	stands still while it shuffles inside the dead zone.
*/

import "core:fmt"
import "core:math"
import mb "../../matchbox"

Camera_Mode :: enum {
	FIRST_PERSON,
	THIRD_PERSON,
	DRIFT,
	FIXED,
}

Block :: struct {
	position:[3]f32,
	size:[3]f32,
	tint:[4]f32,
}

SPEED :: 4

Check_Result :: struct {
	passed:int,
	failed:int,
	first_failure:string,
}

// One probe: `ok` is the comparison, `what` names it if it fails
check :: proc(result:^Check_Result, ok:bool, what:string) {
	if ok {
		result.passed += 1
		return
	}
	result.failed += 1
	if result.first_failure == "" do result.first_failure = what
}

near :: proc(a:[3]f32, b:[3]f32, tolerance:f32 = 1e-3) -> bool {
	d := a - b
	return d.x * d.x + d.y * d.y + d.z * d.z < tolerance * tolerance
}

// The same hand-worked values camera_3d_test.odin, camera_drift_test.odin, camera_fixed_test.odin and movement_test.odin assert on PC,
// run here on whichever target this is
run_checks :: proc() -> Check_Result {
	result:Check_Result
	DT :: f32(1.0 / 60.0)

	// Python: yaw = pitch = pi/6
	check(&result, near(mb.calculate_direction_from_angles(math.PI / 6, math.PI / 6), {-0.4330127, 0.5, -0.75}), "direction from angles")

	// A point 5 ahead of the eye is 5 down -Z in view space, looking down -Z and then turned a quarter left
	first := mb.create_first_person_camera(position = {0, 0, 0}, yaw = 0)
	ahead := mb.calculate_camera_view_matrix(first.camera) * [4]f32{0, 1.7, -5, 1}
	check(&result, near(ahead.xyz, {0, 0, -5}), "first person view, yaw 0")
	first = mb.create_first_person_camera(position = {0, 0, 0}, yaw = math.PI * 0.5)
	ahead = mb.calculate_camera_view_matrix(first.camera) * [4]f32{-5, 1.7, 0, 1}
	check(&result, near(ahead.xyz, {0, 0, -5}), "first person view, yaw 90")

	// Python: focus (0, 1.6, 0), distance 6, pitch -0.3
	third := mb.create_third_person_camera()
	check(&result, near(third.camera.position, {0, 3.3731212, 5.7320189}), "third person position")
	right := mb.create_third_person_camera(shoulder = .RIGHT)
	check(&result, near(right.camera.position - third.camera.position, {0.75, 0, 0}), "shoulder slides the camera")

	// Drift: the anchor stops a dead zone short of a character standing at x = 5
	drift := mb.create_drift_camera(yaw = 0, pitch = 0, distance = 5, dead_zone = 1.5, follow_speed = 3, focus_offset = {0, 0, 0})
	for _ in 0 ..< 300 do mb.follow_drift_camera(&drift, {5, 0, 0}, DT)
	check(&result, abs(drift.anchor.x - 3.5) < 0.01, "drift anchor stops 1.5 short")

	// Fixed: walking along X crosses the seam once
	rig := mb.create_fixed_camera()
	mb.add_fixed_camera_shot(&rig, {position = {-8, 5, 9}, target = {-8, 0, 0}, zone_min = {-20, -1, -20}, zone_max = {4, 4, 20}})
	mb.add_fixed_camera_shot(&rig, {position = {14, 6, 10}, aim = .TRACK, zone_min = {2, -1, -20}, zone_max = {20, 4, 20}})
	cuts := 0
	for step in 0 ..< 200 {
		mb.follow_fixed_camera(&rig, {f32(step) * 0.05, 0, 0}) // x from 0 to 9.95
		if rig.cut do cuts += 1
	}
	check(&result, cuts == 1 && rig.shot == 1, "fixed camera cuts once")

	// Steering: tank up walks along the heading; camera-relative up walks away from the camera, through a cut too
	north := mb.create_camera_3d({0, 5, 10}, {0, 0, 0})
	south := mb.create_camera_3d({0, 5, -10}, {0, 0, 0})
	tank := mb.create_character_controls(facing = math.PI * 0.5)
	mb.steer_character(&tank, {0, 1}, north, DT)
	check(&result, near(tank.move, {-1, 0, 0}), "tank up along the heading")
	tank = mb.create_character_controls()
	mb.steer_character(&tank, {1, 0}, north, DT)
	check(&result, abs(tank.facing + 3 * DT) < 1e-5, "tank right turns clockwise")
	relative := mb.create_character_controls(scheme = .CAMERA_RELATIVE)
	mb.steer_character(&relative, {0, 1}, north, DT)
	check(&result, near(relative.move, {0, 0, -1}), "camera-relative up, north camera")
	mb.steer_character(&relative, {0, 1}, south, DT)
	check(&result, near(relative.move, {0, 0, -1}), "held basis through a cut")

	angle:f32 = 3
	mb.turn_angle_toward(&angle, -3, 1, 0.1)
	check(&result, abs(angle - 3.1) < 1e-5, "turn the short way round")

	return result
}

main :: proc() {
	mb.init("camera check", 960, 544)

	checks := run_checks()
	mb.print(fmt.tprintf("camera-check: %d passed, %d failed %s", checks.passed, checks.failed, checks.first_failure))

	cube := mb.create_cube_model()
	cylinder := mb.create_cylinder_model(0.4, 1.7)
	floor := mb.create_plane_model(40)
	floor.parts[0].material = mb.Material{shininess = 16, specular_strength = 0}
	font := mb.create_font(mb.DEFAULT_FONT_BYTES, 32)

	mb.set_lights({mb.create_directional_light({-1, -2, -1})})
	mb.set_lighting({enabled = true, ambient = {0.3, 0.3, 0.3, 1}})

	blocks := [?]Block {
		{{-12, 1.5, -6}, {4, 3, 4}, {0.8, 0.5, 0.4, 1}},
		{{-4, 2.5, -10}, {5, 5, 3}, {0.5, 0.6, 0.8, 1}},
		{{6, 1, -8}, {3, 2, 6}, {0.5, 0.8, 0.5, 1}},
		{{14, 2, -4}, {4, 4, 4}, {0.8, 0.8, 0.4, 1}},
		{{-8, 1, 6}, {6, 2, 2}, {0.7, 0.5, 0.8, 1}},
		{{12, 1.5, 8}, {3, 3, 3}, {0.8, 0.6, 0.3, 1}},
	}

	// Two shots along X overlapping between x = 2 and 4, so standing on the seam does not strobe
	fixed := mb.create_fixed_camera()
	mb.add_fixed_camera_shot(&fixed, {position = {-8, 5, 9}, target = {-8, 0, 0}, zone_min = {-20, -1, -20}, zone_max = {4, 4, 20}})
	mb.add_fixed_camera_shot(&fixed, {position = {14, 6, 10}, aim = .TRACK, zone_min = {2, -1, -20}, zone_max = {20, 4, 20}})

	start := [3]f32{-6, 0, 2}
	player := start
	facing:f32 = 0
	mode := Camera_Mode.THIRD_PERSON
	controls := mb.create_character_controls()
	first := mb.create_first_person_camera(player, facing)
	third := mb.create_third_person_camera(player, facing)
	drift := mb.create_drift_camera(player, yaw = 0, pitch = -0.5, distance = 9, dead_zone = 2, follow_speed = 2.2)
	camera := third.camera

	// Seats every rig on the character, facing `facing`, so a switch of camera never jumps
	reseat :: proc(first:^mb.First_Person_Camera, third:^mb.Third_Person_Camera, drift:^mb.Drift_Camera, controls:^mb.Character_Controls, player:[3]f32, facing:f32) {
		first.look.yaw = facing
		mb.aim_first_person_camera(first, player)
		third.look.yaw = facing
		third.facing = facing
		mb.follow_third_person_camera(third, player, 0)
		drift.yaw = 0
		mb.snap_drift_camera(drift, player)
		controls.facing = facing
	}

	for mb.is_running() {
		mb.poll_events()
		if mb.is_key_pressed(.ESCAPE) || mb.is_gamepad_pressed(.SELECT) do mb.stop_running()
		delta_time := mb.get_delta_time()

		if mb.is_key_pressed(.C) || mb.is_gamepad_pressed(.FACE_DOWN) {
			mode = Camera_Mode((int(mode) + 1) % len(Camera_Mode))
			reseat(&first, &third, &drift, &controls, player, facing)
		}
		if mb.is_key_pressed(.T) || mb.is_gamepad_pressed(.FACE_LEFT) {
			controls.scheme = .CAMERA_RELATIVE if controls.scheme == .TANK else .TANK
		}
		if mb.is_key_pressed(.R) || mb.is_gamepad_pressed(.FACE_UP) {
			player = start
			reseat(&first, &third, &drift, &controls, player, facing)
		}

		switch mode {
		case .FIRST_PERSON:
			mb.walk_first_person_camera(&first, &player, SPEED, delta_time)
			camera = first.camera
			facing = first.look.yaw
		case .THIRD_PERSON:
			mb.walk_third_person_camera(&third, &player, SPEED, delta_time)
			camera = third.camera
			facing = third.facing
		case .DRIFT:
			mb.walk_character(&controls, &player, SPEED, drift.camera, delta_time)
			mb.follow_drift_camera(&drift, player, delta_time)
			camera = drift.camera
			facing = controls.facing
		case .FIXED:
			mb.walk_character(&controls, &player, SPEED, fixed.camera, delta_time)
			mb.follow_fixed_camera(&fixed, player)
			camera = fixed.camera
			facing = controls.facing
		}
		// Keep the floor underfoot
		player.x = clamp(player.x, -19, 19)
		player.z = clamp(player.z, -19, 19)

		mb.render_start()
		mb.clear_background({0.15, 0.17, 0.22, 1})

		mb.camera_start(camera)
		mb.render_model(floor, [3]f32{0, 0, 0}, tint = {0.4, 0.4, 0.45, 1})
		for block in blocks {
			mb.render_model(cube, mb.Transform{position = block.position, rotation = quaternion(w = 1, x = 0, y = 0, z = 0), scale = block.size}, block.tint)
		}
		if mode != .FIRST_PERSON {
			body := mb.create_transform(player + {0, 0.85, 0})
			mb.render_model(cylinder, body, {1, 0.9, 0.3, 1})
			nose := mb.Transform{position = player + {0, 1.3, 0} + mb.calculate_direction_from_angles(facing, 0) * 0.5, rotation = quaternion(w = 1, x = 0, y = 0, z = 0), scale = {0.2, 0.2, 0.2}}
			mb.render_model(cube, nose, {1, 0.2, 0.2, 1})
		}
		mb.camera_end()

		lines := [?]string {
			fmt.tprintf("checks: %d passed, %d failed", checks.passed, checks.failed),
			checks.first_failure,
			fmt.tprintf("camera %v [C / down]", mode),
			fmt.tprintf("steer %v [T / left]", controls.scheme) if mode == .DRIFT || mode == .FIXED else "steered by the camera",
			fmt.tprintf("at %.1f %.1f", player.x, player.z),
			"CUT" if mode == .FIXED && fixed.cut else (fmt.tprintf("shot %d", fixed.shot) if mode == .FIXED else ""),
		}

		mb.screen_start()
		visible_min, visible_max := mb.calculate_visible_rectangle()
		margin :f32 = 0.2
		baseline := visible_max.y - margin - font.ascent / font.pixels_per_unit
		for line in lines {
			mb.render_text(font, line, {visible_min.x + margin, baseline, 0})
			baseline -= mb.calculate_line_height(font)
		}
		mb.screen_end()

		mb.render_end()
	}

	mb.destroy(cube)
	mb.destroy(cylinder)
	mb.destroy(floor)
	mb.destroy_font(font)
	mb.cleanup()
}
