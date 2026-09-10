package lighting_lab_example

/*
	The lighting engine, with every switch on the outside of the box.

	`examples/lighting` is a *scene* -- PsxGame's campfire, ported, with a few
	toggles bolted on. This is the opposite: a scene built for no reason except
	to make each module of the lighting engine visible one key at a time, and
	the only example that depends on no asset files at all. Every shape here is
	generated in code (`create_sphere_model` and friends), so it runs from a
	clean checkout.

	`lighting_plan.md` asks for an engine where the *game* picks the shading
	model, the shadow technique and the render pipeline rather than being
	locked into whichever was implemented first. That claim is hard to believe
	from reading a struct. This is it wired to a keyboard: **the same frame,
	the same lights and the same materials, redrawn through a different module
	each time you press a key.**

	## What to look at, in the order that makes each one obvious

	  - **press P** to cycle the render pipeline -- FORWARD, CLUSTERED,
	    DEFERRED. The interesting thing is that **nothing should change.**
	    Three completely different frame shapes (one pass; one pass with a
	    per-cluster light list; a G-buffer fill plus a fullscreen lighting
	    pass) reach the same picture, because all three fill the same `Surface`
	    and call the same `shade_surface`. If pressing P changes the image,
	    something in that seam is wrong -- which is exactly the gate
	    `lighting_rework.md` sets for P5 and P6 and could not run without a
	    screen.

	  - **press M** to cycle the shading model on the sphere row: Blinn-Phong,
	    PBR metallic-roughness, PBR specular-glossiness, toon, subsurface,
	    unlit. The six spheres sweep roughness from a mirror on the left to
	    fully rough on the right, so each model shows what it does with that
	    parameter -- and toon shows it doing nothing, since toon bands
	    `n_dot_l` instead.

	  - **press N** to switch the light rig from three lights to twenty-odd.
	    Then press P. FORWARD loops every light for every fragment; CLUSTERED
	    loops only the lights whose reach covers that fragment's cluster. Same
	    picture, and the difference is one the eye cannot see and a profiler
	    can -- which is half of P5's gate, and the half that was measurable.

	  - **press G** to make the orbiting point light cast its own shadow --
	    six maps rather than one, since a point light shines every way at
	    once, and the only way to reach `Shadow_Technique.CUBE`, which the Y
	    cycle deliberately does not include.

	  - **press H** for shadows and **Y** to cycle the technique. PCF is the
	    plain one. PCSS softens an edge the further the caster is from what it
	    lands on -- watch the tall pillar's shadow, sharp at its base and
	    diffuse at its tip. CASCADED is the one to judge up close: walk right
	    up to a shadow edge and it should stay crisp where PCF has gone blocky.

	  - **press O** for SSAO. Look into the corners where the red boxes meet the
	    floor and each other. This is the darkening that no light source can
	    provide, because ambient light has no direction to be blocked from --
	    which is also why **it does nothing while ambient is off**: press K
	    first if the scene is lit only by the sun.

	  - **press R** to capture the two reflection probes, then **K** until the
	    ambient mode reads `ENVIRONMENT_PROBE`, then walk from the red corner
	    to the green pillar. The ambient light should carry the colour of
	    whichever corner you are standing in, and blend across the middle where
	    the two probes overlap. That is the whole difference between a
	    localized probe and the one scene-wide probe P4 shipped: with one
	    probe, both corners get the same answer.

	    Re-press R after changing anything -- a probe holds whatever the room
	    looked like at the moment it was captured, including which shading
	    model M had selected.

	  - **hold Z or X** to change exposure. Worth knowing about before
	    anything else: "the materials are not reaching the shader" and "the
	    scene is blown out" are the same white picture, and this is what tells
	    them apart in one keypress.

	  - **press V** for volumetric light, then look toward the window slot in
	    the back wall. The shaft is the *shadow map* seen edge-on -- the beam
	    takes the shape of the gap because every step of the raymarch asks the
	    same `shadow_visibility` a surface would. Turn H off and the shaft
	    fills the whole room instead, which is what "no shadows" actually
	    means for light in air.

	  - **press B** for bloom, and look at the emissive sphere. Then press T to
	    cycle the tonemap curve: bloom is what pushes pixels past white, so it
	    is what makes NONE (which clips them flat) look different from ACES
	    and AgX (which compress them).

	  - **press C** to cycle colour grading -- off, warm, cold. Both graded
	    stops are deliberately overdone: a tasteful grade and a grade that is
	    not running look far too alike to tell apart.

	  - **press L** to turn lighting off entirely. Every material becomes
	    `UNLIT` and draws in its own base colour. This is a *statement* the
	    scene makes, not something that happens when the light list empties --
	    which is the first defect `lighting_rework.md` opens with.

	## Reading the room

	The back wall has a slot in it and a light behind, which is there for the
	volumetric shafts. The stack of boxes in the left corner is there for SSAO
	-- lots of concave right angles, which is the one thing ambient occlusion
	has to get right. The pillar is there to cast a long shadow for the
	technique switch. The sphere row is the material sweep. The floating sphere
	is emissive and is there for bloom.

	**Nothing in this file has been seen to render.** The whole lighting rework
	was built without a GPU (`lighting_rework.md` section 8), so this example is
	as much a way to find out whether it works as a way to show that it does.
	If something here looks wrong, it probably is.
*/

