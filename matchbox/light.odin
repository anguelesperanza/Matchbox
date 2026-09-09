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

	`casts_shadow` only ever does anything for a directional or spot light --
	see shadow.odin for why a point light's shadow is not built -- and only
	once `Lighting_Settings.shadows.enabled` is also true (`set_lighting`,
	lighting.odin). Marking a light this way with shadows off is inert rather
	than an error, the same "opt-in, nothing happens until both switches are
	on" shape shadows have always had in this package.

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
	s.caster_indices = {-1, -1}
	found := 0

	for light in lights {
		if !light.enabled do continue

		index := len(l.light_data)
		append(&l.light_data, light_uniform(light))

		// Which of the (up to MAX_SHADOW_CASTERS) uploaded lights, by the
		// index they actually land at once disabled ones are dropped -- not
		// their index in `lights`, which shadow_visibility (lighting_core.hlsli)
		// never sees. A third casts_shadow light beyond the first two found
		// degrades silently, the same as an unsupported point-light shadow
		// already does elsewhere in this package.
		if light.casts_shadow && found < MAX_SHADOW_CASTERS {
			s.caster_indices[found] = index
			found += 1
		}
	}

	upload_light_buffer()
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
