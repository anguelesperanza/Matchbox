package animation_layers_example

/*
	The third-person camera from `examples/third-person`, with a real skinned
	character standing in for the three-cube placeholder, and the point of the
	exercise: a reload that plays on the upper body while the legs keep
	walking underneath it.

	Everything except the character is a primitive shape, same as the example
	this is built from -- the ground is `draw_plane`, the grid is `draw_grid`,
	the blocks are `draw_cube`. `Model` and `Animator` are the two additions,
	and `play_animation_layer` is the one this example exists to show.

	**It also shows what a VRM is worth**, because it is loaded as two files
	that were never made for each other: `character.vrm` exactly as VRoid
	Studio exported it, and a glTF holding an animation set authored against
	an entirely different rig. `retarget_animations` joins them, and
	`vrm_bone` is what lets the mask below name "the chest" without knowing
	what this particular file calls that joint. See `vrm.md`.

	**Neither asset is committed.** A rigged humanoid and a clip library are
	tens of megabytes each and this repository carries neither -- see
	`.gitignore`'s entries for `examples/animation-layers/assets/`. To run it,
	put a VRM 0.0 or 1.0 character at `assets/character.vrm`, and at
	`assets/animations.glb` any glTF whose bones follow the Unreal naming
	convention (`pelvis`, `spine_01`, `upperarm_l`, ...) carrying these five
	clips: `Idle_Subtle`, `Walk_Formal`, `Run_Female`, `Pistol_Aim_Neutral`,
	`Pistol_Reload`. A clip set under some other convention needs its own
	name table passed to `retarget_animations` -- `UNREAL_BONE_NAMES` is only
	the default.

	Things to try:

	  - **walk, then run.** Shift is the same modifier as `examples/third-person`;
	    the clip switches on the change, not every frame -- see
	    `update_locomotion`
	  - **hold R while walking or running.** The arms swap to `Pistol_Reload`
	    and the legs do not so much as flinch, because the layer is masked to
	    the chest and up. Let go and it fades back out over a fifth of a
	    second rather than snapping
	  - **hold R while standing still**, then start walking without letting go.
	    The reload keeps playing on the arms the whole time the legs pick up a
	    walk cycle underneath it -- two clips, one character, and neither
	    waits for the other
	  - **F, 1/2/3, C, Q/E under `.CHARACTER` steering.** Exactly
	    `examples/third-person`'s camera controls; see that example's own doc
	    comment for what each one does

	See `animation3d.md` in the repository root for the design this
	demonstrates, and `games/third-person-game` (one directory up from this
	repository, not part of it) for the same layer wired into an actual game.
*/

import "core:fmt"
import "core:log"
import "core:math"

import mb "../../matchbox"

WALK_SPEED :: 6.0
RUN_SPEED  :: 11.0
TURN_KEY_SPEED :: 2.5
CAMERA_FLOOR :: 0.4
SHOULDER_DISTANCE :: 3.0

// The character, straight out of VRoid Studio, and a separate file holding
// nothing but the clips. A .vrm carries no animation of its own -- see
// `vrm.md` -- so the two arrive apart and are joined by `retarget_animations`
// below.
MODEL_PATH :: "assets/character.vrm"
CLIPS_PATH :: "assets/animations.glb"

/*
	A VRM faces -z once loaded: 1.0 files already do, and a 0.0 file is turned
	to match at import (`vrm.odin`). So this is knowledge about the *format*
	rather than about one particular export, which is why it can be named here
	rather than tuned by eye.

	Named through `Model_Facing` rather than written as an angle on purpose --
	`facing_rotation_of`'s own doc comment records that this very model was
	corrected by +PI/2 in one place and -PI/2 in another before anyone noticed
	one of them subtracted.
*/
MODEL_FACING :: mb.Model_Facing.NEG_Z
MODEL_SCALE  :: f32(1.0)

/*
	Where the upper-body mask starts. Asked of the file by role rather than by
	name: a VRM's humanoid block says which of its nodes is the chest, so this
	works on any VRM regardless of what that rig happens to call the joint.

	This used to be `UPPER_BODY_ROOT :: "spine_02"` with a comment telling the
	next person to go and find out what their own file called it. That is the
	line `vrm_bone` exists to delete.
*/
UPPER_BODY_BONE :: mb.Vrm_Bone.CHEST

Locomotion :: enum {
	IDLE,
	WALK,
	RUN,
}

LOCOMOTION_CLIPS := [Locomotion]string{
	.IDLE = "Idle_Subtle",
	.WALK = "Walk_Formal",
	.RUN  = "Run_Female",
}

RELOAD_CLIP          :: "Pistol_Reload"
RELOAD_FADE_SECONDS  :: 0.2

Block :: struct {
	position: [3]f32,
	size:     [3]f32,
	color:    [4]f32,
}