import "core:fmt"
import "core:math"

import mb "../../matchbox"

SKY    :: [4]f32{0.35, 0.45, 0.62, 1}
GROUND :: [4]f32{0.20, 0.17, 0.14, 1}

SPHERE_COUNT :: 6

// Everything the scene draws, built once. Separate models rather than the
// shared `draw_cube`/`draw_sphere` shapes because those carry one material
// between them -- and a material per object is the whole point here.
Shapes :: struct {
	floor:   mb.Model,
	wall:    mb.Model, // the back wall and its lintel -- cool blue-grey
	box:     mb.Model, // the SSAO corner -- red
	pillar:  mb.Model, // the shadow caster -- green
	sphere:  mb.Model, // the emissive one, for bloom
	spheres: [SPHERE_COUNT]mb.Model, // the roughness sweep, one material each
	loaded:  bool,
}

main :: proc() {
	mb.init("Lighting Lab", 1280, 720)
	defer mb.cleanup()

	context.logger = mb.mbi.logger

	shapes := build_shapes()
	defer destroy_shapes(&shapes)

	if !shapes.loaded {
		fmt.eprintln("could not build the scene's geometry")
		return
	}

	rig := mb.create_first_person_camera(
		position   = {0, 0, 9},
		facing     = -math.PI * 0.5,
		pitch      = -0.15,
		eye_offset = {0, 1.7, 0},
	)
	player := [3]f32{0, 0, 9}

	/*
		One value held for the whole run and re-submitted whenever a key
		changes it -- `set_lighting` replaces the entire struct each call, so
		there is no "flip one bit" call to make. Shadows carry
		`SHADOW_DEFAULTS`' numbers from the start with `enabled` forced off,
		so turning them on later does not also mean inventing a resolution and
		an extent on the spot; the same trick for SSAO, bloom and volumetrics.
	*/
	settings := mb.Lighting_Settings{
		enabled  = true,
		exposure = 1,
		tonemap  = .ACES,
		ambient  = {kind = .HEMISPHERE, color = SKY, ground_color = GROUND},
		shadows  = mb.SHADOW_DEFAULTS,
		cluster  = mb.CLUSTER_DEFAULTS,
	}
	settings.shadows.enabled = false

	// The three stops each of these cycles through, held here so a key press
	// is a table lookup rather than a switch that has to agree with the label
	// drawn on screen.
	shading_models := [?]mb.Shading_Model{
		.BLINN_PHONG, .PBR_METALLIC, .PBR_SPECGLOSS, .TOON, .SUBSURFACE, .UNLIT,
	}
	shading_index := 1 // PBR metallic-roughness: the one the sweep says most about

	grade_index  := 0
	many_lights  := false
	point_shadow := false // G -- the orbiting point light's own cube shadow
	probes_baked := false // R -- whether the reflection probes have been captured

	/*
		P7c: two probes, one in each of the two strongly-coloured corners of
		the room, placed here and captured by R.

		Placed where the colour is, because that is the entire thing a
		localized probe does that a scene-wide one cannot: stand in the red
		corner and the ambient light picks up red, walk to the green pillar
		and it turns green, and the two blend where their influence spheres
		overlap. With one scene-wide probe both corners get the same answer,
		which is the picture P4 already had.
	*/
	mb.add_reflection_probe({-5.5, 1.6, 1.5}, 7)
	mb.add_reflection_probe({ 5.0, 1.8, 1.5}, 7)

	mb.set_lighting(settings)
	mb.set_cursor_locked(true)

	for mb.is_running() {
		mb.poll_events()
		time := f32(mb.get_time())

		if mb.is_key_pressed(.ESCAPE) {
			if mb.is_cursor_locked() do mb.set_cursor_locked(false)
			else                     do mb.mbi.running = false
		}
		if !mb.is_cursor_locked() && mb.is_mouse_pressed(.LEFT) do mb.set_cursor_locked(true)

		changed := false

		// --- the render pipeline, which should change nothing visible ------
		if mb.is_key_pressed(.P) {
			switch settings.pipeline {
			case .FORWARD:   settings.pipeline = .CLUSTERED
			case .CLUSTERED: settings.pipeline = .DEFERRED
			case .DEFERRED:  settings.pipeline = .FORWARD
			}
			changed = true
		}

		// --- the shading model, which should change everything -------------
		if mb.is_key_pressed(.M) {
			shading_index = (shading_index + 1) % len(shading_models)
			apply_shading_model(&shapes, shading_models[shading_index])
		}

		// --- shadows -------------------------------------------------------
		if mb.is_key_pressed(.H) {
			settings.shadows.enabled = !settings.shadows.enabled
			changed = true
		}
		if mb.is_key_pressed(.Y) {
			switch settings.shadows.technique {
			case .PCF:      settings.shadows.technique = .PCSS
			case .PCSS:     settings.shadows.technique = .CASCADED
			case .CASCADED: settings.shadows.technique = .PCF
			}
			changed = true
		}

		// --- ambient, which is what SSAO has anything to occlude -----------
		/*
			**K, not A.** A is strafe-left, and binding a toggle to a movement
			key means the ambient mode changes every time you sidestep -- which
			is not a subtle bug to live with, it is the scene relighting itself
			while you walk. Worth stating rather than quietly fixing: the
			mistake was picking mnemonic letters before checking what
			`first_person_walk` already reads, which is WASD and nothing else.
		*/
		if mb.is_key_pressed(.K) {
			switch settings.ambient.kind {
			case .CONSTANT:          settings.ambient.kind = .HEMISPHERE
			case .HEMISPHERE:        settings.ambient.kind = .ENVIRONMENT_PROBE
			case .ENVIRONMENT_PROBE: settings.ambient.kind = .CONSTANT
			}
			changed = true
		}

		// --- P7b -----------------------------------------------------------
		if mb.is_key_pressed(.O) {
			settings.ssao = settings.ssao.enabled ? mb.Ssao{} : mb.SSAO_DEFAULTS
			changed = true
		}
		if mb.is_key_pressed(.V) {
			settings.volumetric = settings.volumetric.enabled ? mb.Volumetric{} : mb.VOLUMETRIC_DEFAULTS
			changed = true
		}

		// --- P7a -----------------------------------------------------------
		if mb.is_key_pressed(.B) {
			settings.post.bloom = settings.post.bloom.enabled ? mb.Bloom{} : mb.BLOOM_DEFAULTS
			changed = true
		}
		if mb.is_key_pressed(.C) {
			grade_index = (grade_index + 1) % 3
			settings.post.grade = grade_for(grade_index)
			changed = true
		}
		if mb.is_key_pressed(.T) {
			switch settings.tonemap {
			case .NONE:     settings.tonemap = .REINHARD
			case .REINHARD: settings.tonemap = .ACES
			case .ACES:     settings.tonemap = .AGX
			case .AGX:      settings.tonemap = .NONE
			}
			changed = true
		}

		// --- fog, and the scene-level on/off -------------------------------
		/*
			**The range has to fit the room, and the first version's did not.**
			Fog from 8 to 34 units in a room whose back wall is 17 units from
			where you start means the wall is barely a third fogged and the only
			thing visibly affected is the far corners of the 40-unit floor --
			which is exactly what it looked like: "I can see the corners of the
			plane darken but that's it".

			3 to 22 puts the whole room inside the ramp, so the back wall reads
			as clearly further away than the sphere row and the fog colour is
			somewhere on screen to be recognised. The colour is also darker and
			bluer than the background now, so fog *on* and fog *off* differ in
			hue and not only in contrast.
		*/
		if mb.is_key_pressed(.F) {
			settings.fog = settings.fog.enabled ? mb.Fog{} : mb.Fog{enabled = true, color = {0.05, 0.08, 0.16, 1}, start = 3, end = 22}
			changed = true
		}
		if mb.is_key_pressed(.L) {
			settings.enabled = !settings.enabled
			changed = true
		}

		if mb.is_key_pressed(.N) do many_lights = !many_lights
		if mb.is_key_pressed(.G) do point_shadow = !point_shadow

		/*
			Exposure, on a key, because "everything looks white" and "the
			materials are not reaching the shader" are the same picture and
			this is what tells them apart in one press. Held rather than
			tapped: finding the exposure a scene wants is a slider, not a
			cycle.
		*/
		if mb.is_key_held(.Z) {
			settings.exposure = max(settings.exposure - mb.get_delta_time() * 0.8, 0.05)
			changed = true
		}
		if mb.is_key_held(.X) {
			settings.exposure = min(settings.exposure + mb.get_delta_time() * 0.8, 6)
			changed = true
		}

		// R: capture and bake every placed reflection probe from where it
		// stands. See capture_probes for why this is a key rather than
		// something that happens every frame.
		if mb.is_key_pressed(.R) {
			capture_probes(&shapes, time)
			probes_baked = true
		}

		if changed do mb.set_lighting(settings)

		if mb.is_cursor_locked() {
			mb.first_person_walk(&rig, &player, 5, mb.get_delta_time())
		}

		set_scene_lights(time, many_lights, point_shadow)

		mb.begin_drawing()
		mb.clear_background({0.04, 0.05, 0.08, 1})

		/*
			Everything that casts a shadow, handed over **before** the 3D pass
			opens. `draw_model(casts_shadow = true)` called out here is held
			rather than drawn, and `begin_drawing_3d` then puts it into every
			pass it belongs in -- each shadow map first, then the scene --
			which is the whole reason to prefer it over opening those passes
			by hand.

			Doing it by hand is what this example tried first, and it was
			quietly wrong: `begin_shadow_pass` is PCF and PCSS's shape, and
			CASCADED needs a pass per cascade per slot
			(`begin_cascade_shadow_pass`) while CUBE needs six. Pressing Y to
			cycle the technique would have produced no shadows at all for two
			of the three, with nothing to point at. The framework already
			knows which shape each technique wants; a game should not have to.
		*/
		draw_room(&shapes, time, casts_shadow = true, include_floor = false)

		mb.begin_drawing_3d(rig.camera)

		/*
			The floor is the one thing drawn *inside* the pass, so it is lit
			and occluded like everything else but never goes into a shadow
			map. A ground plane has nothing for its own shadow to fall on, and
			a surface nearly parallel to the light is where depth bias is
			hardest -- keeping it out is one less source of acne to tune
			around. `examples/lighting` leaves its ground out for the same
			reason.
		*/
		mb.draw_model(shapes.floor, mb.Transform{
			position = {0, 0, 0},
			rotation = 1,
			scale    = {40, 1, 40},
		})

		mb.end_drawing_3d()

		draw_readout(settings, shading_models[shading_index], grade_index, many_lights, point_shadow, probes_baked)

		mb.end_drawing()
	}

	mb.wait_idle()
}

