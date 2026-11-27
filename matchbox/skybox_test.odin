#+build windows

package matchbox

import "core:math"
import "core:testing"

@(test)
rays_follow_the_view_matrix_and_the_field_of_view :: proc(t:^testing.T) {
	// Looking down -Z with +Y up: right is +X, up is +Y, forward is -Z. A 90 degree field has tan(45) = 1, so the
	// rays at the screen's edge are 45 degrees off, scaled by the aspect across
	view := calculate_camera_view_matrix(create_camera_3d({0, 0, 0}, {0, 0, -1}, 90))
	rays := calculate_skybox_rays(view, 90, 2)
	testing.expect(t, math.abs(rays.forward.z + 1) < 1e-5 && math.abs(rays.forward.x) < 1e-5, "forward is -Z")
	testing.expect(t, math.abs(rays.right.x - 2) < 1e-5, "right is +X, scaled by tan(45) * aspect 2")
	testing.expect(t, math.abs(rays.up.y - 1) < 1e-5, "up is +Y, scaled by tan(45)")

	// Turned to look along +X: right is now +Z, because the world is right-handed
	view = calculate_camera_view_matrix(create_camera_3d({3, 4, 5}, {10, 4, 5}, 90))
	rays = calculate_skybox_rays(view, 90, 1)
	testing.expect(t, math.abs(rays.forward.x - 1) < 1e-5, "forward is +X")
	testing.expect(t, math.abs(rays.right.z - 1) < 1e-5, "right is +Z")
}

@(test)
a_cross_is_cut_into_its_labelled_faces :: proc(t:^testing.T) {
	defer free_all(context.temp_allocator)
	// 8 x 6 pixels: faces of 2 x 2. Each cell off the cross is 0, each face holds its number from 1 to 6
	pixels := make([][4]u8, 8 * 6, context.temp_allocator)
	paint :: proc(pixels:[][4]u8, column, row:int, value:u8) {
		for y in 0 ..< 2 {
			for x in 0 ..< 2 do pixels[(row * 2 + y) * 8 + column * 2 + x] = {value, 0, 0, 255}
		}
	}
	paint(pixels, 2, 1, 1) // +X
	paint(pixels, 0, 1, 2) // -X
	paint(pixels, 1, 0, 3) // +Y
	paint(pixels, 1, 2, 4) // -Y
	paint(pixels, 1, 1, 5) // +Z
	paint(pixels, 3, 1, 6) // -Z

	faces, size, ok := split_cubemap_cross(pixels, 8, 6, context.temp_allocator)
	testing.expect(t, ok)
	testing.expect_value(t, size, 2)
	for face, index in faces {
		for pixel in face do testing.expect_value(t, pixel.r, u8(index + 1))
	}

	// A vertical cross is 3 across and 4 down, and a plain square is neither
	_, _, ok = split_cubemap_cross(make([][4]u8, 6 * 8, context.temp_allocator), 6, 8, context.temp_allocator)
	testing.expect(t, ok == false, "a vertical cross is refused")
	_, _, ok = split_cubemap_cross(make([][4]u8, 64, context.temp_allocator), 8, 8, context.temp_allocator)
	testing.expect(t, ok == false, "a square is refused")
}
