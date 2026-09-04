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

MAX_LIGHTS :: 4

Light_Kind :: enum {
	DIRECTIONAL, // a direction only; distance does not matter
	POINT,       // a place, which things get dimmer further from
}

/*
	One light.

	`target` is what a directional light points at -- the direction is
	`target - position`, so moving both moves nothing. A point light ignores it.

	The zero value is a disabled light, which is what makes `set_lights` with a
	short slice do the obvious thing.
*/
Light :: struct {
	kind:     Light_Kind,
	position: [3]f32,
	target:   [3]f32,
	color:    [4]f32,
	enabled:  bool,
}

// A point light at `position`. The common case, and the one the campfire is.
create_point_light :: proc(position: [3]f32, color: [4]f32 = WHITE) -> Light {
	return Light{kind = .POINT, position = position, color = color, enabled = true}
}

// A light shining along `direction`, from nowhere in particular. A sun.
create_directional_light :: proc(direction: [3]f32, color: [4]f32 = WHITE) -> Light {
	return Light{kind = .DIRECTIONAL, position = {0, 0, 0}, target = direction, color = color, enabled = true}
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

	count := min(len(lights), MAX_LIGHTS)

	for i in 0 ..< MAX_LIGHTS {
		l.lights[i] = light_uniform(lights[i]) if i < count else {}
	}

	// How many were handed over, not how many are switched on: a game that sets
	// one light and disables it wants a dark scene, not the fallback shading.
	l.flags.x = f32(count)
}

// One light, by slot, leaving the others alone. For a scene that turns a single
// lamp on and off without rebuilding the list.
set_light :: proc(index: int, light: Light) {
	if index < 0 || index >= MAX_LIGHTS do return

	l := &mbi.renderer.lighting
	l.lights[index] = light_uniform(light)
	l.flags.x = max(l.flags.x, f32(index + 1))
}

/*
	Back to the fixed shading that needs no lights.

	Not the same as setting four disabled lights, which is a scene lit by
	nothing and therefore black.
*/
clear_lights :: proc() {
	l := &mbi.renderer.lighting

	l.lights  = {}
	l.flags.x = 0
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
lighting_active :: proc() -> bool {
	return mbi.renderer.lighting.flags.x > 0
}

// -----------------------------------------------------------------------
// Internals
// -----------------------------------------------------------------------

@(private)
light_uniform :: proc(light: Light) -> Light_Uniform {
	return Light_Uniform{
		position = {light.position.x, light.position.y, light.position.z, 1 if light.enabled else 0},
		target   = {light.target.x, light.target.y, light.target.z, 0 if light.kind == .DIRECTIONAL else 1},
		color    = light.color,
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

	sdl.PushGPUFragmentUniformData(r.cmd, 1, &r.lighting, size_of(Lighting_Data))
}
