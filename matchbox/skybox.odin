package matchbox

import "core:math"

/*
	Skybox
	======
	The sky: drawn as whatever direction each pixel looks in, so it is infinitely far and moving the camera never moves
	it. Shared by every target for the types and the maths; PC alone draws it (skybox_windows.odin), and the handhelds
	declare the same names that stop with a message (skybox_handheld_freestanding_arm32.odin), so a game that uses a sky
	builds everywhere and says so at run time where it can't have one yet.

	Two sources, because sky packs ship as both and neither converts to the other without loss:
	- a **cube map**, six square faces packed as a horizontal cross. The hardware picks the face
	- a **panorama**, one 2:1 equirectangular picture: longitude across, latitude down

	Both are a `Skybox`, drawn by the same `render_skybox` between `camera_start` and `camera_end`. It is drawn before
	anything else in that camera and neither tests nor writes depth, so everything after it covers it.

	**Handedness.** Matchbox is right-handed, +Y up, the camera looks down -Z. A cube map is left-handed, so the cell
	labelled +X is the one seen looking toward world -X, and the cell labelled -Z is the one straight ahead of a camera
	that has not turned. Every sky pack's cross is labelled for a left-handed viewer, so this is what keeps it
	continuous when the camera turns.
*/

Skybox_Kind :: enum {
	CUBEMAP,
	PANORAMA,
}

/*
	A sky on the GPU. `tint` multiplies the picture, to darken a sky for dusk or push it toward a colour with no second
	image. The loaders set it to white; a Skybox that did not come from one has no texture and is refused by render_skybox
*/
Skybox :: struct {
	using backend:Backend_Skybox, // the GPU objects, which differ per target
	kind:Skybox_Kind,
	tint:[4]f32,
}

/*
	The camera's directions, the shape the sky shader wants: the ray through the pixel at normalised device coordinate
	(x, y) is `forward + right * x + up * y`. `right` and `up` are already scaled by the field of view and the aspect
*/
Skybox_Rays :: struct {
	right:[4]f32,
	up:[4]f32,
	forward:[4]f32,
}

/*The rays for a view matrix (calculate_camera_view_matrix), a vertical field of view in degrees and an aspect ratio.
Read from the matrix rather than the Camera, so it is exactly what the frame was drawn with, pixel snapping included*/
calculate_skybox_rays :: proc(view:matrix[4, 4]f32, fov_y:f32, aspect:f32) -> Skybox_Rays {
	// The rows of a view matrix's rotation are the camera's right, its up and its backward
	right := [3]f32{view[0, 0], view[0, 1], view[0, 2]}
	up := [3]f32{view[1, 0], view[1, 1], view[1, 2]}
	forward := [3]f32{-view[2, 0], -view[2, 1], -view[2, 2]}

	// Half the height of the view plane at unit distance: what turns a device coordinate back into a direction
	half := math.tan(math.to_radians(fov_y) * 0.5)
	return Skybox_Rays {
		right = {right.x * half * aspect, right.y * half * aspect, right.z * half * aspect, 0},
		up = {up.x * half, up.y * half, up.z * half, 0},
		forward = {forward.x, forward.y, forward.z, 0},
	}
}

/*
	Cuts a horizontal cross into its six faces, in the order a cube map numbers them: +X, -X, +Y, -Y, +Z, -Z.

		      +Y
	  -X  +Z  +X  -Z
		      -Y

	Four cells across, three down, each square, so the picture is 4:3. A vertical cross or any other shape is refused
	rather than cut into six wrong rectangles that upload without complaint. The faces are copies in one allocation,
	`faces[0]` being its start: delete `faces[0]` to free them all
*/
split_cubemap_cross :: proc(pixels:[][4]u8, width, height:int, allocator := context.allocator) -> (faces:[6][][4]u8, face_size:int, ok:bool) {
	if width <= 0 || width % 4 != 0 || height % 3 != 0 || width / 4 != height / 3 do return {}, 0, false
	if len(pixels) < width * height do return {}, 0, false

	face_size = width / 4
	// Column and row of each face in the cross
	cells := [6][2]int{{2, 1}, {0, 1}, {1, 0}, {1, 2}, {1, 1}, {3, 1}}

	storage := make([][4]u8, 6 * face_size * face_size, allocator)
	for cell, face in cells {
		faces[face] = storage[face * face_size * face_size:][:face_size * face_size]
		for row in 0 ..< face_size {
			source := (cell[1] * face_size + row) * width + cell[0] * face_size
			copy(faces[face][row * face_size:][:face_size], pixels[source:][:face_size])
		}
	}
	return faces, face_size, true
}
