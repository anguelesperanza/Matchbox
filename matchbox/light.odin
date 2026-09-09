package matchbox

/*
	Lights
	------
	What a 3D scene is lit by.

	**Lighting itself is scene state, not a count.** Before this file, a call
	to `set_lights` with anything in it also turned the whole lighting model
	on, and an empty list turned it off in favour of a fixed hard-coded
	direction -- see `lighting_rework.md` section 1's first defect. That
	coupling is gone: whether lighting runs at all is `Lighting_Settings.enabled`
	(`lighting.odin`), set once via `set_lighting`, and a material that wants
	no lighting says so itself with `Shading_Model.UNLIT`
	(`create_material_unlit`, `material.odin`). `set_lights` now only ever
	means "these are the lights in the scene" -- nothing about their count
	changes what shading model anything runs.

	**Unbounded**, where the old version capped at `MAX_LIGHTS` (16) inside a
	fixed cbuffer array. The array is gone -- lights are a `StructuredBuffer`
	now, the same move `Skin_Vert_Data` made for the joint palette when it hit
	SDL's Vulkan uniform sectioning (see that struct's own comment in
	types.odin) -- so there is no cap to document or hit. An unbounded list is
	also a hard prerequisite for clustered light culling later
	(`lighting_rework.md` section 3.3), which is why this happens now rather
	than being deferred alongside it.

	NOTE: The rlights.odin was originally a file from github that was then used as base
	for Matchbox's lights implementation https://github.com/Bigfoot71/rlights.git
	I do not remember where I got the original rlights.odin from sadly as that was closer to the start of 2026

	(Might move this credit into the README.md with the rest of the credit)
*/

import "core:log"

import sdl "vendor:sdl3"

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

	The zero value is a disabled light, which is what makes handing `set_lights`
	a slice that includes one the game built but has not turned on yet do the
	obvious thing -- `set_lights` drops a disabled light rather than uploading
	sixty-four zeroed bytes for it.

	`casts_shadow` means a directional or spot light is routed into one of the
	`MAX_SHADOW_CASTERS` two-dimensional-map slots, run through whichever of
	`Shadow_Technique.PCF`/`.PCSS`/`.CASCADED` the scene picked, and a point
	light into the single cube-map slot (`MAX_POINT_SHADOW_CASTERS`) instead,
	always -- see `Shadow_Technique`'s own doc comment (shadow.odin) for why
	cube shadows are not one of that field's values, and `shadow_cube.odin`
	for why a point light was never eligible for the first shape at all.
	Either way it only does anything once
	`Lighting_Settings.shadows.enabled` is also true (`set_lighting`,
	lighting.odin). Marking a light this way with shadows off is inert rather
	than an error, the same "opt-in, nothing happens until both switches are
	on" shape shadows have always had in this package.

	`inner_angle`/`outer_angle` only ever mean anything for a spotlight -- see
	`create_spot_light`.

	`shadow_bias` overrides `Shadow_Settings.bias` (shadow.odin) for this light
	alone, field by field -- zero in either component of it means "use the
	scene's own default", the same rule `shadow_settings_normalized` already
	applies to the scene-wide value this falls back to. Left zero, as every
	constructor below leaves it, a light just uses whatever the scene picked;
	set it when one particular light's own geometry needs more (or less)
	clearance than the rest of the scene -- a light that mostly grazes its own
	occluders' surfaces is the case `Shadow_Bias.normal_offset`'s own doc
	comment names as needing more than a scene-wide number tuned for the
	common case.
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
	shadow_bias:  Shadow_Bias, // zero means "use Shadow_Settings.bias" -- see this struct's own doc comment
}

