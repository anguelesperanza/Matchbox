package matchbox

/*
	Lights and fog
	--------------
	What a 3D scene is lit by, and what it fades into at a distance.

	**Lighting is opt-in.** A game that never touches any of this gets the fixed
	shading every 3D draw had before lights existed: one direction, hard-coded
	in the shader, enough to tell the faces of a cube apart. The moment one
	enabled light is set, the real model takes over -- diffuse, specular,
	distance attenuation, ambient, and gamma. The alternative, where no lights
	means no light, would have turned every scene written up to now black.

	The model is PsxGame's, ported constant for constant: the same attenuation
	curve, the same specular exponent, the same ambient divided by ten, the same
	gamma before fog. A game moving over should look the way it already looks.

	**Four lights.** That is what `rlights.odin` allows and more than either game
	uses -- the campfire is one. A fixed-size uniform block is the reason: four
	lights are 192 bytes pushed once a pass, where an unbounded number would mean
	a storage buffer and a bindless path for a feature nothing has asked for.
*/

import sdl "vendor:sdl3"

MAX_LIGHTS :: 16

Light_Kind :: enum {
	DIRECTIONAL, // a direction only; distance does not matter
	POINT,       // a place, which things get dimmer further from
	SPOT,        // a place that only shines within a cone around a direction
}

/*
	One light.

	`target` is what a directional light points at -- the direction is
	`target - position`, so moving both moves nothing. A spotlight reuses the
	same field the same way: `target` is the direction its cone points, not a
	place it aims at, so a spotlight's own `position` is not involved in
	reading it back out. A point light ignores it.

	The zero value is a disabled light, which is what makes `set_lights` with a
	short slice do the obvious thing.

	`casts_shadow` only ever does anything for a directional or spot light --
	see shadow.odin for why a point light's shadow is not built -- and only
	once `enable_shadows` has also been called. Marking a light this way with
	shadows never enabled is inert rather than an error, the same "opt-in,
	nothing happens until both switches are on" shape `enable_shadows` itself
	has.

	`inner_angle`/`outer_angle` only ever mean anything for a spotlight -- see
	`create_spot_light`.
*/
Light :: struct {
	kind:         Light_Kind,
	position:     [3]f32,
	target:       [3]f32,
	color:        [4]f32,
	enabled:      bool,
	casts_shadow: bool,
	inner_angle:  f32, // spot only, degrees -- full brightness inside this
	outer_angle:  f32, // spot only, degrees -- faded to nothing by this
}

// A point light at `position`. The common case, and the one the campfire is.
create_point_light :: proc(position: [3]f32, color: [4]f32 = WHITE) -> Light {
	return Light{kind = .POINT, position = position, color = color, enabled = true}
}

// A light shining along `direction`, from nowhere in particular. A sun.
create_directional_light :: proc(direction: [3]f32, color: [4]f32 = WHITE, casts_shadow := false) -> Light {
	return Light{
		kind = .DIRECTIONAL, position = {0, 0, 0}, target = direction, color = color,
		enabled = true, casts_shadow = casts_shadow,
	}
}

/*
	A cone of light at `position`, pointing along `direction`. Distance fades
	the same curve a point light's own does -- see `lighting.hlsli`'s
	attenuation -- the cone is an extra factor on top of that, not a
	replacement for it.

	`inner_angle` is where the cone is still at full brightness; it fades from
	there out to `outer_angle`, both in degrees and measured from the cone's
	own axis to its edge, not corner to corner. A flashlight wants these
	fairly narrow -- the 20/30 default is a tight beam, not a floodlight.

	`casts_shadow` builds a perspective shadow frustum sized to the cone --
	`fov = outer_angle * 2` -- from the spotlight's own real position, rather
	than the camera-centred trick a directional light's shadow needs for
	having none. See `Light`'s own doc comment for the same "opt-in twice"
	contract every shadow-casting light has.
*/
create_spot_light :: proc(
	position:     [3]f32,
	direction:    [3]f32,
	color:        [4]f32 = WHITE,
	inner_angle:  f32 = 20,
	outer_angle:  f32 = 30,
	casts_shadow: bool = false,
) -> Light {
	return Light{
		kind = .SPOT, position = position, target = direction, color = color,
		enabled = true, casts_shadow = casts_shadow,
		inner_angle = inner_angle, outer_angle = outer_angle,
	}
}

/*
	Sets every light at once, and turns lighting on.

	Up to `MAX_LIGHTS` of them; anything past that is ignored, and anything short
	leaves the rest disabled. Call it every frame if the lights move -- it copies
	into a block that is pushed at the start of the next 3D pass, so there is no
	GPU work here and no cost to setting the same thing repeatedly.

		matchbox.set_lights({matchbox.create_point_light(fire_position, ember)})
*/
set_lights :: proc(lights: []Light) {
	l := &mbi.renderer.lighting
	s := &mbi.renderer.shadow

	count := min(len(lights), MAX_LIGHTS)

	for i in 0 ..< MAX_LIGHTS {
		if i < count {
			l.lights[i]             = light_uniform(lights[i])
			s.light_casts_shadow[i] = lights[i].casts_shadow
		} else {
			l.lights[i]             = {}
			s.light_casts_shadow[i] = false
		}
	}

	// How many were handed over, not how many are switched on: a game that sets
	// one light and disables it wants a dark scene, not the fallback shading.
	l.flags.x = f32(count)

	recompute_shadow_casters()
}

