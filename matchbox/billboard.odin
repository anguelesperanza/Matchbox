package matchbox

/*
	Billboard
	=========
	A sprite that turns to face the camera in a perspective scene. It is the same quad as render_sprite's, drawn through
	the same queue, unlit; only the rotation is worked out from the camera instead of being the sprite's own. Shared by
	every target: the maths needs `mbi.view` and nothing else, and uses no trig except for a roll
*/

import "core:math"
import "core:math/linalg"

Billboard_Mode :: enum {
	UPRIGHT, // turns about +Y only, toward the eye: trees, characters, lamp posts. Never leans
	CAMERA_POSITION, // turns fully toward the eye, so it is square-on from any angle: flares, markers
	CAMERA_PLANE, // lies flat to the screen, the camera's own right and up however far off-centre it is: particles
}

Billboard_Settings :: struct {
	mode:Billboard_Mode,
	screen_size:bool, // the same size on screen at any distance: one image pixel is one window pixel, times the sprite's scale
}

// Where a billboard's quad points: its right edge, its up edge and the side it shows
@(private)
Billboard_Basis :: struct {
	right:[3]f32,
	up:[3]f32,
	normal:[3]f32,
}

/*
	The three axes a billboard at `position` has, seen through `view`. `fov_y` is the camera's, in degrees, and 0 for an
	orthographic one: there is no eye to turn toward there, only a direction, so every mode that would turn toward the eye
	turns to face the same way instead

	In a view matrix [R | t] the camera's axes are the rows of R, and the eye is -Rᵀt. That is how this reads the camera
	from `mbi.view` without being handed a Camera
*/
@(private)
calculate_billboard_basis :: proc(view:matrix[4, 4]f32, fov_y:f32, position:[3]f32, mode:Billboard_Mode) -> Billboard_Basis {
	// A squared length under this is a direction with nothing worth turning toward
	EPSILON :: 1e-6

	camera_right := [3]f32{view[0, 0], view[0, 1], view[0, 2]}
	camera_up := [3]f32{view[1, 0], view[1, 1], view[1, 2]}
	camera_back := [3]f32{view[2, 0], view[2, 1], view[2, 2]} // the camera looks down -Z, so +Z is behind it

	if mode == .CAMERA_PLANE || (fov_y <= 0 && mode == .CAMERA_POSITION) {
		return {camera_right, camera_up, camera_back}
	}

	world_up := [3]f32{0, 1, 0}
	toward_eye := camera_back
	if fov_y > 0 {
		translation := [3]f32{view[0, 3], view[1, 3], view[2, 3]}
		eye := -(camera_right * translation.x + camera_up * translation.y + camera_back * translation.z)
		toward_eye = eye - position
	}

	if mode == .UPRIGHT {
		// Only the heading counts: tilting toward a camera above or below would make it lean
		toward_eye.y = 0

		// Straight above or below it there is no heading to turn toward. Face the way the camera is turned
		// rather than produce a NaN: back along its own horizontal heading, and +Z if it looks straight down
		if linalg.length2(toward_eye) < EPSILON {
			toward_eye = {camera_back.x, 0, camera_back.z}
			if linalg.length2(toward_eye) < EPSILON do toward_eye = {0, 0, 1}
		}

		normal := linalg.normalize(toward_eye)
		return {linalg.normalize(linalg.cross(world_up, normal)), world_up, normal}
	}

	// CAMERA_POSITION. On top of the sprite, the cross with +Y vanishes: take the camera's own right instead,
	// made perpendicular to the normal
	if linalg.length2(toward_eye) < EPSILON do toward_eye = camera_back
	normal := linalg.normalize(toward_eye)
	right := linalg.cross(world_up, normal)
	if linalg.length2(right) < EPSILON {
		right = camera_right - normal * linalg.dot(camera_right, normal)
	}
	right = linalg.normalize(right)
	return {right, linalg.cross(normal, right), normal}
}

/*
	The model matrix of a quad centred on its origin and 1 x 1, made `size` big and turned to face the camera. `pivot`
	is the point of the quad that sits at `position` (as Sprite.pivot), and `roll` turns the quad about its normal, about
	that pivot. UPRIGHT ignores the roll, because a roll is exactly leaning
*/
@(private)
calculate_billboard_model :: proc(view:matrix[4, 4]f32, fov_y:f32, position:[3]f32, size:[2]f32, pivot:[2]f32, roll:f32, mode:Billboard_Mode) -> matrix[4, 4]f32 {
	basis := calculate_billboard_basis(view, fov_y, position, mode)

	if roll != 0 && mode != .UPRIGHT {
		sine, cosine := math.sin(roll), math.cos(roll)
		basis.right, basis.up = basis.right * cosine + basis.up * sine, basis.up * cosine - basis.right * sine
	}

	orientation := matrix[4, 4]f32{
		basis.right.x, basis.up.x, basis.normal.x, position.x,
		basis.right.y, basis.up.y, basis.normal.y, position.y,
		basis.right.z, basis.up.z, basis.normal.z, position.z,
		0, 0, 0, 1,
	}
	return orientation * linalg.matrix4_scale_f32({size.x, size.y, 1}) * linalg.matrix4_translate_f32({0.5 - pivot.x, 0.5 - pivot.y, 0})
}

