package game


import "../../matchbox"

// One combo string -- a light attack, a heavy attack, a crouch attack,
// whatever's bound to a given input. `cancel_frame_window` lives here rather
// than on Player because different chains reasonably want different feel: a
// heavy chain's window might be wider than a jab's.
Attack_Chain :: struct {
	stages:              [15]matchbox.Animation_Clip,
	cancel_frame_window: int,

	// Which chain_index to continue into once this chain's own stages run
	// out and a press is queued; -1 ends the combo here. Explicit rather
	// than "whatever's next in the array" -- chains that are only reachable
	// from a specific context (crouch, air) must not become the implicit
	// finisher of an unrelated chain just because they landed next to it.
	next_chain: int,

	// True for a chain that's really one move with sub-phases (run_kick's
	// begin/mid/end) rather than a mashable combo -- its stages advance on
	// their own once each finishes, no fresh press required.
	auto_advance: bool,

	// True for the two crouch attacks: finishing (with nothing queued) drops
	// back into .CROUCH, not .IDLE -- per shaia_attack.png they return to
	// the crouch pose, not standing.
	returns_to_crouch: bool,
}

Player_Animations :: struct {
	sheet: matchbox.Animation_Clip,
	idle: matchbox.Animation_Clip,
	walk: matchbox.Animation_Clip,
	run: matchbox.Animation_Clip,
	break_anim: matchbox.Animation_Clip,
	crouch:  matchbox.Animation_Clip,
	idle_to_crouch: matchbox.Animation_Clip,
	crouch_to_idle: matchbox.Animation_Clip,
	jump_begin: matchbox.Animation_Clip,
	jump_up:    matchbox.Animation_Clip,
	jump_rise:  matchbox.Animation_Clip,
	jump_fall:  matchbox.Animation_Clip,
	jump_land:  matchbox.Animation_Clip,
	jump_attack: matchbox.Animation_Clip,
	guard_standing: matchbox.Animation_Clip,
	guard_standing_end: matchbox.Animation_Clip,
	guard_crouch: matchbox.Animation_Clip,
	guard_crouch_end: matchbox.Animation_Clip,
	atk_chains: [8]Attack_Chain,
}

Player_Animations_State :: enum { IDLE,
	WALK,
	RUN,
	BREAK,
	CROUCH,
	JUMP,
	GUARD_STANDING,
	GUARD_CROUCHING,
	ATK_CHAIN,
}

Crouch_Phase :: enum {
	ENTER,
	HELD,
	EXIT,
}

Jump_Phase :: enum {
	BEGIN,
	UP,
	RISE,
	FALL,
	ATTACK,
	LAND,
}

Player :: struct {
	using animated:matchbox.Animated_Sprite,
	anim:Player_Animations,
	state:Player_Animations_State,
	chain_index:int,   // which Attack_Chain in atk_chains is playing
	combo_index:int,   // which stage within that chain
	queued_atk:bool,
	queued_knee:bool,
	run_speed:f32,
	gravity:f32,
	ground_y:f32,
	jump_phase:Jump_Phase,
	crouch_phase: Crouch_Phase,

	// Seconds left on a quick attack burst (see apply_attack_burst) -- while
	// this counts down, velocity_xy.x decays to 0 instead of being carried
	// indefinitely, so a standing-combo swing gets a brief push rather than
	// dragging the character the whole animation. Left at 0 for chains that
	// should keep whatever velocity_xy.x already was for as long as they play
	// (run_kick's sprint carry, jump's momentum carry).
	atk_burst_timer: f32,

	// All in world units (+Y up), per second, with `position` coming from the
	// Sprite. Not named `velocity`: Sprite's Body has a scalar `velocity`, and
	// through `using animated` the two would collide. `jump_force` is the Body's.
	velocity_xy: [2]f32,
	speed: f32,
	on_ground: bool,
}