// -----------------------------------------------------------------------
// The scene
// -----------------------------------------------------------------------

/*
	Every shape, built once with a material of its own.

	`create_sphere_model` and friends hand back a `Model` whose one part
	carries `MATERIAL_DEFAULTS` -- lit, white, Blinn-Phong. Overwriting
	`parts[0].material` afterwards is the whole material API for generated
	geometry: there is no separate "assign material" call, because a part
	*has* one rather than referring to one.
*/
build_shapes :: proc() -> Shapes {
	shapes: Shapes

	floor_err, wall_err, box_err, pillar_err, sphere_err: mb.Error

	// Four cubes rather than one, because a material belongs to a *part* and
	// these want four different ones. The geometry is identical; only what it
	// is made of differs.
	shapes.floor,  floor_err  = mb.create_plane_model(1)
	shapes.wall,   wall_err   = mb.create_cube_model(1)
	shapes.box,    box_err    = mb.create_cube_model(1)
	shapes.pillar, pillar_err = mb.create_cube_model(1)
	shapes.sphere, sphere_err = mb.create_sphere_model(1, 24, 32)

	if floor_err != nil || wall_err != nil || box_err != nil || pillar_err != nil || sphere_err != nil {
		return shapes
	}

	/*
		**Saturated, and each thing its own colour.** The first version of this
		room made everything a near-neutral grey on the reasoning that the
		spheres should be the only interesting material in it -- and a
		near-neutral grey under a full-strength sun, through ACES, is white.
		Every surface looked like every other surface, which is the opposite of
		what an example for a *lighting* engine wants: you cannot see what a
		light is doing to a surface whose colour you cannot make out.

		The two corner colours are doing a second job as well. They are what
		the reflection probes standing in those corners pick up (`R`), so
		walking from one to the other visibly changes the ambient tint -- and
		strong colours are what makes that visible rather than a subtlety.
	*/
	set_material(&shapes.floor, mb.create_material_pbr_metallic(
		base_color = {0.48, 0.44, 0.38, 1}, metallic = 0, roughness = 0.9))

	// The back wall and its lintel: cool, so the warm sun raking across it
	// reads as warm.
	set_material(&shapes.wall, mb.create_material_pbr_metallic(
		base_color = {0.30, 0.36, 0.52, 1}, metallic = 0, roughness = 0.75))

	// The SSAO corner -- strongly red, both to be distinct and to give the
	// probe standing in it something to pick up.
	set_material(&shapes.box, mb.create_material_pbr_metallic(
		base_color = {0.72, 0.16, 0.10, 1}, metallic = 0, roughness = 0.6))

	// The pillar, and the other probe's colour: strongly green.
	set_material(&shapes.pillar, mb.create_material_pbr_metallic(
		base_color = {0.14, 0.55, 0.22, 1}, metallic = 0, roughness = 0.55))

	/*
		The emissive sphere bloom is for. Emissive is *added* after the light
		loop rather than lit, so a value above 1 is a surface brighter than
		white -- which is exactly what `Bloom.threshold`'s default of 1 is
		looking for, and why this is 3 rather than 1.
	*/
	set_material(&shapes.sphere, mb.create_material_pbr_metallic(
		base_color = {0.9, 0.55, 0.25, 1}, metallic = 0, roughness = 0.4,
		emissive = {3.0, 1.4, 0.5}))

	// The sweep: identical geometry, roughness rising left to right.
	for i in 0 ..< SPHERE_COUNT {
		model, err := mb.create_sphere_model(1, 24, 32)
		if err != nil do return shapes

		shapes.spheres[i] = model
	}

	shapes.loaded = true
	apply_shading_model(&shapes, .PBR_METALLIC)

	return shapes
}

