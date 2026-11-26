package animation_check

/*
	G6's check: a skinned model animated, on every target. Run from the repository root (the assets are the shared
	ones in assets/), on PC with `odin run examples/animation-check`; on the handhelds with
	`3ds_build.bat examples\animation-check` / `vita_build.bat examples\animation-check`.

	It draws test_arm.glb, which `python tools/make_test_skinned_model.py` writes (tools/testdata/models) and which is
	copied into assets/models, git-ignored like all of assets: a ribbon of three joints bending in a chain,
	standing in an "armature" node that is not a joint. A different rig can be tried on the PC (and on a handheld
	built with it in assets/models) with `-define:MODEL=arms_rig.glb`.

	What should show, on a dark ground:
	- the ribbon on the left plays "Wave": it bends up 90 degrees at the first joint over a second and straightens
	  again, the far end growing wider as it goes (a scale on the last joint), with the whole ribbon stepping up
	  half a unit at the one-second mark (a STEP track)
	- the ribbon on the right is the same Model with an animator of its own. It plays "Wave" too until the right
	  face button (A on the 3DS, Circle on the Vita, P on the PC) changes its clip: it eases into "Bend", a fixed
	  45 degree bend, over a fifth of a second, and the next press eases back. The left one never notices
	- the left face button (Y on the 3DS, Square on the Vita, M) switches that fade off, so the change snaps
	- the bottom face button (B on the 3DS, Cross on the Vita, L) switches lighting off and on; the shape must
	  not change, only the shading
	- a model with no clips (a rig with no animation) stands in its bind pose

	The HUD has four lines: how many parts the model draws and the most joints one may use on this target; the left
	animator's clip, time and whether it is playing; the right one's; and "pose ok" while every palette it works
	out is a finite number. The ribbon is one draw, so the 3DS command buffer has nothing to do with it.
	SELECT or Escape quits
*/

import "core:fmt"
import "core:math"
import mb "../../matchbox"

MODEL :: #config(MODEL, "test_arm.glb")

main :: proc() {
	mb.init("animation check", 960, 544)

	model := mb.load_model(MODEL)
	font := mb.create_font(mb.DEFAULT_FONT_BYTES, 32)
	names := mb.get_animation_names(model, context.allocator)

	// Two characters wearing one Model. Made before the first frame: an animator allocates, and nothing is
	// allocated mid-frame on a console
	left := mb.create_animator(model)
	right := mb.create_animator(model)
	if len(names) > 0 {
		mb.play_animation_index(&left, model, 0)
		mb.play_animation_index(&right, model, 0)
	}
	right_clip := 0

	size := mb.calculate_model_size(model)
	center := mb.calculate_model_center(model)
	reach := max(size.x, size.y, 1)
	camera := mb.Camera {
		position = {center.x, center.y + reach * 0.2, center.z + reach * 3.2},
		target = {center.x, center.y + reach * 0.2, center.z},
		up = {0, 1, 0},
		fov_y = 50,
		near = 0.1,
		far = 200,
		zoom = 1,
		projection = .PERSPECTIVE,
	}
	sun := mb.create_directional_light({-0.4, -0.6, -1})
	mb.set_lights({sun})
	lighting_on := true
	mb.set_lighting({enabled = lighting_on, ambient = {0.25, 0.25, 0.25, 1}})

	for mb.is_running() {
		mb.poll_events()
		if mb.is_key_pressed(.ESCAPE) || mb.is_gamepad_pressed(.SELECT) do mb.stop_running()
		if mb.is_key_pressed(.L) || mb.is_gamepad_pressed(.FACE_DOWN) {
			lighting_on = !lighting_on
			mb.set_lighting({enabled = lighting_on, ambient = {0.25, 0.25, 0.25, 1}})
		}
		if mb.is_key_pressed(.M) || mb.is_gamepad_pressed(.FACE_LEFT) {
			right.blend.enabled = !right.blend.enabled
		}
		if (mb.is_key_pressed(.P) || mb.is_gamepad_pressed(.FACE_RIGHT)) && len(names) > 1 {
			right_clip = (right_clip + 1) % len(names)
			mb.play_animation_index(&right, model, right_clip)
		}

		delta_time := mb.get_delta_time()
		mb.update_animator(&left, model, delta_time)
		mb.update_animator(&right, model, delta_time)

		mb.render_start()
		mb.clear_background({0.1, 0.12, 0.16, 1})

		mb.camera_start(camera)
		// Side by side, one Model's width apart. The left plays on; the right is its own character
		spacing := size.x * 1.3
		mb.render_model(model, left, mb.create_transform({-spacing * 0.5 - center.x, 0, 0}), {0.9, 0.7, 0.4, 1})
		mb.render_model(model, right, mb.create_transform({spacing * 0.5 - center.x, 0, 0}), {0.5, 0.8, 1, 1})
		mb.camera_end()

		mb.screen_start()
		visible_min, visible_max := mb.calculate_visible_rectangle()
		margin :f32 = 0.2
		baseline := visible_max.y - margin - font.ascent / font.pixels_per_unit
		lines := [?]string {
			fmt.tprintf("parts %d  joints %d", len(model.parts), mb.mbi.skin_settings.joint_limit),
			describe_animator(model, left, "L"),
			describe_animator(model, right, "R"),
			"pose ok" if is_pose_finite(left) && is_pose_finite(right) else "POSE NOT FINITE",
		}
		for line in lines {
			mb.render_text(font, line, {visible_min.x + margin, baseline, 0})
			baseline -= mb.calculate_line_height(font)
		}
		mb.screen_end()

		mb.render_end()
	}

	mb.destroy_animator(&left)
	mb.destroy_animator(&right)
	mb.destroy(model)
	mb.destroy_font(font)
	mb.cleanup()
}

// One line: which clip, how far in, and whether it has finished (asked of the animator, not told by it)
describe_animator :: proc(model:mb.Model, animator:mb.Animator, label:string) -> string {
	if animator.clip < 0 || animator.clip >= len(model.animations) do return fmt.tprintf("%s no clip", label)
	return fmt.tprintf("%s %s %.1f %s", label, model.animations[animator.clip].name, animator.time, "playing" if animator.playing else "done")
}

// A character whose palette holds a NaN draws as a streak or nothing; this says so on screen instead of by eye
is_pose_finite :: proc(animator:mb.Animator) -> bool {
	for matrix_ in animator.pose.joint_data {
		for row in 0 ..< 3 {
			for column in 0 ..< 4 {
				value := matrix_[row, column]
				if math.is_nan(value) || math.is_inf(value) do return false
			}
		}
	}
	return true
}
