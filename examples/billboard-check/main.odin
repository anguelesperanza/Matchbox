package billboard_check

/*
	G4's check: billboards in a perspective scene. Run from the repository root: `odin run examples/billboard-check`
	on PC, or `3ds_build.bat examples\billboard-check` / `vita_build.bat examples\billboard-check`.

	At start it runs a self-check of axes worked out by hand (the same ones matchbox/billboard_test.odin asserts on PC),
	on the target itself, and shows "checks: N passed, M failed" on the HUD.

	Controls (PC key / 3DS button / Vita button):
	- walk: WASD or arrows / left stick (circle pad) / d-pad
	- look: hold a mouse button and drag / right stick (C-stick) / drag on the touch screen. L and R zoom
	- C / B / Cross: roll the two screen-facing markers (the upright one must not roll)
	- R / X / Triangle: back to the start
	- Escape / SELECT quits

	What should show, walking round the three markers in the middle row (all the same picture: a blue square, a white
	arrow, a red corner at its top left):
	- left, CAMERA_PLANE: always square to the screen, the arrow pointing up the screen. Off to one side it is not
	  turned toward you, so it looks skewed in perspective
	- middle, CAMERA_POSITION: always square-on to you, even from above; the arrow follows the camera's up
	- right, UPRIGHT: turns only as you go round it. Seen from high above it is foreshortened, not tipped toward you
	No marker is ever mirrored (the red corner stays at the top left).
	Four trees stand upright whatever the camera does. A half see-through marker (blended) sits among them; the coin
	beside the trees spins, as an animated billboard. The far marker keeps its size on screen as you walk away from it
	(screen_size): it is 64 pixels wide whether it is near or far. That is window pixels, so on the 3DS (a 400 pixel
	wide top screen) it covers more than twice the share of the screen it does on the Vita (960 wide)

	The second self-check ("through the queue") does the real thing once, on the first frame: camera_start, render_billboard
	for every mode, and a read of the matrix that was queued, from eyes all round the sprite, behind it included and with
	the camera looking away from it. A billboard that faces the wrong way on a target shows up there as a failure
*/

import "core:fmt"
import "core:math"
import mb "../../matchbox"

SPEED :: 4

Check_Result :: struct {
	passed:int,
	failed:int,
	first_failure:string,
}

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

length :: proc(v:[3]f32) -> f32 {
	return math.sqrt(v.x * v.x + v.y * v.y + v.z * v.z)
}

// The columns of a billboard matrix: where the quad's right, up and normal point
axes :: proc(model:matrix[4, 4]f32) -> (right, up, normal:[3]f32) {
	return model[0].xyz, model[1].xyz, model[2].xyz
}

look :: proc(eye, at:[3]f32) -> mb.Camera {
	return mb.create_camera_3d(eye, at, 60)
}