blocks := []Block{
	{{  5, 1.0,   3}, {1, 2, 1},   mb.LIME_GREEN},
	{{ -4, 1.5,  -2}, {2, 3, 2},   mb.CORNFLOWER_BLUE},
	{{  0, 1.0,  -8}, {6, 0.6, 1}, mb.RED},
	{{ -7, 1.0,   5}, {1, 2, 6},   mb.PUMPKIN_ORANGE},
}

main :: proc() {
	mb.init("Animation Layers", 1280, 720)
	defer mb.cleanup()

	// Matchbox's own logger, not this process's default -- otherwise a
	// missing bone or a missing clip logs into a context nothing reads.
	context.logger = mb.mbi.logger

	mb.set_escape_key(.UNKNOWN)

	model, err := mb.load_model(MODEL_PATH)
	if err != nil {
		fmt.eprintfln("could not load %s: %v", MODEL_PATH, err)
		fmt.eprintln("see this example's main.odin for what the file needs to contain")
		return
	}
	defer mb.destroy(&model)

	/*
		The clips, from a file that is not this character: a rig with the same
		bones in the same arrangement but its own rest pose, which is what
		`retarget_animations` corrects for. Nothing of the source survives the
		call except the motion -- the clips it leaves behind are ordinary
		`Model_Animation` data on `model`, so everything below this line is the
		same code it was when the character carried its own animation.
	*/
	clips, clips_err := mb.load_animation_source(CLIPS_PATH)
	if clips_err != nil {
		fmt.eprintfln("could not load %s: %v", CLIPS_PATH, clips_err)
		return
	}
	defer mb.destroy(&clips)

	if added := mb.retarget_animations(&model, clips); added == 0 {
		fmt.eprintln("no clips retargeted -- is the character a VRM, and do its bones match the table?")
		return
	}

	animator := mb.create_animator(model)
	defer mb.destroy(&animator)

	// Built once against this model's own skeleton, kept for the run, and
	// freed on the way out -- play_animation_layer copies it in rather than
	// keeping this slice, so nothing holds a reference past that call. See
	// `Animation_Layer`'s doc comment in animation3d.odin.
	upper_body_mask: []bool
	if chest, found := mb.vrm_bone(model, UPPER_BODY_BONE); found {
		upper_body_mask = mb.animation_mask_below(model, chest)
	} else {
		log.errorf("this model has no %v bone mapped -- R will do nothing", UPPER_BODY_BONE)
	}
	defer delete(upper_body_mask)

	state := Locomotion.IDLE
	mb.play_animation(&animator, model, LOCOMOTION_CLIPS[state])

	player_position := [3]f32{0, 0, 0}

	// Everything else -- angles, distance, framing, steering -- exactly as
	// `examples/third-person` sets it up. See that example for why these are
	// the defaults.
	rig := mb.create_third_person_camera(
		position = player_position,
		facing   = -math.PI * 0.5,
	)

	keep_off_floor := true
	centred_distance := rig.distance

	mb.set_cursor_locked(true)

	for mb.is_running() {
		mb.poll_events()
		dt := mb.get_delta_time()

		if mb.is_key_pressed(.ESCAPE) {
			if mb.is_cursor_locked() {
				mb.set_cursor_locked(false)
			} else {
				mb.mbi.running = false
			}
		}

		if !mb.is_cursor_locked() && mb.is_mouse_pressed(.LEFT) {
			mb.set_cursor_locked(true)
		}

		if mb.is_key_pressed(.C) do keep_off_floor = !keep_off_floor

		if mb.is_key_pressed(.F) {
			switch rig.steering {
			case .CAMERA:    rig.steering = .STRAFE
			case .STRAFE:    rig.steering = .CHARACTER
			case .CHARACTER: rig.steering = .CAMERA
			}
		}

		if mb.is_key_pressed(._1) do rig.shoulder = .CENTER
		if mb.is_key_pressed(._2) do rig.shoulder = .LEFT
		if mb.is_key_pressed(._3) do rig.shoulder = .RIGHT
		if mb.is_key_pressed(._1) || mb.is_key_pressed(._2) || mb.is_key_pressed(._3) {
			rig.distance = centred_distance if rig.shoulder == .CENTER else min(centred_distance, SHOULDER_DISTANCE)
		}

		running := false

		if mb.is_cursor_locked() {
			if rig.steering == .CHARACTER {
				if mb.is_key_held(.Q) do rig.facing -= TURN_KEY_SPEED * dt
				if mb.is_key_held(.E) do rig.facing += TURN_KEY_SPEED * dt
			}

			running = mb.is_key_held(.LSHIFT)
			speed: f32 = RUN_SPEED if running else WALK_SPEED

			mb.third_person_walk(&rig, &player_position, speed, dt)

			if keep_off_floor && rig.camera.position.y < CAMERA_FLOOR {
				focus := player_position + rig.focus_offset
				mb.camera3d_follow(&rig.camera, focus, rig.yaw, rig.pitch,
					clear_of_floor(focus, rig.pitch, rig.distance),
					rig.shoulder, rig.shoulder_offset)
			}

			if rig.shoulder == .CENTER do centred_distance = rig.distance
		}

		update_locomotion(&animator, model, &state, rig.move, running)
		update_reload_layer(&animator, model, upper_body_mask, dt)

		mb.update_animator(&animator, model, dt)

		mb.begin_drawing()
		mb.clear_background(mb.CORNFLOWER_BLUE)

		mb.begin_drawing_3d(rig.camera)

		mb.draw_plane({0, 0, 0}, {60, 60}, {0.42, 0.47, 0.40, 1})
		mb.draw_grid(slices = 30, spacing = 2, color = {1, 1, 1, 0.20})

		for block in blocks {
			mb.draw_cube(block.position, block.size, block.color)
			mb.draw_cube_wires(block.position, block.size, mb.BLACK)
		}

		// Not frame 0 of `model.bounds_min.y`: a rest pose that is not also
		// the bind pose would put the feet somewhere other than y=0, and this
		// is the same correction `third-person-game` applies for the same file.
		ground_offset := [3]f32{0, -model.bounds_min.y * MODEL_SCALE, 0}
		mb.draw_model(model, mb.Transform{
			position = player_position + ground_offset,
			rotation = mb.facing_rotation_of(rig.facing, MODEL_FACING),
			scale    = {MODEL_SCALE, MODEL_SCALE, MODEL_SCALE},
		}, mb.WHITE, &animator)

		mb.end_drawing_3d()

		font := &mb.mbi.font
		mb.draw_text(font, "WASD to run, mouse to orbit, wheel to zoom, shift to sprint", 20, 40, mb.WHITE)
		mb.draw_text(font, "hold R to reload -- upper body only, legs keep moving", 20, 70, mb.WHITE)

		if mb.is_cursor_locked() {
			mb.draw_text(font, "ESC releases the pointer", 20, 100, mb.WHITE)
		} else {
			mb.draw_text(font, "click to look again, ESC again to quit", 20, 100, mb.WHITE)
		}

		mb.draw_text(font, fmt.tprintf("state %v   layer weight %.2f", state, animator.layers[0].weight),
			20, 140, mb.WHITE)
		mb.draw_text(font, "F: camera steering    1/2/3: shoulder    C: keep camera off the floor",
			20, 170, mb.WHITE)

		mb.end_drawing()
	}

	mb.wait_idle()
}