destroy_shapes :: proc(shapes: ^Shapes) {
	mb.destroy_model(&shapes.floor)
	mb.destroy_model(&shapes.wall)
	mb.destroy_model(&shapes.box)
	mb.destroy_model(&shapes.pillar)
	mb.destroy_model(&shapes.sphere)
	for i in 0 ..< SPHERE_COUNT do mb.destroy_model(&shapes.spheres[i])
}

set_material :: proc(model: ^mb.Model, material: mb.Material) {
	for &part in model.parts do part.material = material
}

/*
	Rebuilds the sweep's six materials under a different shading model -- what
	the M key does.

	Each model reads a different subset of `Material`'s flat parameter list
	(that struct's own doc comment says which), so this is six constructors
	rather than one struct with a field changed: `create_material_toon` and
	`create_material_pbr_metallic` disagree about what "roughness" even means,
	and picking the constructor is how a game says which set it is filling in.

	The sweep parameter is the same 0..1 ramp in every case, mapped onto
	whichever knob that model actually has. Toon and unlit have nothing that
	varies with it, and showing that is the point of including them.
*/
apply_shading_model :: proc(shapes: ^Shapes, model: mb.Shading_Model) {
	if !shapes.loaded do return

	for i in 0 ..< SPHERE_COUNT {
		t := f32(i) / f32(SPHERE_COUNT - 1)

		material: mb.Material

		switch model {
		case .BLINN_PHONG:
			// The sweep maps to the specular exponent, backwards: a high
			// exponent is a tight highlight, which is what a *smooth* surface
			// has, so the left-hand sphere gets the largest number.
			material = mb.create_material_phong(
				base_color     = {0.75, 0.76, 0.80, 1},
				specular_power = 128 * (1 - t) + 4 * t)

		case .PBR_METALLIC:
			/*
				**Dielectric, not metal, and that is a deliberate choice about
				what a default view should show.**

				A fully metallic material has no diffuse term at all -- that is
				what metalness *means* -- so everything it shows you is
				reflected. With no environment probe bound there is nothing to
				reflect but the handful of lights, and a metal sweep renders
				very nearly black with a few bright highlights on it. Correct,
				and a terrible first impression.

				At metallic 0 the sweep reads immediately: the same coloured
				surface with its specular lobe tightening from left to right.
				To see the metal case, press R to capture the probes and K
				until ambient reads ENVIRONMENT_PROBE -- then a metal has a
				room to reflect and looks like metal. That dependency is worth
				meeting once; it is the single most common reason PBR "looks
				wrong" in a renderer that is working correctly.
			*/
			material = mb.create_material_pbr_metallic(
				base_color = {0.85, 0.72, 0.40, 1},
				metallic   = 0,
				roughness  = clamp(t, 0.05, 1))

		case .PBR_SPECGLOSS:
			// The same surface in the other parameterization -- glossiness is
			// roughness upside down, which is the whole difference.
			material = mb.create_material_pbr_specgloss(
				base_color = {0.75, 0.76, 0.80, 1},
				specular   = {0.9, 0.75, 0.45},
				glossiness = 1 - t)

		case .TOON:
			// Bands rather than a ramp, and nothing here reads the sweep --
			// which is the point of leaving it in the cycle.
			material = mb.create_material_toon(
				base_color = {0.35, 0.65, 0.85, 1}, bands = 4, rim = 0.35)

		case .SUBSURFACE:
			// Thickness is the sweep: thin at one end (light passes through,
			// so the edges glow) and thick at the other.
			material = mb.create_material_subsurface(
				base_color = {0.90, 0.72, 0.66, 1},
				subsurface = {0.85, 0.35, 0.28},
				thickness  = 0.05 + 0.95 * (1 - t))

		case .UNLIT:
			// No lighting at all, so the whole row is one flat colour and the
			// sweep vanishes. Worth seeing once: this is also what every
			// material in the scene becomes when L turns lighting off.
			material = mb.create_material_unlit({0.75, 0.76, 0.80, 1})
		}

		set_material(&shapes.spheres[i], material)
	}
}