// The hand-worked axes of billboard_test.odin, run here on whichever target this is
run_checks :: proc() -> Check_Result {
	result:Check_Result

	// The camera's own axes: looking down -Z they are the world's
	right, up, normal := axes(mb.calculate_billboard_matrix(look({0, 0, 5}, {0, 0, 0}), {3, 1, 0}, settings = {mode = .CAMERA_PLANE}))
	check(&result, near(right, {1, 0, 0}) && near(up, {0, 1, 0}) && near(normal, {0, 0, 1}), "plane, looking down -Z")

	// Looking down -X (eye at +X) the screen's right is world -Z
	right, up, normal = axes(mb.calculate_billboard_matrix(look({4, 0, 0}, {0, 0, 0}), {0, 0, 0}, settings = {mode = .CAMERA_PLANE}))
	check(&result, near(right, {0, 0, -1}) && near(up, {0, 1, 0}) && near(normal, {1, 0, 0}), "plane, looking down -X")

	// Off to the side the position billboard turns to the eye: (0,0,5) from (5,0,0) is (-1,0,1) over root two
	_, _, normal = axes(mb.calculate_billboard_matrix(look({0, 0, 5}, {0, 0, 0}), {5, 0, 0}, settings = {mode = .CAMERA_POSITION}))
	check(&result, near(normal, {-0.70710678, 0, 0.70710678}), "position, off to the side")

	// Upright, eye at (4,0,0): faces +X; right = (0,1,0) x (1,0,0) = (0,0,-1)
	right, up, normal = axes(mb.calculate_billboard_matrix(look({4, 0, 0}, {0, 0, 0}), {0, 0, 0}))
	check(&result, near(right, {0, 0, -1}) && near(up, {0, 1, 0}) && near(normal, {1, 0, 0}), "upright faces +X")

	// Upright, eye raised: it does not lean
	right, up, normal = axes(mb.calculate_billboard_matrix(look({0, 5, 5}, {0, 0, 0}), {0, 0, 0}))
	check(&result, near(right, {1, 0, 0}) && near(up, {0, 1, 0}) && near(normal, {0, 0, 1}), "upright does not lean")

	// Position, eye (0,5,5): normal (0,s,s), right (1,0,0), up (0,s,-s), s = 0.70711
	right, up, normal = axes(mb.calculate_billboard_matrix(look({0, 5, 5}, {0, 0, 0}), {0, 0, 0}, settings = {mode = .CAMERA_POSITION}))
	check(&result, near(right, {1, 0, 0}) && near(up, {0, 0.70710678, -0.70710678}) && near(normal, {0, 0.70710678, 0.70710678}), "position leans to the eye")

	// Straight above: finite, and facing the camera's own heading
	right, up, normal = axes(mb.calculate_billboard_matrix(look({0, 5, 0}, {0, 0, -1}), {0, 0, 0}))
	check(&result, near(normal, {0, 0, 1}) && near(right, {1, 0, 0}), "upright, eye straight above")

	// A quarter roll: right becomes up, up becomes -right. Upright ignores it
	right, up, _ = axes(mb.calculate_billboard_matrix(look({0, 0, 5}, {0, 0, 0}), {0, 0, 0}, settings = {mode = .CAMERA_PLANE}, roll = math.PI * 0.5))
	check(&result, near(right, {0, 1, 0}) && near(up, {-1, 0, 0}), "quarter roll")
	right, up, _ = axes(mb.calculate_billboard_matrix(look({0, 0, 5}, {0, 0, 0}), {0, 0, 0}, roll = math.PI * 0.5))
	check(&result, near(right, {1, 0, 0}) && near(up, {0, 1, 0}), "upright ignores roll")

	// Twelve places round it: always horizontal, toward the eye, and never mirrored
	round_ok := true
	for step in 0 ..< 12 {
		angle := f32(step) * math.TAU / 12
		eye := [3]f32{6 * math.cos(angle), 3, 6 * math.sin(angle)}
		right, up, normal = axes(mb.calculate_billboard_matrix(look(eye, {0, 0, 0}), {0, 0, 0}))
		cross := [3]f32{right.y * up.z - right.z * up.y, right.z * up.x - right.x * up.z, right.x * up.y - right.y * up.x}
		if !near(normal, {math.cos(angle), 0, math.sin(angle)}) || !near(up, {0, 1, 0}) || !near(cross, normal) do round_ok = false
	}
	check(&result, round_ok, "upright, twelve places round")

	// Orthographic: no eye, so the position billboard faces the screen however far off the side it is
	ortho := mb.create_camera_3d({5, 0, 10}, {5, 0, 0})
	ortho.projection = .ORTHOGRAPHIC
	ortho.view_height = 10
	_, _, normal = axes(mb.calculate_billboard_matrix(ortho, {-20, 0, 0}, settings = {mode = .CAMERA_POSITION}))
	check(&result, near(normal, {0, 0, 1}), "orthographic has no eye")

	// 64 pixels at depth 10, fov 60 is 2 * 10 * tan(30 degrees) / window height * 64 units, whichever window this is
	height := f32(mb.get_window_size()[1])
	expected := 2 * 10 * math.tan(f32(math.PI / 6)) / height * 64
	right, _, _ = axes(mb.calculate_billboard_matrix(look({0, 0, 10}, {0, 0, 0}), {0, 0, 0}, {64, 64}, {screen_size = true}))
	check(&result, abs(length(right) - expected) < 1e-3, "screen_size: 64 pixels at depth 10")
	right, _, _ = axes(mb.calculate_billboard_matrix(look({0, 0, 20}, {0, 0, 0}), {0, 0, 0}, {64, 64}, {screen_size = true}))
	check(&result, abs(length(right) - 2 * expected) < 1e-3, "screen_size: twice as far, twice the units")

	return result
}

