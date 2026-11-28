#+build freestanding arm32

package matchbox

/*3D lines are PC only (a level editor's grid and wire boxes). The handhelds draw nothing, so code that calls them builds*/

/*Does nothing on the handhelds*/
render_line_3d :: proc(start, end:[3]f32, color:[4]f32) {
}

/*Does nothing on the handhelds*/
render_grid :: proc(slices:int, spacing:f32, color:[4]f32, height:f32 = 0) {
}

/*Does nothing on the handhelds*/
render_bounds_wires :: proc(lower, upper:[3]f32, color:[4]f32, model:matrix[4, 4]f32 = {1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1}) {
}
