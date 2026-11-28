#+build windows

package matchbox

/*
	Every axis here is worked out by hand (the cross products are in the comments), not by the formula under test, because a
	billboard that faces the wrong way round, or mirrored, looks fine on a symmetrical test sprite. The numbers are the ones
	examples/billboard-check asserts on the target itself
*/

import "core:math"
import "core:math/linalg"
import "core:sync"
import "core:testing"

@(private="file")
near :: proc(a:[3]f32, b:[3]f32, tolerance:f32 = 1e-4) -> bool {
	return linalg.length(a - b) < tolerance
}

// The three axes a billboard matrix turns the quad onto, and where it puts the origin
@(private="file")
columns :: proc(model:matrix[4, 4]f32) -> (right, up, normal, origin:[3]f32) {
	return model[0].xyz, model[1].xyz, model[2].xyz, model[3].xyz
}

// An axis-aligned look from `eye` at `at` (a perspective camera, 60 degrees)
@(private="file")
look :: proc(eye, at:[3]f32) -> Camera {
	return create_camera_3d(eye, at, 60)
}

@(test)
plane_billboard_is_the_camera_axes :: proc(t:^testing.T) {
	// Looking down -Z from (0, 0, 5): the camera's own axes are the world's, so the rotation is the identity
	model := calculate_billboard_matrix(look({0, 0, 5}, {0, 0, 0}), {3, 1, 0}, settings = {mode = .CAMERA_PLANE})
	right, up, normal, origin := columns(model)
	testing.expect(t, near(right, {1, 0, 0}))
	testing.expect(t, near(up, {0, 1, 0}))
	testing.expect(t, near(normal, {0, 0, 1}))
	testing.expect(t, near(origin, {3, 1, 0}))

	// From the +X side, looking down -X, the screen's right is world -Z (up x back = (0,1,0) x (1,0,0) ... right = (0,0,-1))
	right, up, normal, _ = columns(calculate_billboard_matrix(look({4, 0, 0}, {0, 0, 0}), {0, 0, 0}, settings = {mode = .CAMERA_PLANE}))
	testing.expect(t, near(right, {0, 0, -1}))
	testing.expect(t, near(up, {0, 1, 0}))
	testing.expect(t, near(normal, {1, 0, 0}))
}

@(test)
plane_billboard_ignores_where_the_sprite_is :: proc(t:^testing.T) {
	// Off to the side the plane billboard stays parallel to the screen; the position one turns toward the eye
	camera := look({0, 0, 5}, {0, 0, 0})
	_, _, plane, _ := columns(calculate_billboard_matrix(camera, {5, 0, 0}, settings = {mode = .CAMERA_PLANE}))
	_, _, toward, _ := columns(calculate_billboard_matrix(camera, {5, 0, 0}, settings = {mode = .CAMERA_POSITION}))
	testing.expect(t, near(plane, {0, 0, 1}))
	// From (5, 0, 0) the eye at (0, 0, 5) is the direction (-5, 0, 5): normalised (-0.70711, 0, 0.70711)
	testing.expect(t, near(toward, {-0.70710678, 0, 0.70710678}))
}

@(test)
upright_billboard_turns_about_y_only :: proc(t:^testing.T) {
	// Eye at (4, 0, 0), sprite at the origin: it faces +X. right = (0,1,0) x (1,0,0) = (0,0,-1)
	right, up, normal, _ := columns(calculate_billboard_matrix(look({4, 0, 0}, {0, 0, 0}), {0, 0, 0}))
	testing.expect(t, near(right, {0, 0, -1}))
	testing.expect(t, near(up, {0, 1, 0}))
	testing.expect(t, near(normal, {1, 0, 0}))

	// Eye raised to (0, 5, 5): it still stands straight and faces +Z. Leaning toward the camera would be CAMERA_POSITION
	right, up, normal, _ = columns(calculate_billboard_matrix(look({0, 5, 5}, {0, 0, 0}), {0, 0, 0}))
	testing.expect(t, near(right, {1, 0, 0}))
	testing.expect(t, near(up, {0, 1, 0}))
	testing.expect(t, near(normal, {0, 0, 1}))
}