/*
	Everything in the room, drawn once -- with the two flags its two callers
	disagree about.

	`casts_shadow` submits the call *before* the 3D pass and lets the framework
	replay it into every shadow map that wants it and then into the scene, from
	one list of calls. That is what the ordinary frame does. A probe capture
	cannot: it is already inside a pass of its own, so it passes false and every
	call draws where it stands.

	`include_floor` differs for the same reason from the other end. The ordinary
	frame draws the floor separately, inside the 3D pass, to keep it out of
	every shadow map -- a ground plane has nothing for its own shadow to fall on
	and is where depth bias is hardest. A probe standing in the room very much
	needs to see the floor, since a floor is most of what bounces onto a wall.
*/
draw_room :: proc(shapes: ^Shapes, time: f32, casts_shadow: bool, include_floor: bool) {
	if include_floor {
		mb.draw_model(shapes.floor, mb.Transform{position = {0, 0, 0}, rotation = 1, scale = {40, 1, 40}})
	}

	// The back wall, in three pieces with a slot between them -- the shape the
	// volumetric shafts come through. Left panel, right panel, lintel.
	mb.draw_model(shapes.wall, mb.Transform{position = {-5.5, 3, -8}, rotation = 1, scale = {7, 6, 0.6}}, casts_shadow = casts_shadow)
	mb.draw_model(shapes.wall, mb.Transform{position = { 5.5, 3, -8}, rotation = 1, scale = {7, 6, 0.6}}, casts_shadow = casts_shadow)
	mb.draw_model(shapes.wall, mb.Transform{position = { 0.0, 5, -8}, rotation = 1, scale = {4, 2, 0.6}}, casts_shadow = casts_shadow)

	// The SSAO corner: red boxes stacked into each other and into the floor,
	// which is nothing but concave right angles -- the one thing ambient
	// occlusion has to get right, and the one thing no light source can
	// produce. Also what the left-hand reflection probe picks up.
	mb.draw_model(shapes.box, mb.Transform{position = {-6.0, 0.6, 1.0}, rotation = 1, scale = {2.4, 1.2, 2.4}}, casts_shadow = casts_shadow)
	mb.draw_model(shapes.box, mb.Transform{position = {-4.6, 0.4, 2.2}, rotation = 1, scale = {1.6, 0.8, 1.6}}, casts_shadow = casts_shadow)
	mb.draw_model(shapes.box, mb.Transform{position = {-6.6, 1.8, 1.8}, rotation = 1, scale = {1.2, 1.2, 1.2}}, casts_shadow = casts_shadow)
	mb.draw_model(shapes.box, mb.Transform{position = {-3.6, 0.25, 0.6}, rotation = 1, scale = {1.0, 0.5, 1.0}}, casts_shadow = casts_shadow)

	// The green pillar, for the shadow-technique switch: tall enough that its
	// tip's shadow is far from its base, which is the whole difference PCSS
	// shows. Also what the right-hand reflection probe picks up.
	mb.draw_model(shapes.pillar, mb.Transform{position = {5.5, 2.5, 1.5}, rotation = 1, scale = {0.8, 5, 0.8}}, casts_shadow = casts_shadow)
	mb.draw_model(shapes.pillar, mb.Transform{position = {4.2, 0.5, 2.6}, rotation = 1, scale = {1.6, 1.0, 1.6}}, casts_shadow = casts_shadow)

	// The material sweep, left to right in front of the wall.
	for i in 0 ..< SPHERE_COUNT {
		x := -4.5 + f32(i) * 1.8
		mb.draw_model_at(shapes.spheres[i], {x, 0.9, -3.0}, 0.9, casts_shadow = casts_shadow)
	}

	// The emissive sphere bloom is for, bobbing so it is obviously not part of
	// the wall behind it.
	mb.draw_model_at(shapes.sphere, {0, 2.6 + math.sin(time * 0.8) * 0.35, 2.5}, 0.45, casts_shadow = casts_shadow)
}

