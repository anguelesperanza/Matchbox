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

	**The character asset is not committed.** A rigged, animated humanoid is
	tens of megabytes and this repository does not carry one -- see
	`.gitignore`'s entry for `examples/animation-layers/assets/character.glb`.
	Copy any glTF/GLB with a skeleton and these five clips to that path to run
	this: `Idle_Subtle`, `Walk_Formal`, `Run_Female`, `Pistol_Aim_Neutral`,
	`Pistol_Reload`. It also needs a node named `spine_02` -- or change
	`UPPER_BODY_ROOT` below to whatever this model calls the equivalent joint,
	the one that sits above the hips and below the shoulders. Without a match
	there, the window still opens and the character still walks; R just does
	nothing, and the log says why.

	Things to try:

	  - **walk, then run.** Shift is the same modifier as `examples/third-person`;
	    the clip switches on the change, not every frame -- see
	    `update_locomotion`
	  - **hold R while walking or running.** The arms swap to `Pistol_Reload`
	    and the legs do not so much as flinch, because the layer is masked to
	    `spine_02` and up. Let go and it fades back out over a fifth of a
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

MODEL_PATH :: "assets/character.glb"

// Which way this particular file's rest pose faces, and how big it comes in
// -- properties of the asset, not of Matchbox. `third-person-game` (the game
// this rig was pulled from) uses the same two numbers for the same file.
MODEL_FORWARD :: math.PI * 0.5
MODEL_SCALE   :: f32(1.0)

// The node the upper-body mask is built from: everything at or above it
// layers, everything below stays on the base. See this file's own doc
// comment if your model calls the joint something else.
UPPER_BODY_ROOT :: "spine_02"

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
	// missing spine_02 or a missing clip logs into a context nothing reads.
	context.logger = mb.mbi.logger

	mb.set_escape_key(.UNKNOWN)

	model, err := mb.load_model(MODEL_PATH)
	if err != nil {
		fmt.eprintfln("could not load %s: %v", MODEL_PATH, err)
		fmt.eprintln("see this example's main.odin for what the file needs to contain")
		return
	}
	defer mb.destroy(&model)

	animator := mb.create_animator(model)
	defer mb.destroy(&animator)

	// Built once against this model's own skeleton, kept for the run, and
	// freed on the way out -- play_animation_layer copies it in rather than
	// keeping this slice, so nothing holds a reference past that call. See
	// `Animation_Layer`'s doc comment in animation3d.odin.
	upper_body_mask: []bool
	if spine, found := mb.node_index(model, UPPER_BODY_ROOT); found {
		upper_body_mask = mb.animation_mask_below(model, spine)
	} else {
		log.errorf("no node named %q on this model -- R will do nothing", UPPER_BODY_ROOT)
	}
	defer delete(upper_body_mask)

	state := Locomotion.IDLE
	mb.play_animation(&animator, model, LOCOMOTION_CLIPS[state])

	player_position := [3]f32{0, 0, 0}

	// TEMPORARY, with the draw below: B swaps the animator for nil so the
	// character renders in its bind pose. Delete both once the artifact it is
	// chasing is understood.
	bind_pose := false

	// TEMPORARY, with bind_pose: G hides the grid, H hides the blocks, J hides
	// the character. Between them they say which thing the artifact belongs
	// to, which is the question the bind pose left open.
	show_grid   := true
	show_blocks := true
	show_model  := true

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

		if mb.is_key_pressed(.B) do bind_pose   = !bind_pose
		if mb.is_key_pressed(.G) do show_grid   = !show_grid
		if mb.is_key_pressed(.H) do show_blocks = !show_blocks
		if mb.is_key_pressed(.J) do show_model  = !show_model
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
		if show_grid do mb.draw_grid(slices = 30, spacing = 2, color = {1, 1, 1, 0.20})

		if show_blocks {
			for block in blocks {
				mb.draw_cube(block.position, block.size, block.color)
				mb.draw_cube_wires(block.position, block.size, mb.BLACK)
			}
		}

		// Not frame 0 of `model.bounds_min.y`: a rest pose that is not also
		// the bind pose would put the feet somewhere other than y=0, and this
		// is the same correction `third-person-game` applies for the same file.
		ground_offset := [3]f32{0, -model.bounds_min.y * MODEL_SCALE, 0}

		/*
			TEMPORARY, for chasing a Vulkan-only skinning artifact -- delete
			with `bind_pose` and its key below once it has served its purpose.

			Passing nil draws the bind pose with an identity palette, so the
			animator, the clips, the layers and every matrix they produce are
			out of the picture. If the artifact survives that, nothing about
			the animation is causing it and the fault is in the vertex data or
			the draw itself; if it disappears, the palette is what to chase.
		*/
		posed: ^mb.Animator = &animator
		if bind_pose do posed = nil

		if show_model {
			mb.draw_model(model, mb.Transform{
				position = player_position + ground_offset,
				rotation = mb.facing_rotation(rig.facing - MODEL_FORWARD),
				scale    = {MODEL_SCALE, MODEL_SCALE, MODEL_SCALE},
			}, mb.WHITE, posed)
		}

		mb.end_drawing_3d()

		font := &mb.mbi.font
		mb.draw_text(font, "WASD to run, mouse to orbit, wheel to zoom, shift to sprint", 20, 40, mb.WHITE)
		mb.draw_text(font, "hold R to reload -- upper body only, legs keep moving", 20, 70, mb.WHITE)
		mb.draw_text(font,
			bind_pose ? "B: BIND POSE (no animator) -- temporary bug probe" \
			          : "B: bind pose off -- temporary bug probe",
			20, 130, bind_pose ? mb.ORANGE : mb.LIGHTGRAY)
		mb.draw_text(font,
			fmt.tprintf("G grid %v   H blocks %v   J character %v", show_grid, show_blocks, show_model),
			20, 160, mb.LIGHTGRAY)

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
	if mask == nil do return // spine_02 (or UPPER_BODY_ROOT) was not found; logged once in main

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