@(test)
position_billboard_turns_toward_the_eye :: proc(t:^testing.T) {
	// Eye (0, 5, 5): normal (0, s, s) with s = 0.70711. right = (0,1,0) x normal = (s, 0, 0) -> (1,0,0).
	// up = normal x right = (0, s, -s)
	right, up, normal, _ := columns(calculate_billboard_matrix(look({0, 5, 5}, {0, 0, 0}), {0, 0, 0}, settings = {mode = .CAMERA_POSITION}))
	testing.expect(t, near(right, {1, 0, 0}))
	testing.expect(t, near(up, {0, 0.70710678, -0.70710678}))
	testing.expect(t, near(normal, {0, 0.70710678, 0.70710678}))
}

@(test)
orbiting_upright_billboard_always_faces_the_eye_and_never_leans :: proc(t:^testing.T) {
	for step in 0 ..< 12 {
		angle := f32(step) * math.TAU / 12
		eye := [3]f32{6 * math.cos(angle), 3, 6 * math.sin(angle)}
		right, up, normal, _ := columns(calculate_billboard_matrix(look(eye, {0, 0, 0}), {0, 0, 0}))
		testing.expectf(t, near(normal, {math.cos(angle), 0, math.sin(angle)}), "step %d normal %v", step, normal)
		testing.expectf(t, near(up, {0, 1, 0}), "step %d up %v", step, up)
		testing.expectf(t, abs(linalg.dot(right, normal)) < 1e-5, "step %d right %v", step, right)
		testing.expectf(t, near(linalg.cross(right, up), normal), "step %d handedness", step) // a mirrored quad would flip this
	}
}

@(test)
upright_billboard_survives_an_eye_straight_above :: proc(t:^testing.T) {
	// Directly over the sprite there is no heading to face. It takes the camera's, rather than NaN. This camera looks
	// forward and slightly down, so its horizontal back is +Z
	camera := look({0, 5, 0}, {0, 0, -1})
	right, up, normal, _ := columns(calculate_billboard_matrix(camera, {0, 0, 0}))
	testing.expect(t, near(normal, {0, 0, 1}))
	testing.expect(t, near(right, {1, 0, 0}))
	testing.expect(t, near(up, {0, 1, 0}))

	// And the position billboard, which has the same hole where the cross with +Y vanishes: finite and square-on
	model := calculate_billboard_matrix(camera, {0, 0, 0}, settings = {mode = .CAMERA_POSITION})
	right, up, normal, _ = columns(model)
	testing.expect(t, near(normal, {0, 1, 0}))
	testing.expect(t, near(right, {1, 0, 0}))
	testing.expect(t, near(up, {0, 0, -1})) // normal x right = (0,1,0) x (1,0,0) = (0,0,-1)
	testing.expect(t, !math.is_nan(model[0][0]))
}

@(test)
orthographic_camera_has_no_eye_to_turn_toward :: proc(t:^testing.T) {
	// A sprite far off to the side of an orthographic camera still faces straight at the screen
	camera := create_camera_3d({5, 0, 10}, {5, 0, 0})
	camera.projection = .ORTHOGRAPHIC
	camera.view_height = 10
	for mode in Billboard_Mode {
		_, _, normal, _ := columns(calculate_billboard_matrix(camera, {-20, 0, 0}, settings = {mode = mode}))
		testing.expectf(t, near(normal, {0, 0, 1}), "%v: %v", mode, normal)
	}
}

@(test)
roll_turns_the_quad_about_its_normal :: proc(t:^testing.T) {
	camera := look({0, 0, 5}, {0, 0, 0})
	// A quarter turn: right becomes up and up becomes -right
	right, up, normal, _ := columns(calculate_billboard_matrix(camera, {0, 0, 0}, settings = {mode = .CAMERA_PLANE}, roll = math.PI * 0.5))
	testing.expect(t, near(right, {0, 1, 0}))
	testing.expect(t, near(up, {-1, 0, 0}))
	testing.expect(t, near(normal, {0, 0, 1}))

	// Upright ignores it
	right, up, _, _ = columns(calculate_billboard_matrix(camera, {0, 0, 0}, roll = math.PI * 0.5))
	testing.expect(t, near(right, {1, 0, 0}))
	testing.expect(t, near(up, {0, 1, 0}))
}

