package matchbox

import "core:fmt"
import "core:math"

/*
	light
	=====

	Directional, point and spot lights and the scene's ambient, shared by every target (G2 L4-1,
	docs/3ds_fragment_lighting_plan.md). A game sets them whenever it likes; each camera_end
	turns them into the lights block its shaders read (`calculate_lights_block`), so a light
	stays put in the world while the camera moves.

	The block's shape is fixed by mbsc (tools/mbsc/lighting.odin): a slot per light, unused
	ones zero colour, directions towards the light in eye space. Eye space is the 3DS fragment
	lighting unit's convention (docs/shader_pica.md, "Fragment lighting (L0)"); PC and the Vita
	follow it so one block serves all three.

	Only what a part's material does not say lives here. Shininess and specular strength belong
	to the part (L4-2), so two models under one sun can shine differently.
*/

/*
	How many lights a game can set on every target: the 3DS's fragment lighting unit has 8, and
	the Vita matches it. A game meant for all three keeps to this.
*/
MAX_LIGHTS :: 8

/*
	PC has more (decided 2026-11-25: Matchbox need not target all three, and a PC-only game is
	not held to the handhelds' limit). MAX_PC_LIGHTS exists only in a Windows build, so a game
	that names it does not compile for the 3DS or the Vita, and choosing PC-only is visible in
	its code. A game that merely passes more than 8 lights still compiles there, and stops at
	set_lights' check instead.

	LIGHT_SLOT_COUNT is this target's number, which sizes the arrays below. It must equal what
	mbsc's get_max_lights says for the target, since mbsc writes the block the engine fills.
*/
when ODIN_OS == .Windows {
	MAX_PC_LIGHTS :: 64
	@(private)
	LIGHT_SLOT_COUNT :: MAX_PC_LIGHTS
} else {
	@(private)
	LIGHT_SLOT_COUNT :: MAX_LIGHTS
}

// What a light is: a sun, a bulb, or a torch with a cone.
Light_Kind :: enum {
	DIRECTIONAL, // a sun: a direction and no place, everything is lit from the same angle (the zero value)
	POINT, // a bulb: a place, shining every way, fading with distance
	SPOT, // a torch: a place and a direction, lit inside a cone, fading with distance and towards the cone's edge
}

/*
	A light. `diffuse` is the colour it gives a surface facing it, `specular` the colour of its highlights: two
	colours rather than one because the 3DS's unit holds them apart for free, and a warm light with white highlights
	is a common look. Which other fields count depends on `kind`; the create_ procedures fill them in.

	A point or spot light fades with distance as 1 / (1 + 0.09 d + 0.032 d^2), d in world units, the same on every
	light (the curve main's PsxGame lighting uses); there is no per-light range. Its highlight fades with it. A spot
	adds a smoothstep from full brightness at `inner_angle` to nothing at `outer_angle`.
*/
Light :: struct {
	kind:Light_Kind,
	direction:[3]f32, // DIRECTIONAL and SPOT: the way the light travels, world space; need not be unit length
	position:[3]f32, // POINT and SPOT: world space
	diffuse:[4]f32,
	specular:[4]f32,
	inner_angle:f32, // SPOT only, degrees from the axis: full brightness inside it
	outer_angle:f32, // SPOT only, degrees from the axis: faded to nothing by it
}

/*
	Where the light is worked out. Per pixel follows a highlight across a face; per vertex works
	it out at the corners and blends between them, which costs less and looks softer, and folds
	the highlight into the colour before the texture (mesh_vertex_lit.mbs says why). Per pixel is
	the zero value, so a scene that never chooses gets it
*/
Lighting_Mode :: enum {
	PER_PIXEL,
	PER_VERTEX,
}

// Settings that belong to the whole scene rather than to one light.
Lighting_Settings :: struct {
	/*
		Whether lit models are shaded at all. Off, they draw as they did before lighting
		existed: texture times tint. A separate switch rather than "lit when there are lights",
		so a scene whose only light is switched off goes dark instead of flipping back to
		unlit. That flip was a real bug on main (its lighting.odin, "the fix for both defects").
	*/
	enabled:bool,
	ambient:[4]f32, // the light every surface gets, whichever way it faces
	mode:Lighting_Mode, // for every part whose material doesn't choose (Material.lighting)
}

// What set_lights and set_lighting keep, held in mbi.lighting.
Lighting_State :: struct {
	settings:Lighting_Settings,
	lights:[LIGHT_SLOT_COUNT]Light,
	light_count:int,
}

/*
	The lights block as each target uploads it, in the order and layout of mbsc's (`lights_ambient`, then
	`lights_direction`, `_diffuse`, `_specular`, `_position` and `_cone`, and on PC `lights_count`). Every row is four
	floats, which suits HLSL's constant buffer packing and the PICA's vec4 registers alike.
*/
@(private)
Lights_Block :: struct {
	ambient:[4]f32,
	direction:[LIGHT_SLOT_COUNT][4]f32, // DIRECTIONAL: towards the light; SPOT: back along its axis, the way a sun's is; eye space, w = 0, unit length (the 3DS's vertex program has no instructions to spare for normalizing); zero when unused
	diffuse:[LIGHT_SLOT_COUNT][4]f32,
	specular:[LIGHT_SLOT_COUNT][4]f32,
	position:[LIGHT_SLOT_COUNT][4]f32, // eye space, w = the kind: 0 directional, 1 point, 2 spot
	cone:[LIGHT_SLOT_COUNT][4]f32, // SPOT: cos(outer angle), cos(inner angle), then k = 1 / (the difference) and -outer * k, so a shader works the cone out as cos * k + (-outer * k), two instructions on the 3DS where subtracting and scaling is three; zero otherwise
	/*
		Where the per-pixel shader loops stop on PC and the Vita, so a scene with one sun doesn't pay for 64 slots
		(PC) or for eight on every pixel (the Vita's fragment cost is what a lit draw is bound by). The 3DS's
		per-vertex loop runs all 8 and doesn't read it. The padding fills the row, as HLSL rounds
		a constant buffer up to whole rows of 16 bytes.
	*/
	count:i32,
	_padding:[3]i32,
}