// One light, by slot, leaving the others alone. For a scene that turns a single
// lamp on and off without rebuilding the list.
set_light :: proc(index: int, light: Light) {
	if index < 0 || index >= MAX_LIGHTS do return

	l := &mbi.renderer.lighting
	s := &mbi.renderer.shadow

	l.lights[index]             = light_uniform(light)
	s.light_casts_shadow[index] = light.casts_shadow
	l.flags.x = max(l.flags.x, f32(index + 1))

	recompute_shadow_casters()
}

/*
	Back to the fixed shading that needs no lights.

	Not the same as setting four disabled lights, which is a scene lit by
	nothing and therefore black.
*/
clear_lights :: proc() {
	l := &mbi.renderer.lighting
	s := &mbi.renderer.shadow

	l.lights  = {}
	l.flags.x = 0

	s.light_casts_shadow = {}
	s.caster_indices     = {-1, -1}
}

/*
	Which of `Lighting_Data.lights`, if any, cast a shadow -- up to
	`MAX_SHADOW_CASTERS` enabled lights marked `casts_shadow`, by slot order.
	Recomputed after every change to the light list rather than
	incrementally, since four lights is cheap enough to scan outright and
	"the first two matches" is otherwise a subtle thing to keep correct
	through `set_light` touching one slot at a time.

	`-1` (no caster) in either slot is what makes marking a light
	`casts_shadow` harmless before `enable_shadows` is ever called:
	`push_lighting` only trusts these values when `mbi.renderer.shadow.enabled`
	is also true, so this alone never points the shader at a shadow map that
	was never actually rendered into. A third `casts_shadow` light beyond the
	first two found is not an error, the same silent degrade a point light's
	own `casts_shadow` would be if one were hand-built with it set.
*/
@(private)
recompute_shadow_casters :: proc() {
	l := &mbi.renderer.lighting
	s := &mbi.renderer.shadow

	s.caster_indices = {-1, -1}
	found := 0
	for i in 0 ..< MAX_LIGHTS {
		if found >= MAX_SHADOW_CASTERS do break
		if l.lights[i].position.w >= 0.5 && s.light_casts_shadow[i] {
			s.caster_indices[found] = i
			found += 1
		}
	}
}

/*
	The light that reaches everything regardless of where it faces.

	Divided by ten inside the shader, which is PsxGame's scaling and is kept so
	that a value carried over from there means the same thing.
*/
set_ambient :: proc(color: [4]f32) {
	mbi.renderer.lighting.ambient = color
}

/*
	Distance fade: nothing changes nearer than `start`, everything is `color` by
	`end`.

	Fog is what makes a dark scene readable rather than a black one with objects
	popping out of it, and it is most of the mood in PsxGame -- there it is a
	dark blue from 3 units to 12.
*/
set_fog :: proc(color: [4]f32, start, end: f32) {
	l := &mbi.renderer.lighting

	l.fog_color = color
	l.fog_range = {start, max(end, start + 0.001), 0, 0} // never divide by zero
	l.flags.y   = 1
}

// Turns fog off, leaving its colour and range where they were.
disable_fog :: proc() {
	mbi.renderer.lighting.flags.y = 0
}

// Whether a game has set any lights. Mostly for an example that wants to say so
// on screen.
is_lighting_active :: proc() -> bool {
	return mbi.renderer.lighting.flags.x > 0
}

// -----------------------------------------------------------------------
// Internals
// -----------------------------------------------------------------------

@(private)
light_uniform :: proc(light: Light) -> Light_Uniform {
	kind_flag: f32
	switch light.kind {
	case .DIRECTIONAL: kind_flag = 0
	case .POINT:        kind_flag = 1
	case .SPOT:         kind_flag = 2
	}

	return Light_Uniform{
		position = {light.position.x, light.position.y, light.position.z, 1 if light.enabled else 0},
		target   = {light.target.x, light.target.y, light.target.z, kind_flag},
		color    = light.color,
		cone     = {light.outer_angle, light.inner_angle, 0, 0},
	}
}

/*
	Hands the whole block to the GPU, with the camera filled in.

	Called by `begin_drawing_3d` rather than by the setters, for two reasons: the
	view position is the pass's business and not the game's, and a uniform push
	needs a command buffer, which only exists inside a frame. A game may
	therefore set lights whenever it likes, including before `begin_drawing`.

	Fragment slot 1. Slot 0 is the per-draw tint, pushed once per part.
*/
@(private)
push_lighting :: proc(camera: Camera3D) {
	r := &mbi.renderer

	r.lighting.view_pos = {camera.position.x, camera.position.y, camera.position.z, 0}

	/*
		-1 in both slots whenever shadows are not enabled, even if lights are
		marked `casts_shadow` and `caster_indices` names them -- the shadow
		maps are 1x1 placeholders, never rendered into, until `enable_shadows`
		builds real ones, and the shader must never be told to trust them.
	*/
	r.lighting.flags.z          = f32(r.shadow.caster_indices[0]) if r.shadow.enabled else -1
	r.lighting.flags.w          = r.shadow.settings.bias
	r.lighting.shadow_caster1.x = f32(r.shadow.caster_indices[1]) if r.shadow.enabled else -1
	r.lighting.light_view_projection  = r.shadow.view_projections[0]
	r.lighting.light_view_projection2 = r.shadow.view_projections[1]

	sdl.PushGPUFragmentUniformData(r.cmd, 1, &r.lighting, size_of(Lighting_Data))
}