@(test)
screen_size_keeps_the_pixels_the_same_at_any_distance :: proc(t:^testing.T) {
	// 64 pixels at depth 10, fov 60, a 240 pixel window: 2 * 10 * tan(30 deg) / 240 * 64 = 3.0792014 units
	// (the window height is passed in rather than read from mbi, which other tests change)
	view := calculate_camera_view_matrix(look({0, 0, 10}, {0, 0, 0}))
	per_pixel := calculate_billboard_units_per_pixel(view, 60, 240, {0, 0, 0})
	testing.expectf(t, abs(per_pixel * 64 - 3.0792014) < 1e-4, "64 pixels are %v units", per_pixel * 64)

	// Twice as far: twice as many units for the same pixels
	far := calculate_billboard_units_per_pixel(calculate_camera_view_matrix(look({0, 0, 20}, {0, 0, 0})), 60, 240, {0, 0, 0})
	testing.expectf(t, abs(far * 64 - 6.1584028) < 1e-4, "far: %v", far * 64)

	// Distance is along the view axis: the same depth, off to the side, is the same size
	side := calculate_billboard_units_per_pixel(view, 60, 240, {4, 0, 0})
	testing.expectf(t, abs(side * 64 - 3.0792014) < 1e-4, "side: %v", side * 64)

	// An orthographic camera has no distance to scale by
	testing.expect_value(t, calculate_billboard_units_per_pixel(view, 0, 240, {0, 0, 0}), 0)
}

// A 64 x 32 pixel image at 16 pixels to the unit: 4 x 2 units
@(private="file")
test_sprite :: proc() -> Sprite {
	return create_sprite(Texture{width = 64, height = 32, columns = 1, rows = 1, frame_count = 1, pixels_per_unit = 16})
}

// Runs `body` between a pretend camera_start and camera_end on `camera`, with the queue in temporary memory
@(private="file")
with_camera :: proc(t:^testing.T, camera:Camera, window_height:f32, body:proc(t:^testing.T)) {
	sync.mutex_lock(&render_queue_lock)
	defer sync.mutex_unlock(&render_queue_lock)
	// the camera tests set the view and the window under mbi_lock, so this holds that too (render_queue_lock first, as the others take them)
	sync.mutex_lock(&mbi_lock)
	defer sync.mutex_unlock(&mbi_lock)
	defer free_all(context.temp_allocator)

	// mbi is one global here, so put back every field this touches
	saved_active, saved_screen, saved_pixel, saved_view := mbi.camera_active, mbi.screen_pass, mbi.pixel_scale, mbi.view
	saved_fov, saved_height := mbi.camera_fov_y, mbi.camera_window_height
	saved_opaque, saved_transparent := mbi.opaque_items, mbi.transparent_items
	defer {
		mbi.camera_active, mbi.screen_pass, mbi.pixel_scale, mbi.view = saved_active, saved_screen, saved_pixel, saved_view
		mbi.camera_fov_y, mbi.camera_window_height = saved_fov, saved_height
		mbi.opaque_items, mbi.transparent_items = saved_opaque, saved_transparent
	}
	mbi.camera_active = true
	mbi.screen_pass = false
	mbi.pixel_scale = 0
	mbi.view = calculate_camera_view_matrix(camera)
	mbi.camera_fov_y = camera.fov_y if camera.projection == .PERSPECTIVE else 0
	mbi.camera_window_height = window_height
	mbi.opaque_items = make([dynamic]Render_Item, context.temp_allocator)
	mbi.transparent_items = make([dynamic]Render_Item, context.temp_allocator)
	body(t)
}