// Per-frame update while player.state == .ATK_CHAIN. Owns advancing the
// combo: latches a fresh attack press once the current clip is within its
// cancel window, then -- once the clip hits its last frame -- either steps
// to the next stage (a press was latched and one exists) or hands control
// back to idle.
//
// chain_index is not re-read from input here -- it was fixed for the whole
// string when start_attack_chain kicked it off, so pressing the *other*
// chain's button mid-swing still only ever advances the one already playing.
attack_chain :: proc(player: ^Player, dt: f32) {
	atk_pressed  := matchbox.is_key_pressed(.F) || matchbox.is_gamepad_pressed(.FACE_LEFT)
	knee_pressed := matchbox.is_key_pressed(.G) || matchbox.is_gamepad_pressed(.FACE_UP)

	chain := player.anim.atk_chains[player.chain_index]
	clip  := chain.stages[player.combo_index]

	// The last `cancel_frame_window` frames of the stage. Asked of the sprite
	// rather than worked out from current_frame: every clip here is an
	// animation_range cut of one sheet, so frame_start is rarely 0, and
	// subtracting it by hand at each call site is the mistake that puts a
	// cancel window on the wrong frames of the wrong move.
	in_cancel_window := matchbox.is_animation_in_window(
		player.animated,
		clip.frame_count - chain.cancel_frame_window,
		clip.frame_count - 1,
	)

	if in_cancel_window {
		if atk_pressed {
			player.queued_atk = true
		}
		// Only Combination1-3 (chain_index 0, 1, 2) can cancel into Knee --
		// Combination4 and the other chains have no such arrow in the diagram.
		if knee_pressed && player.chain_index < 3 {
			player.queued_knee = true
		}
	}

	if !player.playing {
		next_stage_index := player.combo_index + 1

		// frame_count > 0 means that slot actually holds a clip -- lets
		// stages stay [15]Animation_Clip with only some of them filled in
		// without the chain reaching into a zeroed one.
		has_next_stage := next_stage_index < len(chain.stages) &&
		                   chain.stages[next_stage_index].frame_count > 0

		// auto_advance chains (run_kick) don't need a fresh press to move
		// through their own stages -- they're one move in three parts, not
		// a mashable combo.
		advance_stage := has_next_stage && (chain.auto_advance || player.queued_atk)

		// Run off the end of this chain's own stages -- see if chain.next_chain
		// picks up where this one left off. This is what makes chain one ->
		// chain two a single combo under one button: exhausting chain[0]'s
		// stages doesn't mean the combo is over, it means look at whatever
		// chain[0] names as its successor.
		next_chain_index := chain.next_chain
		has_next_chain := !has_next_stage &&
		                   next_chain_index >= 0 &&
		                   next_chain_index < len(player.anim.atk_chains) &&
		                   player.anim.atk_chains[next_chain_index].stages[0].frame_count > 0

		switch {
		case player.queued_knee:
			player.chain_index = 5   // Knee -- see atk_chains setup in main()
			player.combo_index = 0
			matchbox.switch_animation(player, player.anim.atk_chains[5].stages[0], looping = false)
		case advance_stage:
			player.combo_index = next_stage_index
			matchbox.switch_animation(player, chain.stages[player.combo_index], looping = false)
		case player.queued_atk && has_next_chain:
			player.chain_index = next_chain_index
			player.combo_index = 0
			// has_next_chain only ever fires for Combination1->2->3->4 (the
			// only chains with next_chain >= 0), so this is exactly "the
			// next F press in the standing combo" -- give it its own burst.
			apply_attack_burst(player)
			matchbox.switch_animation(player, player.anim.atk_chains[player.chain_index].stages[0], looping = false)
		case chain.returns_to_crouch:
			player.chain_index  = 0
			player.combo_index  = 0
			player.state        = .CROUCH
			player.crouch_phase = .HELD
			matchbox.switch_animation(player, player.anim.crouch)
		case:
			player.chain_index = 0
			player.combo_index = 0
			player.state = .IDLE
		}
		player.queued_atk  = false
		player.queued_knee = false
	}

	// A burst chain (see apply_attack_burst) decays to a stop; anything else
	// (run_kick, a walk/run carried into Knee) keeps whatever velocity_xy.x
	// already was for as long as it plays, same as jump_update.
	if player.atk_burst_timer > 0 {
		player.atk_burst_timer -= dt
		if player.atk_burst_timer <= 0 {
			player.atk_burst_timer = 0
			player.velocity_xy.x      = 0
		}
	}
	player.position.x += player.velocity_xy.x * dt

	matchbox.update_animation(player, dt)
}

