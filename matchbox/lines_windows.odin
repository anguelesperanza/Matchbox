#+build windows

package matchbox

/*
	Lines in the 3D world
	=====================
	One pixel wide, tested against the depth buffer, so a grid or a wire box is hidden behind what is in front of it.
	render_line is not that: it is a flat quad in the XY plane, so a line along Z or seen edge-on vanishes.

	Each line is one draw of a shared two-vertex mesh, stretched between its ends by the model matrix: no vertices are built
	per frame. A 40 by 40 grid is 82 draws. A line has no thickness to give: a thick one would have to be a quad turned to
	face the camera, whose width in pixels changes along its length, and nothing needs one yet
*/

import "core:math/linalg"

/*A one pixel line from `start` to `end` in the world, hidden behind anything nearer. Inside camera_start / camera_end of a 3D camera*/
render_line_3d :: proc(start, end:[3]f32, color:[4]f32) {
	// The mesh runs 0..1 along X, so X is the whole line and the other axes only have to be something
	model := calculate_basis_matrix(end - start, {0, 1, 0}, {0, 0, 1}, start)
	queue_render(mbi.line_mesh, model, color, shape_blend(color), .NONE, {}, {0, 0, 1, 1}, 0)
}

/*
	A grid on the ground plane (Y = `height`), `slices` squares across and `spacing` wide each, centred on the origin. The two
	lines through the origin are drawn brighter (twice the alpha), so which way is X and which is Z can be read off it.
	`slices` is rounded up to even so there is a line through the origin
*/
render_grid :: proc(slices:int, spacing:f32, color:[4]f32, height:f32 = 0) {
	count := slices + slices % 2
	if count <= 0 || spacing <= 0 do return

	half := f32(count) * spacing * 0.5
	axis := [4]f32{color.r, color.g, color.b, min(color.a * 2, 1)}

	for index in 0 ..= count {
		at := -half + f32(index) * spacing
		line_color := axis if index == count / 2 else color
		render_line_3d({at, height, -half}, {at, height, half}, line_color)
		render_line_3d({-half, height, at}, {half, height, at}, line_color)
	}
}

/*
	The twelve edges of a box from `lower` to `upper` in its own space, placed in the world by `model`. With no `model` it is
	an upright box between two corners (what a level's shape bounds are); with one it is a turned, scaled box, such as a model
	that would not load drawn as a unit cube
*/
render_bounds_wires :: proc(lower, upper:[3]f32, color:[4]f32, model:matrix[4, 4]f32 = linalg.MATRIX4F32_IDENTITY) {
	corners: [8][3]f32
	for &corner, index in corners {
		local := [4]f32{
			lower.x if index & 1 == 0 else upper.x,
			lower.y if index & 2 == 0 else upper.y,
			lower.z if index & 4 == 0 else upper.z,
			1,
		}
		corner = (model * local).xyz
	}

	// Corner numbers are the bits (x, y, z), so an edge joins two that differ in exactly one bit
	edges := [12][2]int{{0, 1}, {2, 3}, {4, 5}, {6, 7}, {0, 2}, {1, 3}, {4, 6}, {5, 7}, {0, 4}, {1, 5}, {2, 6}, {3, 7}}
	for edge in edges do render_line_3d(corners[edge[0]], corners[edge[1]], color)
}