@(test)
queued_billboard_is_placed_by_its_pivot :: proc(t:^testing.T) {
	with_camera(t, look({4, 0, 0}, {0, 0, 0}), 240, proc(t:^testing.T) {
		sprite := test_sprite()
		sprite.position = {0, 0, 0}
		sprite.pivot = {0.5, 0} // stands on the floor
		render_billboard(sprite)

		model := mbi.opaque_items[0].model
		// Faces +X, so the sprite's right is world -Z: its right edge (local 0.5, 0) is 2 units down -Z at the feet
		testing.expect(t, near((model * [4]f32{0.5, -0.5, 0, 1}).xyz, {0, 0, -2}))
		testing.expect(t, near((model * [4]f32{0, -0.5, 0, 1}).xyz, {0, 0, 0})) // the pivot is the position
		testing.expect(t, near((model * [4]f32{0, 0.5, 0, 1}).xyz, {0, 2, 0})) // two units tall, straight up
		testing.expect_value(t, mbi.opaque_items[0].alpha_cutoff, 0.5)
		testing.expect_value(t, mbi.opaque_items[0].cull, Cull_Mode.NONE)
	})
}

@(test)
plane_billboard_matches_render_sprite_for_a_2d_camera :: proc(t:^testing.T) {
	with_camera(t, look({0, 0, 10}, {0, 0, 0}), 240, proc(t:^testing.T) {
		sprite := test_sprite()
		sprite.position = {1, 2, 0}
		sprite.pivot = {0.25, 0.75}
		sprite.scale = {1.5, 2}
		render_sprite(sprite)
		render_billboard(sprite, {mode = .CAMERA_PLANE})

		a, b := mbi.opaque_items[0], mbi.opaque_items[1]
		for column in 0 ..< 4 do testing.expectf(t, near(a.model[column].xyz, b.model[column].xyz), "column %d: %v vs %v", column, a.model[column], b.model[column])
		testing.expect_value(t, a.uv_rectangle, b.uv_rectangle)
	})
}

@(test)
blended_billboard_sorts_by_its_distance_and_flip_reads_the_image_backwards :: proc(t:^testing.T) {
	with_camera(t, look({0, 0, 10}, {0, 0, 0}), 240, proc(t:^testing.T) {
		sprite := test_sprite()
		sprite.position = {0, 0, 4} // six units from the camera
		sprite.flip_x = true
		render_billboard(sprite, mode = .BLENDED)

		testing.expect_value(t, len(mbi.opaque_items), 0)
		item := mbi.transparent_items[0]
		testing.expectf(t, abs(item.depth - 6) < 1e-4, "depth %v", item.depth)
		testing.expect_value(t, item.alpha_cutoff, 0)
		testing.expect_value(t, item.uv_rectangle, [4]f32{1, 0, 0, 1}) // u runs 1 -> 0
	})
}

@(test)
screen_size_billboard_is_pixels_times_scale :: proc(t:^testing.T) {
	with_camera(t, look({0, 0, 10}, {0, 0, 0}), 240, proc(t:^testing.T) {
		sprite := test_sprite() // 64 x 32 pixels
		sprite.scale = {2, 2}
		render_billboard(sprite, {mode = .CAMERA_PLANE, screen_size = true})

		right, up, _, _ := columns(mbi.opaque_items[0].model)
		// 3.0792014 units for 64 pixels at depth 10, twice that for scale 2 (the sprite's ppu is not used)
		testing.expectf(t, abs(linalg.length(right) - 6.1584028) < 1e-4, "width %v", linalg.length(right))
		testing.expectf(t, abs(linalg.length(up) - 3.0792014) < 1e-4, "height %v", linalg.length(up))
	})
}

