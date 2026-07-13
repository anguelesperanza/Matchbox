package matchbox

/*
	Shapes.odin
	-----------
	This contains shapes & primitives needed for general rendering */

import "gpu"

/*Structs*/
Vertex :: struct {
	position: [3]f32,
	color:    [3]f32,
}

VertData :: struct {
	verts: rawptr,
	shape: int, // 0 -> triangle, 1 -> rectangle, 2 -> circle | Used to determine what shader to use
	position: [3]f32,
}

FragData :: struct #align(16) {
	color: [4]f32,
}

/*
	These shapres are the same;
	may fold into a single Shape struct if other shapes follow pattern as well
 */

Shape :: struct {
	shape:int,
	pos:[3]f32,
	arena:gpu.Arena,
	verts:gpu.slice_t(Vertex),
	verts_local:gpu.slice_t(Vertex),
	indices:gpu.slice_t(u32),
	indices_local:gpu.slice_t(u32),
}

/*3D Shapes*/
create_default_triangle :: proc() -> (triangle:Shape) {

	triangle.arena = gpu.arena_create()

	triangle.shape = 0

	triangle.verts = gpu.arena_alloc(&triangle.arena, Vertex, 3)
	triangle.verts.cpu[0].position = {-0.5, 0.5, 0.0}
	triangle.verts.cpu[1].position = {0.0, -0.5, 0.0}
	triangle.verts.cpu[2].position = {0.5, 0.5, 0.0}
	triangle.verts.cpu[0].color = {1.0, 0.0, 0.0}
	triangle.verts.cpu[1].color = {0.0, 1.0, 0.0}
	triangle.verts.cpu[2].color = {0.0, 0.0, 1.0}

	triangle.indices = gpu.arena_alloc(&triangle.arena, u32, 3)
	triangle.indices.cpu[0] = 0
	triangle.indices.cpu[1] = 2
	triangle.indices.cpu[2] = 1

	triangle.verts_local = gpu.mem_alloc(Vertex, 3, gpu.Memory.GPU)
	triangle.indices_local = gpu.mem_alloc(u32, 3, gpu.Memory.GPU)

	upload_cmd_buf := gpu.commands_begin(.Main)
	gpu.cmd_mem_copy(upload_cmd_buf, triangle.verts_local, triangle.verts)
	gpu.cmd_mem_copy(upload_cmd_buf, triangle.indices_local, triangle.indices)
	gpu.cmd_barrier(upload_cmd_buf, .Transfer, .All, {})
	gpu.queue_submit(.Main, {upload_cmd_buf})

	return
}


create_default_rectangle :: proc() -> (rectangle:Shape) {
	rectangle.arena = gpu.arena_create()

	rectangle.shape = 1

	rectangle.verts = gpu.arena_alloc(&rectangle.arena, Vertex, 4)
	rectangle.verts.cpu[0].position = {-0.5,  0.5, 0.0}
	rectangle.verts.cpu[1].position = { 0.5, -0.5, 0.0}
	rectangle.verts.cpu[2].position = { 0.5,  0.5, 0.0}
	rectangle.verts.cpu[3].position = {-0.5, -0.5, 0.0}
	rectangle.verts.cpu[0].color = {1.0, 0.0, 0.0}
	rectangle.verts.cpu[1].color = {0.0, 1.0, 0.0}
	rectangle.verts.cpu[2].color = {0.0, 0.0, 1.0}
	rectangle.verts.cpu[3].color = {0.0, 0.0, 1.0}

	rectangle.indices = gpu.arena_alloc(&rectangle.arena, u32, 6)
	rectangle.indices.cpu[0] = 0
	rectangle.indices.cpu[1] = 2
	rectangle.indices.cpu[2] = 1
	rectangle.indices.cpu[3] = 0
	rectangle.indices.cpu[4] = 1
	rectangle.indices.cpu[5] = 3

	rectangle.verts_local = gpu.mem_alloc(Vertex, 4, gpu.Memory.GPU)
	rectangle.indices_local = gpu.mem_alloc(u32, 6, gpu.Memory.GPU)

	upload_cmd_buf := gpu.commands_begin(.Main)
	gpu.cmd_mem_copy(upload_cmd_buf, rectangle.verts_local, rectangle.verts)
	gpu.cmd_mem_copy(upload_cmd_buf, rectangle.indices_local,rectangle.indices)
	gpu.cmd_barrier(upload_cmd_buf, .Transfer, .All, {})
	gpu.queue_submit(.Main, {upload_cmd_buf})

	return
}

destroy_rectangle :: proc (rectangle:^Shape) {
	gpu.mem_free(rectangle.verts_local)
	gpu.mem_free(rectangle.indices_local)
	gpu.arena_destroy(&rectangle.arena)
}

create_default_circle :: proc() -> (circle:Shape) {

	circle.arena = gpu.arena_create()

	circle.shape = 2

	circle.verts = gpu.arena_alloc(&circle.arena, Vertex,4)

	circle.verts.cpu[0].position = {-0.5,  0.5, 0.0} // left
	circle.verts.cpu[1].position = { 0.5, -0.5, 0.0} // top
	circle.verts.cpu[2].position = { 0.5,  0.5, 0.0}  // right
	circle.verts.cpu[3].position = {-0.5, -0.5, 0.0}
	circle.verts.cpu[0].color = {1.0, 0.0, 0.0}
	circle.verts.cpu[1].color = {0.0, 1.0, 0.0}
	circle.verts.cpu[2].color = {0.0, 0.0, 1.0}
	circle.verts.cpu[3].color = {0.0, 0.0, 1.0}

	circle.indices = gpu.arena_alloc(&circle.arena, u32, 6)
	circle.indices.cpu[0] = 0
	circle.indices.cpu[1] = 2
	circle.indices.cpu[2] = 1
	circle.indices.cpu[3] = 0
	circle.indices.cpu[4] = 1
	circle.indices.cpu[5] = 3

	circle.verts_local = gpu.mem_alloc(Vertex, 4, gpu.Memory.GPU)
	circle.indices_local = gpu.mem_alloc(u32, 6, gpu.Memory.GPU)


	upload_cmd_buf := gpu.commands_begin(.Main)
	gpu.cmd_mem_copy(upload_cmd_buf, circle.verts_local, circle.verts)
	gpu.cmd_mem_copy(upload_cmd_buf, circle.indices_local,circle.indices)
	gpu.cmd_barrier(upload_cmd_buf, .Transfer, .All, {})
	gpu.queue_submit(.Main, {upload_cmd_buf})

	return
}

destroy_shape :: proc(shape:^Shape) {
	gpu.mem_free(shape.verts_local)
	gpu.mem_free(shape.indices_local)
	gpu.arena_destroy(&shape.arena)
}