/*
	A point light at `position`. The common case, and the one the campfire is.

	`casts_shadow` builds a real cube shadow map around this light --
	`shadow_cube.odin` -- which is new in P3: before this phase a point light
	had no way to cast one at all (see shadow.odin's own history of that
	degrade). Six depth renders instead of one, since the
	light radiates in every direction rather than down one axis or into one
	cone, so this is markedly more expensive than a directional or spot
	light's own shadow -- see shadow_cube.odin's own top comment for the
	SDL_GPU limitation that forced six separate maps rather than one real
	cube-mapped render target.
*/
create_point_light :: proc(position: [3]f32, color: [4]f32 = WHITE, casts_shadow := false) -> Light {
	return Light{kind = .POINT, position = position, color = color, enabled = true, casts_shadow = casts_shadow}
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
	the same curve a point light's own does -- see `brdf/blinn_phong.hlsli`'s
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
	Sets every light in the scene at once, replacing whatever was there.

	Unbounded -- see this file's own top comment -- and disabled lights are
	dropped rather than uploaded, so a caller may freely hand over a slice
	that includes lights it built but has not turned on. Call it every frame
	if the lights move; it rewrites a GPU buffer through a persistent transfer
	buffer rather than reallocating one; growing past the current capacity is
	the one time that costs a real allocation, the same "grown on demand,
	never shrunk" shape `ensure_identity_joint_buffer` already has.

		matchbox.set_lights({matchbox.create_point_light(fire_position, ember)})

	Does **not** turn lighting on -- see `set_lighting`. A scene with lights
	set and `Lighting_Settings.enabled == false` renders every material as if
	it were `Shading_Model.UNLIT`; see that struct's own doc comment.
*/
set_lights :: proc(lights: []Light) {
	l := &mbi.renderer.lighting
	s := &l.shadow

	clear(&l.light_data)
	s.caster_indices     = {-1, -1}
	s.cube_caster_index  = {-1}
	found      := 0
	found_cube := 0

	default_bias := s.settings.bias

	for light in lights {
		if !light.enabled do continue

		index := len(l.light_data)
		append(&l.light_data, light_uniform(light, default_bias))

		if !light.casts_shadow do continue

		/*
			Routed by kind, not by arrival order: a point light was never
			eligible for the two `PCF`/`PCSS`/`CASCADED` slots below (see
			shadow.odin's own top comment), so it goes into the single cube
			slot instead. A third directional/spot caster beyond
			MAX_SHADOW_CASTERS, or a second point-light caster beyond
			MAX_POINT_SHADOW_CASTERS, each degrade silently -- the same shape
			an unsupported combination already gets elsewhere in this package.
		*/
		switch light.kind {
		case .POINT:
			if found_cube < MAX_POINT_SHADOW_CASTERS {
				s.cube_caster_index[found_cube] = index
				found_cube += 1
			}
		case .DIRECTIONAL, .SPOT:
			if found < MAX_SHADOW_CASTERS {
				s.caster_indices[found] = index
				found += 1
			}
		}
	}

	upload_light_buffer()
}

// -----------------------------------------------------------------------
// Internals
// -----------------------------------------------------------------------

/*
	`default_bias` is the scene's own `Shadow_Settings.bias`, as last resolved
	by `set_lighting` -- passed in rather than read off `mbi` directly so this
	stays a pure function of its arguments, the same reason `material_frag_data`
	takes `tint` as a parameter instead of reaching for global draw state.
	`set_lights` is the one caller, and it already has `mbi.renderer.lighting.
	shadow.settings.bias` in hand.
*/
@(private)
light_uniform :: proc(light: Light, default_bias: Shadow_Bias) -> Light_Uniform {
	kind_flag: f32
	switch light.kind {
	case .DIRECTIONAL: kind_flag = 0
	case .POINT:        kind_flag = 1
	case .SPOT:         kind_flag = 2
	}

	// Per field, not "both zero or neither" -- a light might want a wider
	// normal-offset than the scene default while leaving its depth bias
	// alone, and there is no reason to force the two to be overridden
	// together. Mirrors shadow_settings_normalized's own per-field zero
	// handling, applied here instead of at store time because a Light
	// belongs to whoever built it -- see Light_Uniform's own doc comment
	// (types.odin) for why this is resolved at pack time rather than stored
	// back.
	bias := light.shadow_bias
	if bias.depth         == 0 do bias.depth         = default_bias.depth
	if bias.normal_offset == 0 do bias.normal_offset = default_bias.normal_offset

	return Light_Uniform{
		position    = {light.position.x, light.position.y, light.position.z, 1 if light.enabled else 0},
		target      = {light.target.x, light.target.y, light.target.z, kind_flag},
		color       = light.color,
		cone        = {light.outer_angle, light.inner_angle, 0, 0},
		shadow_bias = {bias.depth, bias.normal_offset, 0, 0},
	}
}

/*
	Rewrites `light_buffer` from `light_data`, growing it first if the CPU
	list no longer fits.

	The same shape `update_animator` already established for the joint
	palette: a device buffer plus a persistent transfer buffer, rewritten
	through `rewrite_buffer` rather than recreated, because the common case is
	the same handful of lights moving every frame and not the count changing.
	Growth releases the old pair and makes a bigger one -- never smaller, so a
	scene that briefly has many lights and then few does not pay for a
	reallocation on the way back down.

	At least one element's worth of capacity always exists once a device is
	present, even with zero lights set: the fragment shader declares a
	`StructuredBuffer<Light>` unconditionally, the same reason `init` makes
	1x1 placeholder shadow maps so a game that never calls `enable_shadows`
	-- now `set_lighting` -- still has something valid bound.
*/
@(private)
upload_light_buffer :: proc() {
	l := &mbi.renderer.lighting
	if mbi.renderer.device == nil do return

	// At least one element even with nothing set -- see this proc's own doc
	// comment on why the buffer may never be empty. The scratch element is
	// never read by anything: flags.x (Lighting_Settings, pushed by
	// push_lighting) is 0 whenever light_data is, and shade_surface's light
	// loop runs zero iterations rather than reading it.
	scratch := [1]Light_Uniform{}
	data    := l.light_data[:] if len(l.light_data) > 0 else scratch[:]
	size    := u32(len(data)) * size_of(Light_Uniform)

	if len(data) > l.light_capacity {
		if l.light_buffer   != nil do sdl.ReleaseGPUBuffer(mbi.renderer.device, l.light_buffer)
		if l.light_transfer != nil do sdl.ReleaseGPUTransferBuffer(mbi.renderer.device, l.light_transfer)
		l.light_buffer, l.light_transfer, l.light_capacity = nil, nil, 0

		buffer, err := upload_buffer(raw_data(data), size, {.GRAPHICS_STORAGE_READ})
		if err != nil {
			log.errorf("could not create the light buffer: %v", err)
			return
		}

		l.light_buffer   = buffer
		l.light_transfer = sdl.CreateGPUTransferBuffer(mbi.renderer.device, {usage = .UPLOAD, size = size})
		l.light_capacity = len(data)
		return // upload_buffer already wrote this frame's data; no rewrite needed
	}

	if l.light_buffer == nil || l.light_transfer == nil do return

	// Only `size` bytes are written even though the buffer may have more
	// capacity than that (light_capacity only ever grows) -- whatever is
	// past them is stale data from a previous, longer light list, and
	// nothing reads past flags.x (Lighting_Settings, pushed by push_lighting)
	// lights regardless.
	if err := rewrite_buffer(l.light_buffer, l.light_transfer, raw_data(data), size); err != nil {
		log.errorf("could not update the light buffer: %v", err)
	}
}
