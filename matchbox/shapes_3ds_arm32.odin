package matchbox

/*
	Shapes
	======
	Basic shapes
*/

// Constants
MAX_BATCH_VERTICES :: 4096 // Total number of vertices that can be drawn at once


// Structs
Vertex :: struct {
	x, y, z:f32,
	r,g,b,a:f32,
}

// Batch :: struct {
// 	verticies: [dynamic]Vertex,
// 	gpu_buffer: ^d3d11.IBuffer, // Dynamic but fixed capacity; replaced mbi.vertex_buffer
// 	gpu_cursor: u32, // needed for NO_OVERWRITE
	
// }
// batch:Batch

Triangle :: struct {
	vertex_count:u32,
	vertex_stride:u32,
	vertex_offset:u32
}


/*Create a triangle to render to the screen*/
create_triangle :: proc() -> (triangle:Triangle) {
	
	
	return 
}
