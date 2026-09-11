package matchbox

/*
	Rays -- checked against things this file does not compute
	-----------------------------------------------------------
	`ray_box` is checked against expected answers produced in Python by a
	different algorithm -- intersecting each of the box's six face planes and
	keeping the nearest crossing inside its face -- not by running the slab
	method and writing down what it said. 24 random rays, half aimed near their
	box, and four chosen edges: starting inside, parallel outside a slab,
	parallel inside one, pointing away.

	The screen procedures are checked by a round trip: a point taken to the
	screen and a ray cast back from there has to pass through the point, for a
	perspective and an orthographic camera, over the whole window and over a
	viewport that is not the window's shape.

	The rest are worked out by hand in the comments beside them.
*/

import "core:fmt"
import "core:math"
import "core:math/linalg"
import "core:testing"

@(private)
Ray_Box_Case :: struct {
	origin, direction, lower, upper: [3]f32,
	hit:      bool,
	distance: f32,
}

@(test)
test_ray_box_agrees_with_face_by_face_intersection :: proc(t: ^testing.T) {
	cases := [?]Ray_Box_Case{
		{origin = {-5.304012903, 0.089228798, -5.550052099}, direction = {0.554919252, -0.450818958, 0.699161563}, lower = {-1.704668941, -2.396603304, -0.396262108}, upper = {-1.301847338, -0.696133692, 0.827666860}, hit = false, distance = 0.000000000},
		{origin = {0.925235383, -1.239834304, 5.715061267}, direction = {-0.539724862, 0.469800065, -0.698559212}, lower = {-1.301923243, 0.307408499, -2.504792155}, upper = {-0.476854143, 2.264221521, 0.348792883}, hit = false, distance = 0.000000000},
		{origin = {1.666961627, -1.531229487, 0.572933589}, direction = {-0.808169832, -0.381987488, -0.448271214}, lower = {-2.422979667, -2.528831048, -1.766072704}, upper = {0.062174139, -1.822797184, 0.062407755}, hit = true, distance = 1.985705757},
		{origin = {3.532553778, 2.387933205, -3.070841871}, direction = {-0.318542732, -0.251696362, 0.913881540}, lower = {-0.278400107, -1.289630777, -1.743411318}, upper = {1.561173111, 0.179285477, -0.704063727}, hit = false, distance = 0.000000000},
		{origin = {-4.176185584, -0.132442794, -5.529512915}, direction = {0.527529458, -0.025674346, 0.849148691}, lower = {-0.082218842, -1.848248940, 0.920699390}, upper = {0.448365337, -0.477505039, 3.240693993}, hit = false, distance = 0.000000000},
		{origin = {4.079613366, 5.336173141, -0.310819951}, direction = {-0.189136976, -0.950992500, 0.244623115}, lower = {0.501911247, -1.745009949, -0.218818535}, upper = {2.366146903, 0.078696623, 1.258556393}, hit = false, distance = 0.000000000},
		{origin = {-5.729244863, -0.459656564, -3.983419453}, direction = {0.604070700, 0.096937925, 0.791013040}, lower = {-0.411484582, 0.972383758, 0.287699146}, upper = {0.585382908, 2.252599797, 2.359926751}, hit = false, distance = 0.000000000},
		{origin = {0.593278910, 4.600605917, 3.831358054}, direction = {0.396881276, -0.763320759, -0.509731961}, lower = {-2.482639112, -2.009540665, -1.436201187}, upper = {0.157342416, -1.583913022, 0.021523535}, hit = false, distance = 0.000000000},
		{origin = {-3.199966996, -0.180447236, 1.069482045}, direction = {0.944925950, -0.324365711, -0.043610023}, lower = {-1.564915339, 0.536771309, 0.830924816}, upper = {-0.942336802, 1.230180949, 1.680404043}, hit = false, distance = 0.000000000},
		{origin = {2.114400989, -5.352085281, 4.794396121}, direction = {0.124531187, 0.984686793, -0.121999603}, lower = {-1.522985708, -0.734635105, 0.812391702}, upper = {0.610396532, 0.908740907, 2.741651400}, hit = false, distance = 0.000000000},
		{origin = {-3.494841775, -4.052361747, -1.919356173}, direction = {0.645651835, 0.504459431, -0.573283866}, lower = {-1.430484372, -1.404084671, -2.585851625}, upper = {0.545526411, -1.029790770, -2.197278301}, hit = false, distance = 0.000000000},
		{origin = {-2.972906921, -1.831325447, -1.630038726}, direction = {-0.158835371, 0.615563426, 0.771915146}, lower = {-2.594142528, -1.545560312, -2.897996453}, upper = {0.053988129, 0.373832854, -2.282055094}, hit = false, distance = 0.000000000},
		{origin = {3.946264537, -4.062736674, -5.722851347}, direction = {-0.619172421, 0.650474875, 0.439895386}, lower = {-1.136042163, -1.064661374, -2.656461354}, upper = {-0.649916836, 0.094718973, -1.715142057}, hit = false, distance = 0.000000000},
		{origin = {-2.866617633, -1.599602499, -3.995495586}, direction = {0.627345669, 0.203734105, 0.751618138}, lower = {-0.827310296, -2.891830034, -0.887562236}, upper = {2.112493183, -0.274519950, 1.261788764}, hit = true, distance = 4.134989818},
		{origin = {3.819995320, 2.878476245, -3.279126120}, direction = {-0.598834748, -0.622431811, 0.503959905}, lower = {-1.681340020, -2.107833308, 0.246044987}, upper = {1.276452922, 0.479527329, 2.703065024}, hit = true, distance = 6.994943592},
		{origin = {5.244254415, 5.856456698, 5.460007576}, direction = {-0.475831497, -0.638095878, -0.605324737}, lower = {-2.888251698, -1.882325844, -1.963302547}, upper = {-0.749190262, 0.995916370, -0.511065049}, hit = false, distance = 0.000000000},
		{origin = {1.835736514, 3.595724938, -4.982658163}, direction = {-0.303828191, -0.450538625, 0.839466126}, lower = {-2.213175346, -2.182506547, -0.503734410}, upper = {0.507688000, 0.370712929, 1.038791183}, hit = true, distance = 7.158125468},
		{origin = {5.659887468, -1.249938059, -1.183358186}, direction = {-0.061695265, 0.816373868, -0.574218950}, lower = {0.000561839, -1.087869022, -2.285913127}, upper = {2.410141046, 0.043179138, 0.156392866}, hit = false, distance = 0.000000000},
		{origin = {5.763671321, 1.887219513, -1.795109854}, direction = {-0.778550838, -0.575392034, 0.250564563}, lower = {-2.491846531, -2.395397198, 0.619408383}, upper = {-0.033640981, -1.786109134, 3.133637723}, hit = false, distance = 0.000000000},
		{origin = {3.913863022, -3.467491952, -2.977982264}, direction = {-0.846097825, 0.046807817, 0.530968454}, lower = {0.883560709, -0.401301321, -0.893675812}, upper = {3.697710163, 1.013365102, 1.747204387}, hit = false, distance = 0.000000000},
		{origin = {1.000185265, 4.851561295, -0.952460751}, direction = {-0.059626285, -0.990741710, -0.121965449}, lower = {-1.962540819, -1.323949789, -2.475705294}, upper = {0.785506939, -0.133354522, -0.992854532}, hit = true, distance = 5.031498894},
		{origin = {-3.931839453, -0.318084810, 2.702319245}, direction = {0.834079717, -0.320298074, -0.449132686}, lower = {-0.905973658, -2.925180528, -1.239500350}, upper = {-0.193271573, -2.714169579, 1.198176911}, hit = false, distance = 0.000000000},
		{origin = {3.267133185, 0.092567902, 0.740752640}, direction = {-0.566660013, 0.411702832, -0.713720679}, lower = {-0.778232500, 0.137089901, -2.575562332}, upper = {0.990596674, 1.032874000, -1.600194534}, hit = false, distance = 0.000000000},
		{origin = {-0.263564184, 5.298013530, 2.390614586}, direction = {0.671600850, 0.001145113, -0.740912267}, lower = {-0.549888463, -0.977787477, -0.951354110}, upper = {1.589758345, 0.488780742, 0.741845115}, hit = false, distance = 0.000000000},
		{origin = {0, 0, 0}, direction = {1, 0, 0}, lower = {-1, -1, -1}, upper = {1, 1, 1}, hit = true, distance = 0},
		{origin = {0, 5, 0}, direction = {1, 0, 0}, lower = {-1, -1, -1}, upper = {1, 1, 1}, hit = false, distance = 0},
		{origin = {-5, 0.5, 0.5}, direction = {1, 0, 0}, lower = {-1, -1, -1}, upper = {1, 1, 1}, hit = true, distance = 4},
		{origin = {0, 0, 5}, direction = {0, 0, 1}, lower = {-1, -1, -1}, upper = {1, 1, 1}, hit = false, distance = 0},
	}

	for c, i in cases {
		distance, hit := ray_box(Ray{origin = c.origin, direction = c.direction}, c.lower, c.upper)
		testing.expectf(t, hit == c.hit, "case %d: hit %v, want %v", i, hit, c.hit)
		if hit && c.hit {
			testing.expectf(t, math.abs(distance - c.distance) < 1e-4, "case %d: distance %.6f, want %.6f", i, distance, c.distance)
		}
	}
}