// A small, short-lived forward push -- the standing combo's per-hit feel is
// a quick step, not the sustained carry a run or a jump gets. Signed by
// flip_x rather than any existing velocity_xy.x, so it's the same size and
// duration whether this swing started from a standstill or mid-walk.
apply_attack_burst :: proc(player: ^Player) {
	burst := player.speed * 0.5
	if player.flip_x {
		player.velocity_xy.x = -burst
	} else {
		player.velocity_xy.x = burst
	}
	player.atk_burst_timer = 0.1
}

// Enters .ATK_CHAIN playing the first stage of atk_chains[chain_index].
// Shared by every input that can start a chain, so adding a fourth chain
// later is one more call site here rather than a copy of these five lines.
start_attack_chain :: proc(player: ^Player, dt: f32, chain_index: int) {
	player.state       = .ATK_CHAIN
	player.chain_index = chain_index
	player.combo_index = 0
	player.queued_atk  = false
	matchbox.switch_animation(player, player.anim.atk_chains[chain_index].stages[0], looping = false)
	attack_chain(player, dt)
}

jump_update :: proc(player: ^Player, dt: f32) {
	attack_pressed := matchbox.is_key_pressed(.F) || matchbox.is_gamepad_pressed(.FACE_LEFT) ||
	                   matchbox.is_key_pressed(.G) || matchbox.is_gamepad_pressed(.FACE_UP)

	switch player.jump_phase {
	case .BEGIN:
		if !player.playing {
			player.jump_phase = .UP
			player.on_ground  = false
			player.velocity_xy.y = player.jump_force
			matchbox.switch_animation(player, player.anim.jump_up, looping = false)
		}
	case .UP:
		if !player.playing {
			player.jump_phase = .RISE
			matchbox.switch_animation(player, player.anim.jump_rise)
		}
	case .RISE:
		if attack_pressed {
			player.jump_phase = .ATTACK
			matchbox.switch_animation(player, player.anim.jump_attack, looping = false)
		} else if player.velocity_xy.y <= 0 {
			player.jump_phase = .FALL
			matchbox.switch_animation(player, player.anim.jump_fall)
		}
	case .FALL:
		if attack_pressed {
			player.jump_phase = .ATTACK
			matchbox.switch_animation(player, player.anim.jump_attack, looping = false)
		} else if player.position.y <= player.ground_y {
			player.position.y = player.ground_y
			player.velocity_xy.y = 0
			player.on_ground  = true
			player.jump_phase = .LAND
			matchbox.switch_animation(player, player.anim.jump_land, looping = false)
		}
	case .ATTACK:
		// Gravity keeps acting through the attack -- it doesn't freeze you
		// in the air -- so touching ground can happen mid-swing too.
		if player.position.y <= player.ground_y {
			player.position.y = player.ground_y
			player.velocity_xy.y = 0
			player.on_ground  = true
			player.jump_phase = .LAND
			matchbox.switch_animation(player, player.anim.jump_land, looping = false)
		} else if !player.playing {
			if player.velocity_xy.y > 0 {
				player.jump_phase = .RISE
				matchbox.switch_animation(player, player.anim.jump_rise)
			} else {
				player.jump_phase = .FALL
				matchbox.switch_animation(player, player.anim.jump_fall)
			}
		}
	case .LAND:
		if !player.playing {
			player.state     = .IDLE
		}
	}

	if !player.on_ground {
		player.velocity_xy.y -= player.gravity * dt
		player.position.y += player.velocity_xy.y * dt

		// Carries whatever horizontal speed was already set (see movement's
		// D/A-held blocks) unchanged through the whole jump -- no air
		// control, no air friction, just the momentum you had at takeoff.
		player.position.x += player.velocity_xy.x * dt
	}

	matchbox.update_animation(player, dt)
}

update_guard :: proc(player: ^Player, dt: f32) {
	guard_held := (matchbox.is_key_held(.V) || matchbox.is_gamepad_held(.LEFT_SHOULDER)) && player.on_ground

	if !guard_held {
		player.state     = .IDLE
		matchbox.update_animation(player, dt)
		return
	}

	matchbox.update_animation(player, dt)
}

start_standing_guard :: proc(player: ^Player, dt: f32) {
	player.state        = .GUARD_STANDING

	// The entry hands on to the hold on its own. That hand-off was the whole
	// of what Guard_Phase did -- a phase field, a switch and a `!playing`
	// check to sequence two clips -- so queueing it deletes all three.
	matchbox.switch_animation(player, player.anim.guard_standing, looping = false)
	matchbox.queue_animation(player, player.anim.guard_standing_end, true)

	update_guard(player, dt)
}