/*
	Captures and bakes every placed reflection probe: six faces each, then the
	convolution.

	**A key rather than something that happens every frame**, and the cost is
	the reason: two probes is twelve extra renders of the whole room, plus
	sixty-odd convolution draws. A probe is a load-time thing, or a when-a-door-
	opens thing. Bound to R here so it can be re-run after walking around --
	which is worth doing at least once, because a probe captures whatever the
	scene looked like at that moment, including whichever shading model the M
	key had selected.

	Note the probes do not see each other: the first is captured before the
	second exists in any baked form, so neither picks up the other's bounce.
	That is the standard limitation and the standard fix is to capture twice.
*/
capture_probes :: proc(shapes: ^Shapes, time: f32) {
	for index in 0 ..< mb.get_reflection_probe_count() {
		for face in 0 ..< 6 {
			if mb.begin_probe_capture(index, face) {
				draw_room(shapes, time, casts_shadow = false, include_floor = true)
				mb.end_probe_capture()
			}
		}

		mb.bake_reflection_probe(index)
	}
}

/*
	The light rig, re-submitted every frame because two of the lights move.

	`set_lights` replaces the whole list, the same way `set_lighting` replaces
	the whole settings struct -- so this builds the list from scratch rather
	than patching one entry, which is also what makes the N key a one-line
	change rather than a bookkeeping problem.
*/
set_scene_lights :: proc(time: f32, many: bool, point_shadow: bool) {
	lights: [24]mb.Light
	count := 0

	// The sun, and the only light with a shadow map by default -- the shafts
	// through the wall slot are its shadow map seen edge-on.
	/*
		Dimmer than the first version, which had this at full white. A sun at
		1.0 plus a spot plus a point light drives every surface in the room past
		the top of the ACES curve, and a surface past the top of the curve is
		white whatever colour it started -- which is what "everything is white"
		was. 0.7 leaves headroom for the other two and for the emissive sphere,
		which is the one thing here that *should* clip.
	*/
	lights[count] = mb.create_directional_light(
		{-0.35, -0.85, -0.4}, {0.70, 0.66, 0.58, 1}, casts_shadow = true)
	count += 1

	// A spot swinging across the room, so the cone moves over the boxes and
	// the shadow technique has something changing to be judged on.
	angle := math.sin(time * 0.35) * 0.7
	lights[count] = mb.create_spot_light(
		position     = {6, 7, 6},
		direction    = {math.sin(angle) - 0.5, -1, math.cos(angle) - 1.4},
		color        = {0.35, 0.45, 0.65, 1},
		inner_angle  = 14,
		outer_angle  = 26,
		casts_shadow = true,
	)
	count += 1

	// A warm point light orbiting the sphere row, close enough that its
	// attenuation is visible across the sweep.
	orbit := time * 0.6
	/*
		The G key marks this one a caster, which is the only way to reach
		`Shadow_Technique.CUBE`: a point light shines in every direction at
		once, so it needs six shadow maps rather than one and is not one of
		the three choices the Y key cycles (see `Shadow_Technique`'s own doc
		comment). Six passes per frame instead of one, so it is worth
		watching what it costs.
	*/
	lights[count] = mb.create_point_light(
		{math.cos(orbit) * 3.5, 1.6, -3.0 + math.sin(orbit) * 1.5},
		{0.9, 0.45, 0.18, 1},
		casts_shadow = point_shadow)
	count += 1

	/*
		The N key's other stop: twenty small lights on a grid over the floor.

		This is the pair of pictures CLUSTERED exists for. Under FORWARD every
		one of these is evaluated for every fragment in the frame; under
		CLUSTERED only the ones whose reach covers that fragment's own cluster
		are. The picture is meant to be identical and the cost is not -- which
		is the half of P5's gate that a profiler can settle and an eye cannot.
	*/
	if many {
		for i in 0 ..< 20 {
			if count >= len(lights) do break

			fx := f32(i % 5) - 2
			fz := f32(i / 5) - 1.5

			hue := f32(i) * 0.31 + time * 0.2
			color := [4]f32{
				0.5 + 0.5 * math.sin(hue),
				0.5 + 0.5 * math.sin(hue + 2.1),
				0.5 + 0.5 * math.sin(hue + 4.2),
				1,
			}

			lights[count] = mb.create_point_light({fx * 3.2, 0.7, fz * 3.2 + 1}, color)
			count += 1
		}
	}

	mb.set_lights(lights[:count])
}