// The three axes of what render_billboard queued, read back from the render queue
queued_axes :: proc() -> (right, up, normal:[3]f32) {
	// Unit lengths: the queued matrix carries the sprite's size too
	model := mb.mbi.opaque_items[len(mb.mbi.opaque_items) - 1].model
	right, up, normal = axes(model)
	return normalize(right), normalize(up), normalize(normal)
}

normalize :: proc(v:[3]f32) -> [3]f32 {
	return v / length(v)
}

// The real path, on the target: a camera_start, render_billboard and the matrix it queued, for every mode, from eyes all round
// the sprite. The expected axes come from the eye and the camera by plain geometry, not from the billboard code
run_queue_checks :: proc(sprite:mb.Sprite, result:^Check_Result) {
	sprite := sprite
	sprite.position = {3, 1.5, -2}
	sprite.scale = {0.01, 0.01} // a speck: the camera_end below draws it once, before the first real frame
	world_up := [3]f32{0, 1, 0}

	all_ok := [mb.Billboard_Mode]bool{.UPRIGHT = true, .CAMERA_POSITION = true, .CAMERA_PLANE = true}
	first_failure := ""
	for height in 0 ..< 3 {
		for step in 0 ..< 12 {
			angle := f32(step) * math.TAU / 12 + 0.1
			eye := [3]f32{3 + 7 * math.cos(angle), 0.5 + f32(height) * 3, -2 + 7 * math.sin(angle)}
			for aim_step in 0 ..< 2 {
				aim := sprite.position
				if aim_step == 1 do aim = sprite.position + {6 * math.cos(angle + 1.2), 0, 6 * math.sin(angle + 1.2)}
				camera := look(eye, aim)

				to_eye := normalize(eye - sprite.position)
				back := normalize(eye - aim) // the camera looks down its own -Z
				screen_right := normalize([3]f32{world_up.y * back.z - world_up.z * back.y, world_up.z * back.x - world_up.x * back.z, world_up.x * back.y - world_up.y * back.x})

				for mode in mb.Billboard_Mode {
					mb.camera_start(camera)
					mb.render_billboard(sprite, {mode = mode})
					right, up, normal := queued_axes()
					mb.camera_end()

					ok := true
					switch mode {
					case .CAMERA_POSITION: ok = near(normal, to_eye, 1e-2)
					case .CAMERA_PLANE: ok = near(normal, back, 1e-2) && near(right, screen_right, 1e-2)
					case .UPRIGHT:
						horizontal := normalize({to_eye.x, 0, to_eye.z})
						ok = near(normal, horizontal, 1e-2) && near(up, world_up, 1e-2)
					}
					// Never mirrored, and the right edge is on the screen's right
					if right.x * screen_right.x + right.y * screen_right.y + right.z * screen_right.z <= 0 do ok = false
					if !ok && all_ok[mode] {
						all_ok[mode] = false
						first_failure = fmt.tprintf("queue %v angle %.2f height %d aim %d", mode, angle, height, aim_step)
					}
				}
			}
		}
	}
	check(result, all_ok[.UPRIGHT], first_failure)
	check(result, all_ok[.CAMERA_POSITION], first_failure)
	check(result, all_ok[.CAMERA_PLANE], first_failure)
}

