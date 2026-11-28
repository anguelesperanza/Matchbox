package matchbox

import "core:fmt"
import "core:math"
import "core:math/linalg"

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
	AREA_RECT, // PC only: a flat rectangle shining from its front face (`direction` is the way it faces). Elsewhere it is a point light at its centre
	AREA_DISK, // PC only: the same as a disk of radius `area_size.x`. Elsewhere a point light
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
	right:[3]f32, // AREA_RECT and AREA_DISK: the way the shape's width runs, world space, at right angles to `direction`; need not be unit length
	area_size:[2]f32, // AREA_RECT: half the width and half the height; AREA_DISK: the radius in x
	/*
		PC only: this light throws shadows of what was queued under set_shadow_casting(true). One light does it, the first in the list that
		asks and is a sun or a spot: a point or area light would need a map for every direction, and more than one caster a map each. The
		handhelds ignore it
	*/
	casts_shadow:bool,
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

/*
	The curve that brings a lit colour, which may be brighter than a screen can show, back into range (PC only; after the
	exposure). NONE just clamps, which is how the scene looked before tonemaps existed. AGX is the one with the gentlest
	highlights. The handhelds' lighting is already clamped by their hardware and ignores this
*/
Tonemap :: enum {
	NONE,
	REINHARD,
	ACES,
	AGX,
}

/*
	Distance fog, on lit models (PC only): nothing nearer than `start` world units from the camera, everything `color` by `end`,
	a straight blend between. It is applied after the tonemap, so `color` reaches the screen as written. The zero value is off
*/
Fog_Settings :: struct {
	enabled:bool,
	color:[4]f32,
	start:f32,
	end:f32,
}

/*
	How the one shadow is made (PC only; Light.casts_shadow). Zero in a field means "the default", not zero, since a map of no texels or a
	volume of no size is not something anyone is asking for; the defaults are in the comments.
*/
Shadow_Settings :: struct {
	resolution:int, // texels along a side of the shadow map; 2048. A bigger one is sharper and costs memory and fill
	/*
		What the map covers. A sun's map is a box, `radius` world units either side of `center` and as deep, which is as sharp as it is
		small: put it where the player is, not around the whole level. A spot's covers its own cone out to `radius` from the light.
		Outside it nothing is shadowed. 20 units
	*/
	center:[3]f32,
	radius:f32,
	depth_bias:f32, // how much nearer to the light than the map a point must be to count as lit, in the map's 0..1 depth; 0.002. Too small stripes surfaces, too big lifts shadows off their casters
	normal_offset:f32, // how far, world units, a point is pushed out along its normal before it is looked up, which cures the stripes on slopes the depth bias cannot; 0.02
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
	ambient:[4]f32, // the light every surface gets, whichever way it faces; with `hemisphere`, the colour of the sky
	/*
		PC only, and the zero value of each means "as before": a flat ambient, no fog, an exposure of 1 and no tonemap, so a scene
		that never heard of them draws as it always did. They are applied by the lit shaders (light_finish in mbsc), so an unlit model, a
		sprite, text and the skybox are left alone
	*/
	hemisphere:bool, // ambient is lit from above and `ambient_ground` from below, blending with the surface's up-ness, rather than the same everywhere
	ambient_ground:[4]f32,
	fog:Fog_Settings,
	exposure:f32, // multiplies the lit colour before the tonemap; 0 is read as 1, since an exposure of 0 would be a black screen and not a choice
	tonemap:Tonemap,
	shadow:Shadow_Settings,
	mode:Lighting_Mode, // for every part whose material doesn't choose (Material.lighting)
}

// What set_lights and set_lighting keep, held in mbi.lighting.
Lighting_State :: struct {
	settings:Lighting_Settings,
	lights:[LIGHT_SLOT_COUNT]Light,
	light_count:int,
	casting:bool, // set_shadow_casting: whether what is queued now throws a shadow
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
	position:[LIGHT_SLOT_COUNT][4]f32, // eye space, w = the kind: 0 directional, 1 point, 2 spot, and on PC 3 a rectangle and 4 a disk (an area light's centre)
	cone:[LIGHT_SLOT_COUNT][4]f32, // SPOT: cos(outer angle), cos(inner angle), then k = 1 / (the difference) and -outer * k, so a shader works the cone out as cos * k + (-outer * k), two instructions on the 3DS where subtracting and scaling is three; zero otherwise
	/*
		Where PC's shader loop stops, so a scene with one sun doesn't pay for 64 slots. The Vita's per-pixel shader
		uses the three counts below instead; the 3DS's per-vertex loop runs all 8 and reads neither. The padding fills the row, as HLSL rounds
		a constant buffer up to whole rows of 16 bytes.
	*/
	count:i32,
	sun_count:i32, // the Vita's only, set by sort_lights_block_by_kind: how many of the first `count` slots are suns
	point_count:i32, // the Vita's only: how many of the next are bulbs; the rest are spots
	_padding:i32,
	// PC's four scene rows (mbsc's LIGHT_SCENE_NAMES): the ground's ambient, the world's up in eye space (w: hemisphere on), the fog colour (w: fog on), and
	// the fog's start and 1 / length, the exposure and the tonemap. Nothing on the handhelds, whose blocks do not have them
	ground:Scene_Row,
	up:Scene_Row,
	fog_color:Scene_Row,
	fog_range:Scene_Row,
	// The shadow: the four rows of the matrix from eye space to the caster's clip space, then the caster's slot (-1 for none), a texel's width in the map, the depth bias and the normal offset
	shadow_x:Scene_Row,
	shadow_y:Scene_Row,
	shadow_z:Scene_Row,
	shadow_w:Scene_Row,
	shadow_parameters:Scene_Row,
}