update_crouch_guard :: proc(player: ^Player, dt: f32) {
	guard_held := (matchbox.is_key_held(.V) || matchbox.is_gamepad_held(.LEFT_SHOULDER)) &&
	              (matchbox.is_key_held(.S) || matchbox.is_gamepad_held(.DPAD_DOWN)) &&
	              player.on_ground

	if !guard_held {
		player.state        = .CROUCH
		player.crouch_phase = .HELD
		matchbox.switch_animation(player, player.anim.crouch)
		matchbox.update_animation(player, dt)
		return
	}

	matchbox.update_animation(player, dt)
}

start_crouch_guard :: proc(player: ^Player, dt: f32) {
	player.state       = .GUARD_CROUCHING

	// As with the standing guard: the entry hands on to the hold by itself.
	matchbox.switch_animation(player, player.anim.guard_crouch, looping = false)
	matchbox.queue_animation(player, player.anim.guard_crouch_end, true)

	update_crouch_guard(player, dt)
}

// Owns .CROUCH end to end: the enter/hold/exit pose cycle, and -- since
// crouch-attack and crouch-guard both only make sense once actually
// crouched -- the F/G/V presses that branch out of the held pose.
crouch_update :: proc(player: ^Player, dt: f32) {
	if player.crouch_phase == .HELD {
		if matchbox.is_key_pressed(.F) || matchbox.is_gamepad_pressed(.FACE_LEFT) {
			start_attack_chain(player, dt, 4)   // crouch_attack1
			return
		}
		if matchbox.is_key_pressed(.G) || matchbox.is_gamepad_pressed(.FACE_UP) {
			start_attack_chain(player, dt, 6)   // crouch_attack2
			return
		}
		if matchbox.is_key_pressed(.V) || matchbox.is_gamepad_pressed(.LEFT_SHOULDER) {
			start_crouch_guard(player, dt)
			return
		}
	}

	switch player.crouch_phase {
	case .ENTER:
		if !player.playing {
			player.crouch_phase = .HELD
			matchbox.switch_animation(player, player.anim.crouch)
		}
	case .HELD:
		crouch_held := (matchbox.is_key_held(.S) || matchbox.is_gamepad_held(.DPAD_DOWN)) && player.on_ground
		if !crouch_held {
			player.crouch_phase = .EXIT
			matchbox.switch_animation(player, player.anim.crouch_to_idle, looping = false)
		}
	case .EXIT:
		if !player.playing {
			player.state     = .IDLE
		}
	}

	matchbox.update_animation(player, dt)
}

start_crouch :: proc(player: ^Player, dt: f32) {
	player.state        = .CROUCH
	player.crouch_phase = .ENTER
	player.velocity_xy.x   = 0   // no crouch-walk -- don't let a run carry into a crouch-attack
	matchbox.switch_animation(player, player.anim.idle_to_crouch, looping = false)
	crouch_update(player, dt)
}

// The break that follows stopping from a run (see movement's D/A release
// handling) -- one-shot, then back to idle.
break_update :: proc(player: ^Player, dt: f32) {
	if !player.playing {
		player.state     = .IDLE
	}
	matchbox.update_animation(player, dt)
}

start_break :: proc(player: ^Player, dt: f32) {
	player.state      = .BREAK
	player.velocity_xy.x = 0   // the run stopped -- don't let it carry into a post-break attack
	matchbox.switch_animation(player, player.anim.break_anim, looping = false)
	break_update(player, dt)
}

start_jump :: proc(player: ^Player, dt: f32) {
	player.state      = .JUMP
	player.jump_phase = .BEGIN
	matchbox.switch_animation(player, player.anim.jump_begin, looping = false)
	jump_update(player, dt)
}