main :: proc() {
	mb.init("billboard check", 960, 544)

	checks := run_checks()
	mb.print(fmt.tprintf("billboard-check: %d passed, %d failed %s", checks.passed, checks.failed, checks.first_failure))

	floor := mb.create_plane_model(40)
	character := mb.create_cylinder_model(0.4, 1.7)
	font := mb.create_font(mb.DEFAULT_FONT_BYTES, 32)

	tree_texture := mb.load_texture("tree.png", .POINT)
	marker_texture := mb.load_texture("marker.png", .POINT)
	coin_texture := mb.load_texture("coin.png", .POINT)

	tree := mb.create_sprite(tree_texture)
	tree.pivot = {0.5, 0} // stands on the floor
	marker := mb.create_sprite(marker_texture)
	queue_checked := false
	coin := mb.create_animated_sprite_from_clip(mb.create_animation_clip(coin_texture, 0.12), 1)
	coin.pivot = {0.5, 0}

	start := [3]f32{0, 0, 8}
	player := start
	third := mb.create_third_person_camera(player, 0)
	rolling := false
	roll:f32 = 0

	for mb.is_running() {
		mb.poll_events()
		if mb.is_key_pressed(.ESCAPE) || mb.is_gamepad_pressed(.SELECT) do mb.stop_running()
		delta_time := mb.get_delta_time()

		if mb.is_key_pressed(.C) || mb.is_gamepad_pressed(.FACE_DOWN) do rolling = !rolling
		if mb.is_key_pressed(.R) || mb.is_gamepad_pressed(.FACE_UP) {
			player = start
			third = mb.create_third_person_camera(player, 0)
		}
		if rolling do roll += delta_time
		else do roll = 0

		mb.walk_third_person_camera(&third, &player, SPEED, delta_time)
		player.x = clamp(player.x, -19, 19)
		player.z = clamp(player.z, -19, 19)
		mb.update_animation(&coin, delta_time)

		mb.render_start()
		mb.clear_background({0.15, 0.17, 0.22, 1})

		// Once, on the first frame, the checks that go through camera_start and the render queue
		if queue_checked == false {
			queue_checked = true
			run_queue_checks(marker, &checks)
			mb.print(fmt.tprintf("billboard-check: through the queue, %d passed, %d failed %s", checks.passed, checks.failed, checks.first_failure))
		}

		mb.camera_start(third.camera)
		mb.render_model(floor, [3]f32{0, 0, 0}, tint = {0.4, 0.4, 0.45, 1})
		mb.render_model(character, mb.create_transform(player + {0, 0.85, 0}), {1, 0.9, 0.3, 1})

		// The three modes side by side, one picture, so the difference is the mode and nothing else
		marker.position = {-4, 1.5, 0}
		marker.rotation = roll
		mb.render_billboard(marker, {mode = .CAMERA_PLANE})
		marker.position = {0, 1.5, 0}
		mb.render_billboard(marker, {mode = .CAMERA_POSITION})
		// Live, from the queue: 1.00 when the middle marker faces the eye exactly, whatever the target and wherever you stand
		_, _, queued_normal := queued_axes()
		facing := queued_normal.x * normalize(third.camera.position - marker.position).x + queued_normal.y * normalize(third.camera.position - marker.position).y + queued_normal.z * normalize(third.camera.position - marker.position).z
		marker.position = {4, 1.5, 0}
		mb.render_billboard(marker, {mode = .UPRIGHT}) // rotation is ignored

		// Trees round the middle, upright whatever the camera does
		for position in ([?][3]f32{{-6, 0, -5}, {6, 0, -5}, {-6, 0, 5}, {6, 0, 5}}) {
			tree.position = position
			mb.render_billboard(tree)
		}

		// Half see-through, sorted by distance, and an animated one beside the trees
		ghost := marker
		ghost.position = {0, 1, -6}
		ghost.rotation = 0
		ghost.tint = {1, 1, 1, 0.5}
		mb.render_billboard(ghost, {mode = .CAMERA_POSITION}, .BLENDED)
		coin.position = {-3, 0, 5}
		mb.render_animated_billboard(coin)

		// Far away, and 64 pixels wide wherever you stand
		far := marker
		far.position = {0, 3, -16}
		far.rotation = 0
		far.scale = {2, 2} // 32 x 32 pixels of image, twice over
		mb.render_billboard(far, {mode = .CAMERA_POSITION, screen_size = true})
		mb.camera_end()

		lines := [?]string {
			fmt.tprintf("checks: %d passed, %d failed", checks.passed, checks.failed),
			checks.first_failure,
			"plane | position | upright",
			fmt.tprintf("roll %v [C / down]", "on" if rolling else "off"),
			fmt.tprintf("at %.1f %.1f", player.x, player.z),
			fmt.tprintf("middle faces the eye: %.2f", facing),
			fmt.tprintf("sticks %.2f %.2f | %.2f %.2f", mb.get_thumbstick_value(.LEFT_THUMBSTICK).x, mb.get_thumbstick_value(.LEFT_THUMBSTICK).y, mb.get_thumbstick_value(.RIGHT_THUMBSTICK).x, mb.get_thumbstick_value(.RIGHT_THUMBSTICK).y),
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

	mb.destroy(floor)
	mb.destroy(character)
	mb.destroy_font(font)
	mb.destroy_sprite(tree)
	mb.destroy_sprite(marker)
	mb.destroy_texture(coin_texture)
	mb.cleanup()
}