// create_directional_light makes a sun shining along `direction`, `color` used for both its diffuse and highlights.
create_directional_light :: proc(direction:[3]f32, color:[4]f32 = WHITE) -> Light {
	return Light{kind = .DIRECTIONAL, direction = direction, diffuse = color, specular = color}
}

// create_point_light makes a bulb at `position` shining every way, `color` used for both its diffuse and highlights.
create_point_light :: proc(position:[3]f32, color:[4]f32 = WHITE) -> Light {
	return Light{kind = .POINT, position = position, diffuse = color, specular = color}
}

// create_spot_light makes a torch at `position` shining along `direction`, full brightness inside `inner_angle` degrees of the axis and none past `outer_angle`.
create_spot_light :: proc(position, direction:[3]f32, color:[4]f32 = WHITE, inner_angle:f32 = 20, outer_angle:f32 = 30) -> Light {
	return Light{kind = .SPOT, position = position, direction = direction, diffuse = color, specular = color, inner_angle = inner_angle, outer_angle = outer_angle}
}

/*
	set_lights replaces the scene's lights with `lights`. Call it again whenever they change;
	the camera_end after it uses them. More than get_max_lights() (8, or MAX_PC_LIGHTS on PC) is
	a mistake rather than something to trim quietly: which lights were dropped would be a guess
	the game never sees.

		mb.set_lights({mb.create_directional_light({-1, -2, -1})})
*/
set_lights :: proc(lights:[]Light) {
	if len(lights) > LIGHT_SLOT_COUNT {
		message := fmt.tprintf("set_lights: %d lights given, this target takes %d", len(lights), LIGHT_SLOT_COUNT)
		print(message) // the print log keeps it; the panic carries it too, as a 3DS crash screen replaces the print log
		panic(message)
	}
	mbi.lighting.lights = {}
	copy(mbi.lighting.lights[:], lights)
	mbi.lighting.light_count = len(lights)
}

/*
	set_lighting sets what belongs to the whole scene, and turns lighting on unless told not to.
	The whole struct is replaced each call, like set_lights replaces the whole list.
*/
set_lighting :: proc(settings := Lighting_Settings{enabled = true, ambient = {0.2, 0.2, 0.2, 1}}) {
	mbi.lighting.settings = settings
}

// get_max_lights is how many lights set_lights takes on this target: MAX_LIGHTS (8) on the 3DS and the Vita, MAX_PC_LIGHTS (64) on PC.
get_max_lights :: proc() -> int {
	return LIGHT_SLOT_COUNT
}

// calculate_unit_direction makes a direction unit length, a zero one staying zero rather than becoming a NaN.
@(private)
calculate_unit_direction :: proc(direction:[3]f32) -> [4]f32 {
	length_squared := direction.x * direction.x + direction.y * direction.y + direction.z * direction.z
	if length_squared < 1e-24 do return {}
	unit := direction / math.sqrt(length_squared)
	return {unit.x, unit.y, unit.z, 0}
}

// calculate_lights_block turns the scene's lights into the block a camera's shaders read, in eye space: a direction with w = 0 so the view's translation stays out, a position with w = 1.
@(private)
calculate_lights_block :: proc(lighting:Lighting_State, view:matrix[4,4]f32) -> Lights_Block {
	block:Lights_Block
	block.ambient = lighting.settings.ambient
	block.count = i32(lighting.light_count)
	for slot in 0 ..< lighting.light_count {
		light := lighting.lights[slot]
		block.diffuse[slot] = light.diffuse
		block.specular[slot] = light.specular
		kind := f32(int(light.kind))
		block.position[slot].w = kind
		switch light.kind {
		case .DIRECTIONAL:
			// reversed, to point towards the light
			towards := view * [4]f32{-light.direction.x, -light.direction.y, -light.direction.z, 0}
			block.direction[slot] = calculate_unit_direction(towards.xyz)
		case .POINT, .SPOT:
			place := view * [4]f32{light.position.x, light.position.y, light.position.z, 1}
			block.position[slot] = {place.x, place.y, place.z, kind}
			if light.kind == .SPOT {
				// reversed, like a sun's, so a shader reads the cosine of the angle from the axis as one dot product
				axis := view * [4]f32{-light.direction.x, -light.direction.y, -light.direction.z, 0}
				block.direction[slot] = calculate_unit_direction(axis.xyz)
				outer, inner := math.cos(math.to_radians(light.outer_angle)), math.cos(math.to_radians(light.inner_angle))
				scale := 1 / max(inner - outer, 1e-6)
				block.cone[slot] = {outer, inner, scale, -outer * scale}
			}
		}
	}
	return block
}

/*
	get_lighting_mode is how a part with this material is lit: the material's own choice, or the
	scene's when it has none. Read at draw time, so a game changing either sees it the next frame
*/
get_lighting_mode :: proc(material:Material) -> Lighting_Mode {
	return material.lighting.? or_else mbi.lighting.settings.mode
}