movement :: proc(player:^Player, dt:f32) {

	// attack_chain owns every frame of the combo -- movement below only
	// ever starts one from IDLE/WALK/CROUCH.
	if player.state == .ATK_CHAIN {
		attack_chain(player, dt)
		return
	}

	if player.state == .JUMP {
		jump_update(player, dt)
		return
	}

	if player.state == .GUARD_STANDING {
		update_guard(player, dt)
		return
	}

	if player.state == .GUARD_CROUCHING {
		update_crouch_guard(player, dt)
		return
	}

	if player.state == .CROUCH {
		crouch_update(player, dt)
		return
	}

	if player.state == .BREAK {
		break_update(player, dt)
		return
	}

	// Held. Sets velocity_xy.x (not just position) so jump_update can carry
	// whatever horizontal speed was active the instant the jump starts.
	if (matchbox.is_key_held(.D) || matchbox.is_gamepad_held(.DPAD_RIGHT)) && player.on_ground {

		if matchbox.is_key_held(.SHIFT) || matchbox.is_gamepad_held(.RIGHT_SHOULDER) {

			if player.state != .RUN {
				player.flip_x = false
				player.state = .RUN
			}

			player.velocity_xy.x = player.speed + player.run_speed

		} else {
			if player.state != .WALK {
				player.flip_x = false
				player.state = .WALK
			}
			player.velocity_xy.x = player.speed
		}
		player.position.x += player.velocity_xy.x * dt
	}

	if (matchbox.is_key_held(.A) || matchbox.is_gamepad_held(.DPAD_LEFT)) && player.on_ground {

			if matchbox.is_key_held(.SHIFT) || matchbox.is_gamepad_held(.RIGHT_SHOULDER) {

				if player.state != .RUN {
					player.flip_x = true
					player.state = .RUN
				}

				player.velocity_xy.x = -(player.speed + player.run_speed)

			} else {
				if player.state != .WALK {
					player.flip_x = true
					player.state = .WALK
			}
			player.velocity_xy.x = -player.speed
		}
		player.position.x += player.velocity_xy.x * dt
	}



	// Released. Stopping from RUN goes through BREAK first; stopping from
	// WALK (or anywhere else) drops straight to idle.
	if (matchbox.is_key_released(.D) || matchbox.is_gamepad_released(.DPAD_RIGHT)) {
		if player.state == .RUN {
			start_break(player, dt)
			return
		}
		player.state      = .IDLE
		player.velocity_xy.x = 0
	}

	if (matchbox.is_key_released(.A) || matchbox.is_gamepad_released(.DPAD_LEFT)) {
		if player.state == .RUN {
			start_break(player, dt)
			return
		}
		player.state      = .IDLE
		player.velocity_xy.x = 0
	}

	// F/West starts the standing combo, or run_kick while running.
	// (Crouch's own F/G/V handling lives in crouch_update, since it's only
	// reachable once player.state == .CROUCH.)
	if (matchbox.is_key_pressed(.F) || matchbox.is_gamepad_pressed(.FACE_LEFT)) {
		if player.state == .RUN {
			start_attack_chain(player, dt, 7)   // run_kick -- already carries running speed
		} else {
			apply_attack_burst(player)
			start_attack_chain(player, dt, 0)   // Combination1
		}
		return
	}

	// G/North starts Knee directly from idle/walk/run.
	if (matchbox.is_key_pressed(.G) || matchbox.is_gamepad_pressed(.FACE_UP)) {
		start_attack_chain(player, dt, 5)
		return
	}

	if (matchbox.is_key_pressed(.SPACE) || matchbox.is_gamepad_pressed(.FACE_DOWN)) && player.on_ground {
		start_jump(player, dt)
		return
	}

	if (matchbox.is_key_pressed(.V) || matchbox.is_gamepad_pressed(.LEFT_SHOULDER)) && player.on_ground {
		start_standing_guard(player, dt)
		return
	}

	if (matchbox.is_key_pressed(.S) || matchbox.is_gamepad_pressed(.DPAD_DOWN)) && player.on_ground {
		start_crouch(player, dt)
		return
	}

	#partial switch player.state {
		case .IDLE:
			matchbox.switch_animation(player, player.anim.idle)
		case .WALK:
			matchbox.switch_animation(player, player.anim.walk)
		case .RUN:
			matchbox.switch_animation(player, player.anim.run)
	}

	matchbox.update_animation(player, dt)
}

// The original numbers were pixels, y down, for a sprite 3x its 256 pixel frames.
// One world unit is now 256 pixels (the sheet's ppu), so those numbers are kept
// and multiplied by PX instead of being worked out again.
PX :: 1.0 / 256.0

