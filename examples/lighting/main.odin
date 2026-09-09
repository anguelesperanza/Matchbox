package lighting_example

/*
	A campfire in the dark, which is stage 5 and is PsxGame's opening scene.

	The lighting model is that game's, ported constant for constant -- the same
	attenuation curve, the same specular exponent, the same ambient divided by
	ten, gamma applied before the fog so the fog colour is the colour you asked
	for. Its `campfire_light` flicker is reproduced here line for line, because
	the flicker is the thing that makes a fire look like a fire rather than an
	orange lamp.

	Things to try:

	  - **walk backwards.** The fog is dark blue from 3 units to 12, so the
	    world does not end at a black wall, it fades. Turn it off with F and
	    watch how much worse an unlit scene reads without it
	  - **press L.** That turns `Lighting_Settings.enabled` off, which is a
	    scene-level statement now rather than an accident of how many lights
	    happen to be set -- the fire and the moon are still set the whole
	    time, they are just not being run through any BRDF while this is off.
	    Every part still draws, in its own material's base colour, because
	    that is what `Shading_Model.UNLIT` (which this forces every material
	    through while lighting is off) means
	  - **watch the specular highlight on the stove.** It moves, because the
	    light does. The flicker offsets the position by a few centimetres on
	    two different sine waves and the highlight follows it
	  - **press K** for a second, cold, directional light -- a moon
	  - **press H** for an actual cast shadow -- the moon's, since only a
	    directional or spot light uses `Shadow_Settings.technique`'s three
	    map-based choices (see `shadow.odin`). The stove, pot, cube and the
	    ring of cubes further out all block it, each with a dark patch on the
	    ground stretching away from the moon's own direction. Needs K on as
	    well: marking the moon `casts_shadow` and turning
	    `Lighting_Settings.shadows.enabled` on are two separate switches, and
	    neither alone does anything
	  - **press T** for a flashlight -- a spotlight glued to the camera, aimed
	    wherever it looks. Point straight at the stove or pot and it lights
	    up; turn away and it goes back to whatever the fire and ambient alone
	    give it, even though nothing about its distance changed -- the cutoff
	    is the cone, not range. Watch the edge of the beam sweep across the
	    ground as you turn: soft, not a hard line, which is `inner_angle`
	    fading out to `outer_angle` rather than a single cutoff angle
	  - **T and H together, K off** -- the torch casts its own shadow, from
	    its own position rather than the camera-centred trick the moon's
	    shadow needs for having none
	  - **T, H and K all together** -- the moon and the torch each cast a
	    real shadow at once now, in two separate maps (`MAX_SHADOW_CASTERS`).
	    Turning the flashlight on used to mean the moon's own shadow vanished
	    everywhere, not just outside the beam, since only one light could
	    ever be the caster; watch the moon's own shadows on the ground stay
	    put while the torch's beam adds its own
	  - **press Y** to cycle `Shadow_Settings.technique` through PCF, PCSS
	    and CASCADED (H must be on too, or there is nothing to see it change
	    on) -- PCSS softens the moon's shadow edge more the further the
	    penumbra has to spread; CASCADED is the one to check up close: walk
	    right up to the stove's own shadow edge and the crawling, blocky
	    aliasing PCF shows at this resolution should read cleaner, since the
	    nearest cascade covers far less ground per texel than the single map
	    PCF/PCSS share
	  - **press G** for the fire's own cube shadow (P3's point-light case,
	    `shadow_cube.odin`) -- independent of Y's own technique switch, since
	    a point light was never eligible for that switch's three choices in
	    the first place (see `Shadow_Technique`'s own doc comment). Six
	    passes instead of one, so watch for it costing more than the others;
	    the campfire is a poor occluder of itself but the props around it
	    should each pick up a shadow radiating outward from the fire now,
	    on every side, the way a point light's shadow actually has to look
	  - **press B** to step bloom through off, the shipped `BLOOM_DEFAULTS`,
	    and a second stop tuned for a dark scene (`post.odin`, `bloom.odin`).
	    The shipped default only spills light brighter than white, which is
	    right for a scene lit for HDR and may be nothing at all in this one --
	    the brightest thing here is a clamped ember. That is what the second
	    stop is for. **Whether either shows anything is genuinely not known:
	    no frame of this rework has been rendered.** If the second stop is
	    what does it, the number to carry back into a game is `threshold`,
	    not `intensity`
	  - **press B then M.** Bloom is what makes `Tonemap`'s four curves tell
	    themselves apart: it is the thing that pushes pixels past white, and
	    NONE clips them flat where REINHARD, ACES and AGX each compress them
	    differently. On the dark stop, look at the ember's core rather than
	    its halo
	  - **press C** to step colour grading through off, warm-and-contrasty
	    and cold-and-flat. Both stops are deliberately overdone -- a grade
	    tuned to be tasteful and a grade that is not running look far too
	    alike to tell apart. The off stop is `Color_Grade{}`, which is an
	    exact no-op rather than a grade that happens to be near one: every
	    field of that struct is a delta from identity, which is what lets a
	    partial literal naming two fields mean what it looks like it means
	  - **press C then L.** Grading runs in the tonemap resolve, after the
	    3D pass, so it applies to an unlit scene exactly as it does to a lit
	    one -- and so does bloom. Neither knows which shading model ran, or
	    which of the three render pipelines drew the frame

	Models are PsxGame's own, loaded by stage 4.
*/

