package matchbox

/*
	light
	=====

	Directional lights and the scene's ambient, shared by every target (G2 L4-1,
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

/*
	A light shining along `direction`, from nowhere in particular: a sun. `diffuse` is the
	colour it gives a surface facing it, `specular` the colour of its highlights. Two colours
	rather than one because the 3DS's unit holds them apart for free, and a warm sun with white
	highlights is a common look; create_directional_light sets both from one colour.
*/
Light :: struct {
	direction:[3]f32, // the way the light travels, world space; need not be unit length
	diffuse:[4]f32,
	specular:[4]f32,
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
	The lights block as each target uploads it, in the order and layout of mbsc's
	(`lights_ambient`, `lights_direction`, `lights_diffuse`, `lights_specular`, and on PC
	`lights_count`). Every row is four floats, which suits HLSL's constant buffer packing and the
	PICA's vec4 registers alike.
*/
Lights_Block :: struct {
	ambient:[4]f32,
	direction:[LIGHT_SLOT_COUNT][4]f32, // towards the light, eye space, w = 0; zero in an unused slot
	diffuse:[LIGHT_SLOT_COUNT][4]f32,
	specular:[LIGHT_SLOT_COUNT][4]f32,
	/*
		Where PC's shader loops stop, so a scene with one sun doesn't pay for 64 slots. The
		handhelds' loops run all 8 and don't read it. The padding fills the row, as HLSL rounds
		a constant buffer up to whole rows of 16 bytes.
	*/
	count:i32,
	_padding:[3]i32,
}

// create_directional_light makes a sun shining along `direction`, `color` used for both its diffuse and highlights.
create_directional_light :: proc(direction:[3]f32, color:[4]f32 = WHITE) -> Light {
	return Light{direction = direction, diffuse = color, specular = color}
}

/*
	set_lights replaces the scene's lights with `lights`. Call it again whenever they change;
	the camera_end after it uses them. More than get_max_lights() (8, or MAX_PC_LIGHTS on PC) is
	a mistake rather than something to trim quietly: which lights were dropped would be a guess
	the game never sees.

		mb.set_lights({mb.create_directional_light({-1, -2, -1})})
*/
set_lights :: proc(lights:[]Light) {
	ensure(len(lights) <= LIGHT_SLOT_COUNT, "set_lights: more lights than get_max_lights()")
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

/*
	calculate_lights_block turns the scene's lights into the block a camera's shaders read.
	A light's direction is reversed to point towards it, then turned by the view's rotation;
	w = 0 keeps the view's translation out, as a direction has no position to move. Takes the
	state rather than reading mbi so it is the same maths on every target and in a test.
*/
calculate_lights_block :: proc(lighting:Lighting_State, view:matrix[4,4]f32) -> Lights_Block {
	block:Lights_Block
	block.ambient = lighting.settings.ambient
	block.count = i32(lighting.light_count)
	for slot in 0 ..< lighting.light_count {
		light := lighting.lights[slot]
		towards := view * [4]f32{-light.direction.x, -light.direction.y, -light.direction.z, 0}
		block.direction[slot] = {towards.x, towards.y, towards.z, 0}
		block.diffuse[slot] = light.diffuse
		block.specular[slot] = light.specular
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
