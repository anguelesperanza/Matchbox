package matchbox

/*
	Shapes
	======
	Basic shapes
*/


import "vendor:directx/d3d11"

// Constants
MAX_BATCH_VERTICIES :: 65536 // Total number of vertices that can be drawn at once


// Structs
Vertex :: struct {
	position:[2]f32,
	color:[4]f32
}

Batch :: struct {
	verticies: [dynamic]Vertex,
	gpu_buffer: ^d3d11.IBuffer, // Dynamic but fixed capacity; replaced mbi.vertex_buffer
	gpu_cursor: u32, // needed for NO_OVERWRITE
	
}
batch:Batch

Triangle :: struct {
	vertex_count:u32,
	vertex_stride:u32,
	vertex_offset:u32
}


/*Create a triangle to render to the screen*/
create_triangle :: proc() -> (triangle:Triangle) {
	
	
	return 
}