when ODIN_OS == .Windows {
	@(private)
	Scene_Row :: [4]f32
} else {
	@(private)
	Scene_Row :: struct {}
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
	create_area_rect_light makes a flat rectangle of light, `width` along `right` and `height` across it, centred on `position` and facing
	`direction` (the way its light goes). It shines only from its front. PC only: the handhelds draw it as a point light at `position`.
	The light is the nearest point of the rectangle to each pixel shining as a point light does, so it fades with distance like one
*/
create_area_rect_light :: proc(position, direction, right:[3]f32, width, height:f32, color:[4]f32 = WHITE) -> Light {
	return Light{kind = .AREA_RECT, position = position, direction = direction, right = right, area_size = {width * 0.5, height * 0.5}, diffuse = color, specular = color}
}

// create_area_disk_light makes a flat disk of light of `radius` centred on `position` and facing `direction`, like create_area_rect_light.
create_area_disk_light :: proc(position, direction:[3]f32, radius:f32, color:[4]f32 = WHITE) -> Light {
	// A disk is round, so which way is "right" is only the direction its two axes are measured from: any one at right angles will do
	helper := [3]f32{1, 0, 0} if abs(direction.x) < 0.9 * math.sqrt(max(direction.x * direction.x + direction.y * direction.y + direction.z * direction.z, 1e-12)) else [3]f32{0, 1, 0}
	right := [3]f32{direction.y * helper.z - direction.z * helper.y, direction.z * helper.x - direction.x * helper.z, direction.x * helper.y - direction.y * helper.x}
	return Light{kind = .AREA_DISK, position = position, direction = direction, right = right, area_size = {radius, 0}, diffuse = color, specular = color}
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

/*
	set_shadow_casting chooses whether what is queued from now on throws a shadow, until it is called again (PC only; the handhelds draw no shadows). It
	is separate from the light that casts: this says which things are in the way, `Light.casts_shadow` which light they are in the way of. A model
	that is skinned or see-through casts none, whatever this says
*/
set_shadow_casting :: proc(enabled:bool) {
	mbi.lighting.casting = enabled
}

// get_shadow_settings is what set_lighting's Shadow_Settings come to with the defaults filled in where it was left zero.
get_shadow_settings :: proc(settings:Shadow_Settings) -> Shadow_Settings {
	filled := settings
	if filled.resolution <= 0 do filled.resolution = 2048
	if filled.radius <= 0 do filled.radius = 20
	if filled.depth_bias <= 0 do filled.depth_bias = 0.002
	if filled.normal_offset <= 0 do filled.normal_offset = 0.02
	return filled
}

// calculate_shadow_caster finds the light that casts the shadow: the first that asks and is a sun or a spot. -1 when there is none.
calculate_shadow_caster :: proc(lighting:Lighting_State) -> int {
	for slot in 0 ..< lighting.light_count {
		light := lighting.lights[slot]
		if light.casts_shadow && (light.kind == .DIRECTIONAL || light.kind == .SPOT) do return slot
	}
	return -1
}

/*
	calculate_shadow_matrix is the caster's view of the world as a matrix: world space to D3D clip space (depth 0..1). A sun is looked at through a box
	around `center`, set back `radius` along its direction so the box holds everything that can fall on it; a spot through a cone as wide as its
	outer angle. The same matrix draws the map and, at the end of the chain, looks it up
*/
when ODIN_OS == .Windows {
	calculate_shadow_matrix :: proc(light:Light, settings:Shadow_Settings) -> matrix[4,4]f32 {
		shadow := get_shadow_settings(settings)
		direction := calculate_unit_direction(light.direction).xyz
		if direction == {} do direction = {0, -1, 0}
		// look_at breaks when the way up is the way it looks
		up := [3]f32{0, 1, 0} if abs(direction.y) < 0.99 else [3]f32{0, 0, 1}
		if light.kind == .SPOT {
			view := linalg.matrix4_look_at_f32(light.position, light.position + direction, up)
			field_of_view := min(2 * light.outer_angle, 170) // the whole cone, from the light's centre line out to the edge on both sides
			projection := linalg.matrix4_perspective_f32(math.to_radians(max(field_of_view, 1)), 1, 0.1, shadow.radius)
			return GL_TO_D3D_DEPTH * projection * view
		}
		center := shadow.center
		view := linalg.matrix4_look_at_f32(center - direction * shadow.radius, center, up)
		projection := linalg.matrix_ortho3d_f32(-shadow.radius, shadow.radius, -shadow.radius, shadow.radius, 0, 2 * shadow.radius)
		return GL_TO_D3D_DEPTH * projection * view
	}
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

/*
	sort_lights_block_by_kind puts the block's lights in the order suns, bulbs, spots, keeping the game's order inside
	each kind, and says how many of each in `sun_count` and `point_count`. The Vita's per-pixel shader runs one loop per
	kind, so a sun costs a direction and no more and a bulb has no cone to work out; with the lights in the game's order
	every turn of one loop would pay for all three. The Vita only: PC's shader tests the kind, and the 3DS's unit takes
	any order. The sum of the lights does not depend on their order.
*/
@(private)
sort_lights_block_by_kind :: proc(block:^Lights_Block) {
	sorted:Lights_Block = block^
	next := 0
	for kind in 0 ..< 3 {
		for slot in 0 ..< int(block.count) {
			if int(block.position[slot].w) != kind do continue
			sorted.direction[next] = block.direction[slot]
			sorted.diffuse[next] = block.diffuse[slot]
			sorted.specular[next] = block.specular[slot]
			sorted.position[next] = block.position[slot]
			sorted.cone[next] = block.cone[slot]
			next += 1
		}
		if kind == 0 do sorted.sun_count = i32(next)
		if kind == 1 do sorted.point_count = i32(next) - sorted.sun_count
	}
	block^ = sorted
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
		// The handhelds' lighting has no area lights: the point light at the centre is the nearest it can do
		effective := light.kind
		when ODIN_OS != .Windows {
			if effective == .AREA_RECT || effective == .AREA_DISK do effective = .POINT
		}
		kind := f32(int(effective))
		block.position[slot].w = kind
		switch effective {
		case .DIRECTIONAL:
			// reversed, to point towards the light
			towards := view * [4]f32{-light.direction.x, -light.direction.y, -light.direction.z, 0}
			block.direction[slot] = calculate_unit_direction(towards.xyz)
		case .AREA_RECT, .AREA_DISK:
			// The way it faces, not reversed like a sun's: the shader tests which side of the shape a pixel is on. Its half height rides in
			// the direction's w and its right vector and half width in `cone` (mbsc's mbs_light_sample)
			place := view * [4]f32{light.position.x, light.position.y, light.position.z, 1}
			block.position[slot] = {place.x, place.y, place.z, kind}
			facing := calculate_unit_direction((view * [4]f32{light.direction.x, light.direction.y, light.direction.z, 0}).xyz)
			right := calculate_unit_direction((view * [4]f32{light.right.x, light.right.y, light.right.z, 0}).xyz)
			block.direction[slot] = {facing.x, facing.y, facing.z, light.area_size.y}
			block.cone[slot] = {right.x, right.y, right.z, light.area_size.x}
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
	when ODIN_OS == .Windows {
		settings := lighting.settings
		block.ground = settings.ambient_ground
		up := view * [4]f32{0, 1, 0, 0}
		block.up = {up.x, up.y, up.z, 1 if settings.hemisphere else 0}
		block.fog_color = {settings.fog.color.r, settings.fog.color.g, settings.fog.color.b, 1 if settings.fog.enabled else 0}
		block.fog_range = {
			settings.fog.start,
			1 / max(settings.fog.end - settings.fog.start, 1e-6),
			settings.exposure if settings.exposure > 0 else 1,
			f32(int(settings.tonemap)),
		}
		block.shadow_parameters = {-1, 0, 0, 0}
		if caster := calculate_shadow_caster(lighting); caster >= 0 {
			shadow := get_shadow_settings(settings.shadow)
			// The block's points are in eye space, so the matrix starts from there: back to the world with the view's inverse, then the caster's
			eye_to_light := calculate_shadow_matrix(lighting.lights[caster], settings.shadow) * linalg.inverse(view)
			block.shadow_x = {eye_to_light[0, 0], eye_to_light[0, 1], eye_to_light[0, 2], eye_to_light[0, 3]}
			block.shadow_y = {eye_to_light[1, 0], eye_to_light[1, 1], eye_to_light[1, 2], eye_to_light[1, 3]}
			block.shadow_z = {eye_to_light[2, 0], eye_to_light[2, 1], eye_to_light[2, 2], eye_to_light[2, 3]}
			block.shadow_w = {eye_to_light[3, 0], eye_to_light[3, 1], eye_to_light[3, 2], eye_to_light[3, 3]}
			block.shadow_parameters = {f32(caster), 1 / f32(shadow.resolution), shadow.depth_bias, shadow.normal_offset}
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