/*
	How many world units one window pixel covers at `position`, for a perspective camera `fov_y` degrees tall that draws
	into a target `window_height` pixels tall. Measured along the view axis, not along the ray to the point: the plane
	one pixel is the same size across, so it does not swell toward the screen's edge. 0 for an orthographic camera, where
	distance changes nothing
*/
@(private)
calculate_billboard_units_per_pixel :: proc(view:matrix[4, 4]f32, fov_y:f32, window_height:f32, position:[3]f32) -> f32 {
	if fov_y <= 0 || window_height <= 0 do return 0
	depth := max(-(view * [4]f32{position.x, position.y, position.z, 1}).z, 0)
	return 2 * depth * math.tan(linalg.to_radians(fov_y) * 0.5) / window_height
}

/*
	The model matrix render_billboard draws with, for a game that wants to place a mesh of its own facing the camera.
	It is built for the 1 x 1 quad Matchbox draws sprites with (centred on its origin): `size` is how big to make it

	With `settings.screen_size`, `size` is in window pixels rather than world units. UPRIGHT leans the same way
	render_billboard's does, so it ignores `roll`
*/
calculate_billboard_matrix :: proc(camera:Camera, position:[3]f32, size := [2]f32{1, 1}, settings := Billboard_Settings{}, roll:f32 = 0) -> matrix[4, 4]f32 {
	view := calculate_camera_view_matrix(camera)
	fov_y := camera.fov_y if camera.projection == .PERSPECTIVE else 0

	world_size := size
	if settings.screen_size {
		world_size = size * calculate_billboard_units_per_pixel(view, fov_y, f32(get_draw_size().y), position)
	}
	return calculate_billboard_model(view, fov_y, position, world_size, {0.5, 0.5}, roll, settings.mode)
}

/*
	Queues a sprite, turned to face the camera, to be drawn at camera_end. Same as render_sprite otherwise: the
	position is where the pivot goes ({0.5, 0} stands a tree on the floor), and the size is the image's pixels over
	`pixels_per_unit`, times `scale`. With `settings.screen_size` the size is the image's pixels on screen instead, and
	does not change with distance (perspective cameras only)

	`sprite.rotation` is a roll about the way the billboard faces, except for UPRIGHT, which ignores it. Not for a
	screen pass: there is no eye there to face, and render_sprite is the one to use
*/
render_billboard :: proc(sprite:Sprite, settings := Billboard_Settings{}, mode:Sprite_Mode = .CUTOUT) {
	ensure(sprite.texture.width > 0, "Sprite has no texture")
	ensure(sprite.pixels_per_unit > 0, "Sprite pixels_per_unit must be above zero")
	ensure(mbi.camera_active == true, "Drawing must happen between camera_start and camera_end")
	ensure(mbi.screen_pass == false, "A billboard cannot be drawn in a screen pass; use render_sprite")

	source := calculate_sprite_source(sprite)
	pixels := [2]f32{source[2], source[3]}

	size := pixels / sprite.pixels_per_unit * sprite.scale
	if settings.screen_size {
		// Orthographic: no distance to scale by, so it keeps its world size
		units_per_pixel := calculate_billboard_units_per_pixel(mbi.view, mbi.camera_fov_y, mbi.camera_window_height, sprite.position)
		if units_per_pixel > 0 do size = pixels * sprite.scale * units_per_pixel
	}

	model := calculate_billboard_model(mbi.view, mbi.camera_fov_y, sprite.position, size, sprite.pivot, sprite.rotation, settings.mode)
	blend, alpha_cutoff := calculate_sprite_blend(mode)
	queue_render(mbi.sprite_mesh, model, sprite.tint, blend, .NONE, sprite.texture, calculate_sprite_uv_rectangle(sprite, source), alpha_cutoff)
}

/*
	Draws an animated sprite as a billboard. The frame and `flip_x` are read at draw time as render_animated_sprite
	does. The clip's `offset` moves the drawing along the billboard's own right and up, not world x and y: those would
	slide the art sideways the moment the billboard turns
*/
render_animated_billboard :: proc(sprite:Animated_Sprite, settings := Billboard_Settings{}, mode:Sprite_Mode = .CUTOUT) {
	shifted := sprite.sprite
	shift := calculate_animation_render_offset(sprite)

	if shift != {} {
		basis := calculate_billboard_basis(mbi.view, mbi.camera_fov_y, sprite.position, settings.mode)
		shifted.position += basis.right * shift.x + basis.up * shift.y
	}
	render_billboard(shifted, settings, mode)
}