@(test)
test_ray_plane_and_sphere :: proc(t: ^testing.T) {
	down := Ray{origin = {0, 5, 0}, direction = {0, -1, 0}}

	d, hit := ray_plane(down, {0, 0, 0}, {0, 1, 0})
	testing.expectf(t, hit && math.abs(d - 5) < 1e-5, "straight down onto the floor from 5: %v %v", d, hit)

	_, hit = ray_plane(Ray{origin = {0, 5, 0}, direction = {1, 0, 0}}, {0, 0, 0}, {0, 1, 0})
	testing.expect(t, !hit, "a ray along the floor hit it")

	_, hit = ray_plane(Ray{origin = {0, 5, 0}, direction = {0, 1, 0}}, {0, 0, 0}, {0, 1, 0})
	testing.expect(t, !hit, "a floor behind the ray was hit")

	// Straight at a sphere of radius 2 centred 10 away: in at 8. From its centre:
	// out at 2. Three to the side of the line: missed.
	ahead := Ray{origin = {0, 0, 0}, direction = {0, 0, -1}}
	d, hit = ray_sphere(ahead, {0, 0, -10}, 2)
	testing.expectf(t, hit && math.abs(d - 8) < 1e-5, "sphere ahead: %v %v", d, hit)

	d, hit = ray_sphere(Ray{origin = {0, 0, -10}, direction = {0, 0, -1}}, {0, 0, -10}, 2)
	testing.expectf(t, hit && math.abs(d - 2) < 1e-5, "from inside: %v %v", d, hit)

	_, hit = ray_sphere(Ray{origin = {3, 0, 0}, direction = {0, 0, -1}}, {0, 0, -10}, 2)
	testing.expect(t, !hit, "a ray three to the side hit a sphere of radius two")
}