// The feet are 11 pixels above the bottom of each 256 pixel frame. Pivoting
// there puts the feet, not the empty margin, on `position`.
FEET_PIVOT_Y :: 11.0 / 256.0

main :: proc() {

	matchbox.init("Game", 1920, 1080)

	// The sheet is made by tools/sheetpack from the 169 frames, and its .meta
	// gives the frame count and 256 pixels per unit
	sheet_texture := matchbox.load_texture("shia.png", .POINT)

	player:Player
	player.anim.sheet = matchbox.create_animation_clip(sheet_texture, 0.1)

	player.run_speed = 800 * PX

	player.anim.idle = matchbox.animation_range(player.anim.sheet, 67, 74, 0.1)
	player.anim.walk = matchbox.animation_range(player.anim.sheet, 95, 106, 0.1)
	player.anim.run = matchbox.animation_range(player.anim.sheet, 113, 118, 0.1)
	player.anim.break_anim = matchbox.animation_range(player.anim.sheet, 119, 123, 0.1)

	// 85 is the held crouch pose (common_01_idle_crouch); 83-84 and 86-87 are
	// the transitions either side of it (common_01_crouch_to_idle/idle_to_crouch) --
	// per shaia_common01.png, crouch itself is a single frame, not 83.
	player.anim.crouch         = matchbox.animation_range(player.anim.sheet, 85, 85, 0.1)
	player.anim.idle_to_crouch = matchbox.animation_range(player.anim.sheet, 86, 87, 0.1)
	player.anim.crouch_to_idle = matchbox.animation_range(player.anim.sheet, 83, 84, 0.1)

	player.anim.jump_begin  = matchbox.animation_range(player.anim.sheet, 129, 129, 0.1)
	player.anim.jump_up     = matchbox.animation_range(player.anim.sheet, 133, 133, 0.1)
	player.anim.jump_rise   = matchbox.animation_range(player.anim.sheet, 124, 128, 0.1)
	player.anim.jump_fall   = matchbox.animation_range(player.anim.sheet, 130, 132, 0.1)
	player.anim.jump_land   = matchbox.animation_range(player.anim.sheet, 134, 137, 0.1)
	player.anim.jump_attack = matchbox.animation_range(player.anim.sheet, 60, 66, 0.1)

	player.anim.guard_standing     = matchbox.animation_range(player.anim.sheet, 138, 139, 0.1)
	player.anim.guard_standing_end = matchbox.animation_range(player.anim.sheet, 139, 139, 0.1)
	player.anim.guard_crouch       = matchbox.animation_range(player.anim.sheet, 140, 141, 0.1)
	player.anim.guard_crouch_end   = matchbox.animation_range(player.anim.sheet, 141, 141, 0.1)

	// The standing combo: four chains, each contributing one hit, chained
	// F -> F -> F -> F via next_chain. See anim_list.txt.
	player.anim.atk_chains[0].stages[0] = matchbox.animation_range(player.anim.sheet, 0, 5, 0.1)
	player.anim.atk_chains[0].cancel_frame_window = 3
	player.anim.atk_chains[0].next_chain = 1

	player.anim.atk_chains[1].stages[0] = matchbox.animation_range(player.anim.sheet, 6, 11, 0.1)
	player.anim.atk_chains[1].cancel_frame_window = 3
	player.anim.atk_chains[1].next_chain = 2

	player.anim.atk_chains[2].stages[0] = matchbox.animation_range(player.anim.sheet, 12, 18, 0.1)
	player.anim.atk_chains[2].cancel_frame_window = 3
	player.anim.atk_chains[2].next_chain = 3

	// Combination4 is all 11 frames (0401-0411) -- was truncated to 19,24.
	player.anim.atk_chains[3].stages[0] = matchbox.animation_range(player.anim.sheet, 19, 29, 0.1)
	player.anim.atk_chains[3].cancel_frame_window = 3
	player.anim.atk_chains[3].next_chain = -1   // last hit of the standing combo

	// Crouch attacks: two standalone one-shots (F and G respectively, see
	// crouch_update), each dropping back into .CROUCH rather than .IDLE --
	// per shaia_attack.png, both are reached directly from "crouch", not
	// chained into each other.
	player.anim.atk_chains[4].stages[0] = matchbox.animation_range(player.anim.sheet, 45, 50, 0.1)

	// The art for this clip is drawn about 33 pixels left of the crouch it returns
	// to, so without this the character jumps right when the attack ends. Frame 50
	// is further out (65 pixels), so it is still a little off. The feet are also
	// about 6 pixels lower in these frames than in the crouch, hence the y
	player.anim.atk_chains[4].stages[0].offset = {33, 6}
	player.anim.atk_chains[4].cancel_frame_window = 3
	player.anim.atk_chains[4].next_chain = -1
	player.anim.atk_chains[4].returns_to_crouch = true

	// Knee: reachable directly from idle (G) and as a cancel out of
	// Combination1-3 (see attack_chain's queued_knee handling).
	player.anim.atk_chains[5].stages[0] = matchbox.animation_range(player.anim.sheet, 30, 35, 0.1)
	player.anim.atk_chains[5].cancel_frame_window = 3
	player.anim.atk_chains[5].next_chain = -1

	player.anim.atk_chains[6].stages[0] = matchbox.animation_range(player.anim.sheet, 51, 59, 0.1)

	// Frames 51 to 58 are drawn about 26 pixels right of the crouch; frame 59 is
	// already in place, so it ends up a little left instead
	player.anim.atk_chains[6].stages[0].offset = {-26, 0}
	player.anim.atk_chains[6].cancel_frame_window = 3
	player.anim.atk_chains[6].next_chain = -1
	player.anim.atk_chains[6].returns_to_crouch = true

	// run_kick: one move in three parts (begin/kick/end), triggered by F
	// while running -- auto_advance means no re-press is needed between them.
	player.anim.atk_chains[7].stages[0] = matchbox.animation_range(player.anim.sheet, 38, 39, 0.1)
	player.anim.atk_chains[7].stages[1] = matchbox.animation_range(player.anim.sheet, 36, 37, 0.1)
	player.anim.atk_chains[7].stages[2] = matchbox.animation_range(player.anim.sheet, 40, 44, 0.1)
	player.anim.atk_chains[7].next_chain    = -1
	player.anim.atk_chains[7].auto_advance  = true

	player.state = .IDLE

	player.animated = matchbox.create_animated_sprite_from_clip(player.anim.idle, 3)
	player.pivot = {0.5, FEET_PIVOT_Y}
	player.position = {0, 0, 1}   // x, y (up), z (the layer)
	player.speed = 200 * PX
	player.on_ground = true
	player.ground_y = player.position.y
	player.jump_force = 600 * PX
	player.gravity = 1500 * PX

	// 1080 pixels tall, as the old window was, so the character is the same size
	camera := matchbox.create_camera_2d(1080 * PX)
	camera.position.y = 1.5
	camera.target.y = 1.5

	// Debug: T toggles slow motion (a tenth of the speed), and the sheet frame is
	// printed to the console each time it changes, so a pose can be matched to
	// its number in anim_list.txt
	slow_motion := false
	last_frame := -1

	for matchbox.is_running() {
		dt := matchbox.get_delta_time()
		matchbox.poll_events()

		if matchbox.is_key_pressed(.ESCAPE) {
			matchbox.stop_running()
		}
		if matchbox.is_key_pressed(.T) {
			slow_motion = slow_motion == false
		}
		if slow_motion == true {
			dt *= 0.1
		}

		movement(&player, dt)
		matchbox.camera_follow(&camera, {player.position.x, 1.5}, 4, dt)

		if player.frame != last_frame {
			last_frame = player.frame
			matchbox.print("frame", player.frame, "state", player.state)
		}

		matchbox.render_start()
		matchbox.clear_background({0.1, 0.1, 0.14, 1})

			matchbox.camera_start(camera)

			// The ground, with a tick every unit so walking is visible
			matchbox.render_rectangle({camera.position.x, -2, 0}, {20, 4}, {0.25, 0.3, 0.25, 1})
			first_tick := int(camera.position.x) - 6
			for tick in first_tick ..= first_tick + 12 {
				matchbox.render_rectangle({f32(tick), -0.15, 0.5}, {0.04, 0.3}, {0.5, 0.55, 0.5, 1})
			}

			matchbox.render_animated_sprite(player.animated)

			matchbox.camera_end()

		matchbox.render_end()
	}

	matchbox.destroy_animation_clip(player.anim.sheet)
	matchbox.cleanup()

}
