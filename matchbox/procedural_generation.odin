package matchbox

/*
	Procedural Generation
	=====================
	This file contains different (or possibly just one) implementation(s) of procedural generation algorithms

	Rendering data must be done on a game by game basis

	Current algorithms in this file
	-------------------------------
	Random Walk (also called Drunken Walk) 
*/


import "core:math/rand"

/*
	A drunkard's-walk map: `steps` moves from `start`, carving out the cells it
	passes through.

	Returns a `size.x * size.y` grid, row-major, with 1 where the walk went and
	0 everywhere else. Allocated, so the caller frees it.

	The simplest cave generator there is, and it makes no promise that the
	result is connected end to end or that it fills any particular share of the
	grid -- a short walk on a large grid is mostly zeroes.
*/
random_walk :: proc(size:[2]int, start: [2]f32, steps: int, stride: f32) -> []u8 {
	current_pos := start

	level, err := make([]u8, size.x* size.y)

	if err != nil {
		return level
	}

	for _ in 0 ..< steps {
		direction := rand.int_range(0, 4)
		next := current_pos

		switch direction {
		case 0: next.y -= stride // Up
		case 1: next.y += stride // Down
		case 2: next.x -= stride // Left
		case 3: next.x += stride // Right
		}

		// Clamp to valid bounds
		next.x = clamp(next.x, 0, f32(size.x) - stride)
		next.y = clamp(next.y, 0, f32(size.y) - stride)

		current_pos = next

		// Convert pixel position to cell index
		cell_x := int(current_pos.x / stride)
		cell_y := int(current_pos.y / stride)
		level_loc := cell_y * (size.x / int(stride)) + cell_x		
		level[level_loc] = 1
	}


	return level
}