@(test)
test_ray_oriented_box_turned_scaled_and_moved :: proc(t: ^testing.T) {
	// A unit box stretched to 2 along its own X, turned 90 degrees about Y --
	// which takes its X to world -Z and its Z to world X -- and moved to
	// (10, 0, 0). Across world X it is now 1 wide, 9.5 to 10.5; across world Z
	// it is 2 deep, -1 to 1.
	transform := transform_matrix(Transform{
		position = {10, 0, 0},
		rotation = transform_rotation({0, 1, 0}, math.PI * 0.5),
		scale    = {2, 1, 1},
	})

	d, hit := ray_oriented_box(Ray{origin = {0, 0, 0}, direction = {1, 0, 0}}, {-0.5, -0.5, -0.5}, {0.5, 0.5, 0.5}, transform)
	testing.expectf(t, hit && math.abs(d - 9.5) < 1e-4, "along X: %v %v, want 9.5", d, hit)

	d, hit = ray_oriented_box(Ray{origin = {10, 0, 10}, direction = {0, 0, -1}}, {-0.5, -0.5, -0.5}, {0.5, 0.5, 0.5}, transform)
	testing.expectf(t, hit && math.abs(d - 9) < 1e-4, "along -Z: %v %v, want 9", d, hit)

	_, hit = ray_oriented_box(Ray{origin = {10.8, 0, 10}, direction = {0, 0, -1}}, {-0.5, -0.5, -0.5}, {0.5, 0.5, 0.5}, transform)
	testing.expect(t, !hit, "a ray 0.8 off-centre passed through a box 0.5 either side")
}

