package matchbox

/*
	Shapes
	======
	Basic shapes
*/


import "vendor:directx/d3d11"

// Structs

Batch :: struct {
	verticies: [dynamic]Vertex,
	gpu_buffer: ^d3d11.IBuffer, // Dynamic but fixed capacity; replaced mbi.vertex_buffer
	gpu_cursor: u32, // needed for NO_OVERWRITE
	
}
batch:Batch

Triangle :: struct {
	position:[2]f32,
	points:[3][2]f32,
	color:[4]f32,
}

/*Create a triangle to render to the screen*/
create_triangle :: proc(position:[2]f32, size:f32 = 50, color:[4]f32 = {1, 1, 1, 1}) -> (triangle:Triangle) {

	h := size / 2

	triangle = {
		position = position,
		points = {{0, -h}, {h, h}, {-h, h}},
		color = color
	}
	
	return triangle
}