// -----------------------------------------------------------------------
// The readout
// -----------------------------------------------------------------------

// Off, warm-and-contrasty, cold-and-flat. Both graded stops are deliberately
// overdone: a tasteful grade and a grade that is not running look far too
// alike to tell apart from across a room.
grade_for :: proc(index: int) -> mb.Color_Grade {
	switch index {
	case 1:
		return {
			enabled    = true,
			gain       = {0.14, 0, -0.14},
			lift       = {0.01, 0, -0.02},
			contrast   = 0.25,
			saturation = 0.2,
		}
	case 2:
		return {
			enabled    = true,
			gain       = {-0.10, -0.02, 0.12},
			lift       = {0.05, 0.05, 0.07},
			contrast   = -0.18,
			saturation = -0.4,
		}
	}

	// The zero value, which `Color_Grade` guarantees is an exact no-op rather
	// than a grade that happens to be near one -- see post.odin.
	return {}
}

on_off :: proc(v: bool) -> string {
	return "on" if v else "off"
}

draw_readout :: proc(settings: mb.Lighting_Settings, model: mb.Shading_Model, grade_index: int, many: bool, point_shadow: bool, probes_baked: bool) {
	font := &mb.mbi.font

	mb.draw_text(font, "P pipeline   M shading model   H shadows   Y technique   G point shadow   K ambient   N light count", 20, 30, mb.WHITE)
	mb.draw_text(font, "O ssao   V volumetric   B bloom   C grade   T tonemap   F fog   L lighting   R bake probes   Z/X exposure", 20, 55, mb.WHITE)

	grades := [3]string{"off", "warm", "cold"}

	mb.draw_text(font, fmt.tprintf("pipeline %v      shading %v      lighting %v      lights %v",
		settings.pipeline,
		model,
		"on" if settings.enabled else "off (everything unlit)",
		"many" if many else "few"), 20, 95, mb.WHITE)

	mb.draw_text(font, fmt.tprintf("shadows %v (%v)      point shadow %v      ambient %v      fog %v",
		on_off(settings.shadows.enabled),
		settings.shadows.technique,
		on_off(point_shadow),
		settings.ambient.kind,
		on_off(settings.fog.enabled)), 20, 120, mb.WHITE)

	mb.draw_text(font, fmt.tprintf("ssao %v      volumetric %v      bloom %v      grade %v      tonemap %v      exposure %.2f",
		on_off(settings.ssao.enabled),
		on_off(settings.volumetric.enabled),
		on_off(settings.post.bloom.enabled),
		grades[grade_index],
		settings.tonemap,
		settings.exposure), 20, 145, mb.WHITE)

	mb.draw_text(font, fmt.tprintf("reflection probes %v, %v",
		mb.get_reflection_probe_count(),
		"captured (R to re-bake)" if probes_baked else "not captured yet -- press R"), 20, 170, mb.WHITE)

	/*
		Two lines that are hints rather than state, both for the same class of
		confusion: a module that is on, doing exactly what it should, and
		looking like it is broken because what it modifies is not there.

		Occlusion multiplies the ambient term, so SSAO with no ambient light
		has nothing to occlude. And a localized probe that was never captured
		holds nothing, so selecting ENVIRONMENT_PROBE before pressing R reads
		as "the ambient went out" rather than as "there is no probe".
	*/
	hint_y := f32(205)

	if settings.ssao.enabled && settings.ambient.kind == .CONSTANT && settings.ambient.color.r == 0 {
		mb.draw_text(font, "ssao is on but ambient is black -- there is nothing for it to occlude (press K)", 20, hint_y, {1, 0.7, 0.3, 1})
		hint_y += 25
	}

	if settings.ambient.kind == .ENVIRONMENT_PROBE && !probes_baked {
		mb.draw_text(font, "ambient is ENVIRONMENT_PROBE but no probe has been captured -- press R", 20, hint_y, {1, 0.7, 0.3, 1})
	}

	cx := f32(mb.mbi.width) * 0.5
	cy := f32(mb.mbi.height) * 0.5
	mb.draw_rect({position = {cx, cy}, size = {12, 2}, color = mb.WHITE})
	mb.draw_rect({position = {cx, cy}, size = {2, 12}, color = mb.WHITE})
}