@(test)
test_world_to_screen_and_back_passes_through_the_point :: proc(t: ^testing.T) {
	mbi.width  = 1280
	mbi.height = 720

	ortho_camera := create_camera3d({4, 6, 9}, {0, 0, 0})
	ortho_camera.projection = .ORTHOGRAPHIC
	ortho_camera.fov = 12

	cameras := []Camera3D{
		create_camera3d({6, 5, 8}, {0, 0.5, 0}, 70),
		create_camera3d({-3, 15, 5}, {1, 0, -1}, 45),
		ortho_camera,
	}
	viewports := []Rectangle{
		{},                                                           // the whole window
		{position = {260, 44}, size = {740, 446}, pivot = {0.5, 0.5}}, // an editor's viewport
	}

	for camera, ci in cameras {
		for viewport, vi in viewports {
			for x in -2 ..= 2 {
				for z in -2 ..= 2 {
					point := [3]f32{f32(x) * 1.5, 0.25 * f32(x + z), f32(z) * 1.5}

					screen, in_front := world_to_screen(camera, point, viewport)
					if !testing.expectf(t, in_front, "camera %d: %v reported behind", ci, point) do continue

					ray := ray_from_screen(camera, screen, viewport)
					along := linalg.dot(point - ray.origin, ray.direction)
					miss  := linalg.length(point - ray_point(ray, along))

					what := fmt.tprintf("camera %d viewport %d point %v", ci, vi, point)
					testing.expectf(t, along > 0, "%s: the point is behind the ray", what)
					testing.expectf(t, miss < 1e-3, "%s: the ray misses by %.6f", what, miss)
				}
			}
		}
	}
}

@(test)
test_the_middle_of_a_viewport_and_the_mouse_ray :: proc(t: ^testing.T) {
	camera   := create_camera3d({0, 0, 10}, {0, 0, 0})
	viewport := Rectangle{position = {100, 50}, size = {400, 300}, pivot = {0.5, 0.5}}

	// What the camera looks at lands in the middle of the viewport: (100 + 200,
	// 50 + 150). Behind the camera is not in front.
	screen, in_front := world_to_screen(camera, {0, 0, 0}, viewport)
	testing.expectf(t, in_front && math.abs(screen.x - 300) < 1e-3 && math.abs(screen.y - 200) < 1e-3, "centre: %v %v", screen, in_front)

	_, in_front = world_to_screen(camera, {0, 0, 20}, viewport)
	testing.expect(t, !in_front, "a point behind the camera was in front")

	// Up the world is up the screen: a smaller y.
	above, _ := world_to_screen(camera, {0, 1, 0}, viewport)
	testing.expectf(t, above.y < 200, "a point above the centre landed at y %v", above.y)

	// The pointer in the middle casts straight ahead, from the near plane 0.1
	// in front of the camera.
	mbi.input.mouse.x = 300
	mbi.input.mouse.y = 200
	ray := get_mouse_ray(camera, viewport)
	testing.expectf(t, linalg.length(ray.direction - {0, 0, -1}) < 1e-4, "direction %v", ray.direction)
	testing.expectf(t, linalg.length(ray.origin - {0, 0, 9.9}) < 1e-3, "origin %v", ray.origin)
}