/*
	Picks Idle, Walk or Run from this frame's move and speed, and starts the
	clip only on a change.

	`play_animation` is idempotent for the clip already playing (see
	`animation3d.md`'s step 0), so calling it every frame would not break
	anything -- but the change check is what makes this function say what it
	means: "the state changed", not "a frame happened".
*/
update_locomotion :: proc(animator: ^mb.Animator, model: mb.Model, state: ^Locomotion, move: [3]f32, running: bool) {
	want := Locomotion.IDLE
	switch {
	case move == {0, 0, 0}: want = .IDLE
	case running:           want = .RUN
	case:                   want = .WALK
	}

	if want == state^ do return
	state^ = want
	mb.play_animation(animator, model, LOCOMOTION_CLIPS[want])
}

/*
	Holding R plays the reload on the upper body while the legs carry on with
	whatever `update_locomotion` put on the base -- the case
	`play_animation_layer` exists for. Called every frame R is held; the
	layer's own idempotence (see `play_animation_layer`'s doc comment in
	animation3d.odin) is what keeps a held key from restarting the clip every
	frame, the same way `update_locomotion`'s change check relies on
	`play_animation`'s.

	The weight ramps over `RELOAD_FADE_SECONDS` rather than snapping straight
	to full strength, which is the three lines `animation3d.md` said a fade
	would cost the game rather than the library.
*/
update_reload_layer :: proc(animator: ^mb.Animator, model: mb.Model, mask: []bool, delta_time: f32) {
	if mask == nil do return // the chest bone was not mapped; logged once in main

	reloading := mb.is_key_held(.R)
	if reloading {
		mb.play_animation_layer(animator, model, 0, RELOAD_CLIP, mask, looping = false)
	}

	target: f32 = 1 if reloading else 0
	weight := animator.layers[0].weight

	if target > weight {
		weight = min(weight + delta_time / RELOAD_FADE_SECONDS, target)
	} else {
		weight = max(weight - delta_time / RELOAD_FADE_SECONDS, target)
	}
	mb.set_animation_layer_weight(animator, 0, weight)

	// Faded all the way out: drop it, so update_animator stops spending a
	// sample on a layer nobody can see.
	if !reloading && weight <= 0 do mb.stop_animation_layer(animator, 0)
}

// Identical to examples/third-person's -- see that file for why this exists
// instead of a ray cast.
clear_of_floor :: proc(focus: [3]f32, pitch, distance: f32) -> f32 {
	drop := math.sin(pitch)
	if drop <= 0 do return distance

	room := (focus.y - CAMERA_FLOOR) / drop
	return clamp(room, 0.5, distance)
}