import "core:fmt"
import "core:math"

import mb "../../matchbox"

ASSETS :: "../../../games/PsxGame/assets/models/"

// PsxGame's deep amber red, and its fog.
EMBER     :: [4]f32{1.0, 0.2, 0.0, 1}
FOG_COLOR :: [4]f32{0.04, 0.04, 0.18, 1}
FOG_START :: f32(3)
FOG_END   :: f32(12)

Prop :: struct {
	path:     string,
	position: [3]f32,
	scale:    f32,
	model:    mb.Model,
	loaded:   bool,
}

main :: proc() {
	mb.init("Lighting", 1280, 720)
	defer mb.cleanup()

	mb.set_escape_key(.UNKNOWN)

	props := []Prop{
		{path = ASSETS + "campfireV1.gltf", position = { 0, 0,  0}, scale = 3},
		{path = ASSETS + "stove.gltf",      position = {-4, 0, -3}, scale = 3},
		{path = ASSETS + "pot.gltf",        position = { 3, 0, -2}, scale = 3},
		{path = ASSETS + "cube.gltf",       position = { 2, 0,  3}, scale = 3},
	}

	for &prop in props {
		model, err := mb.load_model(prop.path)
		if err != nil {
			fmt.eprintfln("could not load %s: %v", prop.path, err)
			continue
		}

		prop.model, prop.loaded = model, true
		prop.position.y = -prop.model.bounds_min.y * prop.scale
	}

	defer for &prop in props {
		if prop.loaded do mb.destroy(&prop.model)
	}

	// Standing five back with the eye 1.8 up, looking down at the campfire --
	// the same opening view this had before the rig existed.
	player := [3]f32{0, 0, 5}

	rig := mb.create_first_person_camera(
		position   = player,
		facing     = -math.PI * 0.5,
		pitch      = math.atan2(f32(-1.0), f32(5.0)),
		eye_offset = {0, 1.8, 0},
	)

	moon_on   := false
	torch_on  := false
	fire_cube_shadow := false // G -- the fire's own cube shadow, see this file's own top comment

	/*
		B and C step through the post chain (post.odin) rather than toggling
		it, and that is the point of them here.

		Bloom's default threshold is 1 -- only light brighter than white
		spills -- which is the right default for a scene lit for HDR and may
		well show nothing at all in this one, where the brightest thing is a
		clamped ember a couple of units from the camera. **Whether it does has
		not been checked: nothing in this rework has been seen to render.** So
		B offers a second stop with the threshold well below 1 and the
		intensity up, which is what a dark scene wants, and stepping between
		the two answers the question in one keypress instead of needing a
		recompile.

		C is the same idea for grading: the two stops are deliberately
		exaggerated (a warm, contrasty one and a cold, flat one), because a
		grade tuned to be tasteful and a grade that is not running look far
		too alike to tell apart from across a room.
	*/
	bloom_step := 0
	grade_step := 0

	/*
		One value held for the whole run and re-submitted whenever a toggle
		changes it -- `set_lighting` replaces the entire struct each call, the
		same way `set_lights` replaces the entire light list, so there is no
		"just flip the fog bit" call to make. `shadows` carries `SHADOW_DEFAULTS`'
		numbers from the start, with `enabled` forced off until H turns it on,
		so turning shadows on later does not also mean inventing a resolution
		and an extent on the spot.
	*/
	settings := mb.Lighting_Settings{
		enabled  = true,
		ambient  = {color = {0.35, 0.35, 0.55, 1}},
		fog      = {enabled = true, color = FOG_COLOR, start = FOG_START, end = FOG_END},
		shadows  = mb.SHADOW_DEFAULTS,
		exposure = 1,
	}
	settings.shadows.enabled = false
	mb.set_lighting(settings)

	mb.set_cursor_locked(true)

	for mb.is_running() {
		mb.poll_events()
		time := f32(mb.get_time())

		if mb.is_key_pressed(.ESCAPE) {
			if mb.is_cursor_locked() do mb.set_cursor_locked(false)
			else                 do mb.mbi.running = false
		}
		if !mb.is_cursor_locked() && mb.is_mouse_pressed(.LEFT) do mb.set_cursor_locked(true)

		settings_changed := false

		if mb.is_key_pressed(.L) {
			settings.enabled = !settings.enabled
			settings_changed = true
		}
		if mb.is_key_pressed(.K) do moon_on  = !moon_on
		if mb.is_key_pressed(.T) do torch_on = !torch_on

		if mb.is_key_pressed(.F) {
			settings.fog.enabled = !settings.fog.enabled
			settings_changed = true
		}

		// Only the moon casts one -- see create_directional_light's
		// casts_shadow below -- so this does nothing visible until K is also
		// on. Left as two independent switches rather than one, the same
		// "opt in twice" shape shadow.odin's own doc comment explains.
		if mb.is_key_pressed(.H) {
			settings.shadows.enabled = !settings.shadows.enabled
			settings_changed = true
		}

		// Cycles PCF -> PCSS -> CASCADED -> PCF. Only the directional/spot
		// casters (the moon, the torch) are affected -- see this file's own
		// top comment on G for why the fire's own shadow is a separate
		// switch entirely.
		if mb.is_key_pressed(.Y) {
			switch settings.shadows.technique {
			case .PCF:      settings.shadows.technique = .PCSS
			case .PCSS:     settings.shadows.technique = .CASCADED
			case .CASCADED: settings.shadows.technique = .PCF
			}
			settings_changed = true
		}

		if mb.is_key_pressed(.G) do fire_cube_shadow = !fire_cube_shadow

		// Off -> the shipped defaults -> a dark-scene tuning. See bloom_step's
		// own comment above for why there are two on-stops rather than one.
		if mb.is_key_pressed(.B) {
			bloom_step = (bloom_step + 1) % 3

			switch bloom_step {
			case 0: settings.post.bloom = {}
			case 1: settings.post.bloom = mb.BLOOM_DEFAULTS
			case 2: settings.post.bloom = {enabled = true, threshold = 0.35, knee = 0.2, intensity = 0.2, scatter = 0.8, levels = 5}
			}

			settings_changed = true
		}

		/*
			Off -> warm and contrasty -> cold and flat. Every field is a delta
			from identity (`Color_Grade`, post.odin), so the first stop is the
			zero value and is an exact no-op rather than a grade that happens
			to be close to one.
		*/
		if mb.is_key_pressed(.C) {
			grade_step = (grade_step + 1) % 3

			switch grade_step {
			case 0:
				settings.post.grade = {}
			case 1:
				settings.post.grade = {
					enabled    = true,
					gain       = {0.12, 0, -0.12}, // warmer highlights
					lift       = {0.01, 0, -0.01},
					contrast   = 0.25,
					saturation = 0.15,
				}
			case 2:
				settings.post.grade = {
					enabled    = true,
					gain       = {-0.08, -0.02, 0.10}, // colder highlights
					lift       = {0.04, 0.04, 0.06},   // milky blacks
					contrast   = -0.15,
					saturation = -0.35,
				}
			}

			settings_changed = true
		}

		// The tonemap curve, which decides what happens to anything bloom
		// pushed past white -- NONE clips it flat, the other three compress
		// it. Worth having beside B: bloom is most of what makes the
		// difference between them visible at all.
		if mb.is_key_pressed(.M) {
			switch settings.tonemap {
			case .NONE:     settings.tonemap = .REINHARD
			case .REINHARD: settings.tonemap = .ACES
			case .ACES:     settings.tonemap = .AGX
			case .AGX:      settings.tonemap = .NONE
			}
			settings_changed = true
		}

		if settings_changed do mb.set_lighting(settings)

		if mb.is_cursor_locked() {
			mb.first_person_walk(&rig, &player, 4, mb.get_delta_time())
		}

		// PsxGame's flicker, unchanged. Two sines that do not divide into
		// each other, so the fire never repeats on a beat you can hear.
		flicker := 1.0 + math.sin(time * 1.0) * 0.1 + math.sin(time * 0.5) * 0.05

		fire := mb.create_point_light(
			{math.sin(time * 8.0) * 0.05, 1.0, math.cos(time * 6.0) * 0.05},
			{
				clamp(EMBER.r * flicker, 0, 1),
				clamp(EMBER.g * flicker, 0, 0.31), // green capped much lower,
				0,                                 // or it drifts to yellow
				1,
			},
			casts_shadow = fire_cube_shadow)

		// Fire is always in the scene; the moon and torch are each an extra
		// slot, filled in only when their own key has turned them on. Set
		// every frame regardless of `settings.enabled` -- the light list and
		// whether lighting runs are independent statements now, see this
		// file's own top comment on L.
		slots: [3]mb.Light
		count := 0
		slots[count] = fire; count += 1

		if moon_on {
			slots[count] = mb.create_directional_light({-0.4, -1, -0.3}, {0.18, 0.20, 0.40, 1}, casts_shadow = true)
			count += 1
		}
		if torch_on {
			slots[count] = mb.create_spot_light(rig.camera.position, mb.camera3d_forward(rig.camera), mb.WHITE, 15, 25, casts_shadow = true)
			count += 1
		}

		mb.set_lights(slots[:count])

		mb.begin_drawing()
		mb.clear_background(FOG_COLOR if settings.fog.enabled else {0.02, 0.02, 0.05, 1})

		/*
			Whatever should cast a shadow, drawn once per active caster
			(moon and/or torch, each its own slot -- see MAX_SHADOW_CASTERS)
			from that light's own point of view before the scene is drawn
			from the camera's. Same models, same positions, as the main pass
			just below -- a shadow pass ordinarily draws whatever occludes
			the light, which here is everything the main pass also draws
			except the ground itself (nothing for the plane's own shadow to
			fall on). Guarded on the return value rather than called
			unconditionally: with shadows off or no light marked
			casts_shadow for that slot, begin_shadow_pass opens no pass at
			all, and draw_model asserts loudly rather than silently doing
			nothing if asked to draw with none of the right kind open.
		*/
		for slot in 0 ..< mb.MAX_SHADOW_CASTERS {
			if mb.begin_shadow_pass(slot) {
				for prop in props {
					if prop.loaded do mb.draw_model_at(prop.model, prop.position, prop.scale)
				}
				for i in 0 ..< 9 {
					angle := f32(i) * math.TAU / 9
					radius := 7 + f32(i % 3) * 2.5
					mb.draw_cube(
						{math.cos(angle) * radius, 0.6, math.sin(angle) * radius},
						{1.2, 1.2, 1.2},
						{0.55, 0.5, 0.45, 1})
				}
				mb.end_shadow_pass()
			}
		}

		// The fire's own cube shadow -- six passes, one per face, entirely
		// separate from the loop just above since a point light was never
		// one of MAX_SHADOW_CASTERS's own two slots (see shadow_cube.odin).
		// A no-op loop when G is off: begin_point_shadow_pass returns false
		// with no point light marked casts_shadow, the same "opt in twice,
		// harmless otherwise" shape H's own switch already has.
		for face in 0 ..< 6 {
			if mb.begin_point_shadow_pass(face) {
				for prop in props {
					if prop.loaded do mb.draw_model_at(prop.model, prop.position, prop.scale)
				}
				for i in 0 ..< 9 {
					angle := f32(i) * math.TAU / 9
					radius := 7 + f32(i % 3) * 2.5
					mb.draw_cube(
						{math.cos(angle) * radius, 0.6, math.sin(angle) * radius},
						{1.2, 1.2, 1.2},
						{0.55, 0.5, 0.45, 1})
				}
				mb.end_shadow_pass()
			}
		}

		mb.begin_drawing_3d(rig.camera)

		mb.draw_plane({0, 0, 0}, {60, 60}, {0.30, 0.26, 0.22, 1})

		for prop in props {
			if prop.loaded do mb.draw_model_at(prop.model, prop.position, prop.scale)
		}

		// Something to catch the light further out, so the fog has a gradient
		// to work across rather than a single object and then nothing.
		for i in 0 ..< 9 {
			angle := f32(i) * math.TAU / 9
			radius := 7 + f32(i % 3) * 2.5
			mb.draw_cube(
				{math.cos(angle) * radius, 0.6, math.sin(angle) * radius},
				{1.2, 1.2, 1.2},
				{0.55, 0.5, 0.45, 1})
		}

		mb.end_drawing_3d()

		font := &mb.mbi.font
		mb.draw_text(font, "L lights, K moon, F fog, H shadows, T torch, Y technique, G fire shadow, WASD walk, ESC pointer", 20, 40, mb.WHITE)
		mb.draw_text(font, "B bloom, C grade, M tonemap", 20, 70, mb.WHITE)
		mb.draw_text(font, fmt.tprintf("lights %v   moon %v   fog %v   shadows %v (%v)   torch %v   fire shadow %v",
			"on" if settings.enabled else "off (unlit)",
			"on" if moon_on else "off",
			"on" if settings.fog.enabled else "off",
			"on" if settings.shadows.enabled else "off",
			settings.shadows.technique,
			"on" if torch_on else "off",
			"on" if fire_cube_shadow else "off"), 20, 100, mb.WHITE)

		bloom_label := "off"
		if settings.post.bloom.enabled {
			bloom_label = fmt.tprintf("threshold %.2f, intensity %.2f", settings.post.bloom.threshold, settings.post.bloom.intensity)
		}

		grade_labels := [3]string{"off", "warm", "cold"}

		mb.draw_text(font, fmt.tprintf("bloom %v   grade %v   tonemap %v",
			bloom_label, grade_labels[grade_step], settings.tonemap), 20, 130, mb.WHITE)

		cx := f32(mb.mbi.width) * 0.5
		cy := f32(mb.mbi.height) * 0.5
		mb.draw_rect({position = {cx, cy}, size = {12, 2}, color = mb.WHITE})
		mb.draw_rect({position = {cx, cy}, size = {2, 12}, color = mb.WHITE})

		mb.end_drawing()
	}

	mb.wait_idle()
}