@(test)
animation_offset_slides_along_the_billboards_own_axes :: proc(t:^testing.T) {
	with_camera(t, look({4, 0, 0}, {0, 0, 0}), 240, proc(t:^testing.T) {
		clip := create_animation_clip(test_sprite().texture, 0.1)
		clip.offset = {16, 8} // pixels: one unit right and half a unit up at 16 pixels to the unit
		animated := create_animated_sprite_from_clip(clip)
		animated.position = {0, 0, 0}
		render_animated_billboard(animated)

		_, _, _, origin := columns(mbi.opaque_items[0].model)
		// The quad faces +X, so its right is world -Z: one unit right is z = -1, not x = 1
		testing.expectf(t, near(origin, {0, 0.5, -1}), "origin %v", origin)
	})
}

// Where the eye is, read back out of mbi.view the way a game never does: the camera's position is not stored anywhere else
@(test)
every_mode_faces_the_eye_from_every_side_through_the_real_view :: proc(t:^testing.T) {
	// Eyes all the way round, high and low, some of them behind the sprite's first facing, looking at the sprite and
	// also looking well off to one side of it, since a billboard turns toward where the eye IS, not where it looks
	for height_step in 0 ..< 3 {
		for step in 0 ..< 16 {
			angle := f32(step) * math.TAU / 16 + 0.1
			eye := [3]f32{3 + 7 * math.cos(angle), 0.5 + f32(height_step) * 3, -2 + 7 * math.sin(angle)}
			sprite_position := [3]f32{3, 1.5, -2}
			for aim_step in 0 ..< 2 {
				aim := sprite_position if aim_step == 0 else sprite_position + {6 * math.cos(angle + 1.2), 0, 6 * math.sin(angle + 1.2)}
				camera := look(eye, aim)
				with_camera(t, camera, 240, proc(t:^testing.T) {})
				for mode in Billboard_Mode {
					check_one_mode(t, camera, eye, sprite_position, mode, angle)
				}
			}
		}
	}
}

@(private="file")
check_one_mode :: proc(t:^testing.T, camera:Camera, eye, sprite_position:[3]f32, mode:Billboard_Mode, angle:f32) {
	saved_view, saved_fov := mbi.view, mbi.camera_fov_y
	defer mbi.view, mbi.camera_fov_y = saved_view, saved_fov
	mbi.view = calculate_camera_view_matrix(camera) // what camera_start leaves behind
	mbi.camera_fov_y = camera.fov_y

	basis := calculate_billboard_basis(mbi.view, mbi.camera_fov_y, sprite_position, mode)
	to_eye := linalg.normalize(eye - sprite_position)
	view_right := [3]f32{mbi.view[0, 0], mbi.view[0, 1], mbi.view[0, 2]}
	view_up := [3]f32{mbi.view[1, 0], mbi.view[1, 1], mbi.view[1, 2]}

	// The front of the quad looks at the eye. For UPRIGHT only the heading counts, and the plane one follows the
	// camera's own back axis instead of the eye, so it is square to the screen wherever the sprite is
	view_back := [3]f32{mbi.view[2, 0], mbi.view[2, 1], mbi.view[2, 2]}
	switch mode {
	case .CAMERA_PLANE:
		testing.expectf(t, near(basis.normal, view_back), "plane at angle %v: normal %v, camera back %v", angle, basis.normal, view_back)
	case .CAMERA_POSITION:
		testing.expectf(t, near(basis.normal, to_eye), "position at angle %v: normal %v, eye direction %v", angle, basis.normal, to_eye)
	case .UPRIGHT:
		testing.expectf(t, linalg.dot(basis.normal, to_eye) > 0.3, "upright at angle %v: normal %v does not face the eye %v", angle, basis.normal, to_eye)
	}

	// What reaches the screen: the quad's right edge goes to the screen's right (not mirrored), and its top goes up it
	testing.expectf(t, linalg.dot(basis.right, view_right) > 0, "%v at angle %v: right %v is on the wrong side of the screen", mode, angle, basis.right)
	testing.expectf(t, linalg.dot(basis.up, view_up) > 0, "%v at angle %v: up %v is upside down", mode, angle, basis.up)
	testing.expectf(t, near(linalg.cross(basis.right, basis.up), basis.normal), "%v at angle %v: a mirrored basis", mode, angle)
}
