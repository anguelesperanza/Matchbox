package matchbox

/*
	Shapes -- 3D
	------------
	Cubes, planes, spheres, wireframes and a ground grid, drawn without loading
	or building anything first.

	These are the 3D counterpart of `draw_rect` and they work the same way: you
	say where and how big, and the geometry is somebody else's problem. Behind
	them is one shared model per shape, built the first time it is asked for and
	scaled by the transform on every draw after that -- so a hundred cubes are a
	hundred draws of one vertex buffer rather than a hundred buffers.

	Built on demand rather than at `init`, for the same reason the depth texture
	is: a game that never draws a sphere should not be carrying one. A 2D
	program touches none of this.

	When a shape is drawn thousands of times, or wants its own vertices, the
	generators in model.odin are the same shapes without the sharing --
	`cube_model`, `sphere_model` and the rest hand back a Model to keep.
*/

// -----------------------------------------------------------------------
// The shared shapes
// -----------------------------------------------------------------------

@(private)
shapes3d_cube :: proc() -> Model {
	r := &mbi.renderer
	if r.unit_cube.parts == nil do r.unit_cube = cube_model(1)
	return r.unit_cube
}

@(private)
shapes3d_cube_wires :: proc() -> Model {
	r := &mbi.renderer
	if r.unit_cube_wires.parts == nil do r.unit_cube_wires = cube_wires_model(1)
	return r.unit_cube_wires
}

@(private)
shapes3d_plane :: proc() -> Model {
	r := &mbi.renderer
	if r.unit_plane.parts == nil do r.unit_plane = plane_model(1)
	return r.unit_plane
}

@(private)
shapes3d_sphere :: proc() -> Model {
	r := &mbi.renderer
	if r.unit_sphere.parts == nil do r.unit_sphere = sphere_model(1)
	return r.unit_sphere
}

// Called by cleanup. Everything here is optional, so all of it is a nil check.
@(private)
shapes3d_destroy :: proc() {
	r := &mbi.renderer

	if r.unit_cube.parts       != nil do destroy_model(&r.unit_cube)
	if r.unit_cube_wires.parts != nil do destroy_model(&r.unit_cube_wires)
	if r.unit_plane.parts      != nil do destroy_model(&r.unit_plane)
	if r.unit_sphere.parts     != nil do destroy_model(&r.unit_sphere)
	if r.grid.parts            != nil do destroy_model(&r.grid)
}

// -----------------------------------------------------------------------
// Solids
// -----------------------------------------------------------------------

/*
	A box at `position`, `size` units across each axis.

	`size` is the whole width, not a half-extent, which matches `rl.DrawCube`
	and does *not* match what a physics library wants -- Box3D's `MakeBoxHull`
	takes half-extents. A shape defined by its half-extents is drawn with
	`size = half * 2`, and getting that backwards draws a box a quarter the
	volume of the one you are colliding with.

	`rotation` is the reason this takes a quaternion rather than three angles:
	`b3.Body_GetRotation` returns a `b3.Quat`, which *is* Odin's `quaternion128`,
	so a body's orientation reaches this call without being converted, decomposed
	or rebuilt. Under raylib the same thing needs `rlgl.PushMatrix`, a `Rotatef`
	in degrees off `GetAxisAngle`, and a `PopMatrix`.
*/
draw_cube :: proc(position: [3]f32, size: [3]f32, color: [4]f32 = WHITE, rotation: quaternion128 = 1) {
	draw_model(shapes3d_cube(), Transform{
		position = position,
		rotation = rotation,
		scale    = size,
	}, color)
}

// A flat square on the ground plane at `position`, facing up.
draw_plane :: proc(position: [3]f32, size: [2]f32, color: [4]f32 = WHITE) {
	draw_model(shapes3d_plane(), Transform{
		position = position,
		rotation = 1,
		scale    = {size.x, 1, size.y},
	}, color)
}

// A sphere of `radius` at `position`.
draw_sphere :: proc(position: [3]f32, radius: f32 = 1, color: [4]f32 = WHITE) {
	draw_model(shapes3d_sphere(), Transform{
		position = position,
		rotation = 1,
		scale    = {radius, radius, radius},
	}, color)
}

// -----------------------------------------------------------------------
// Lines
// -----------------------------------------------------------------------

// The twelve edges of a box, same arguments as `draw_cube`. Drawn over the
// solid one it outlines without fighting it -- see the depth bias in
// create_pipeline.
draw_cube_wires :: proc(position: [3]f32, size: [3]f32, color: [4]f32 = BLACK, rotation: quaternion128 = 1) {
	draw_model(shapes3d_cube_wires(), Transform{
		position = position,
		rotation = rotation,
		scale    = size,
	}, color)
}

/*
	The same box, given by its corners rather than its middle.

	This is the one to point at a physics library. `b3.Shape_GetAABB` and
	`b3.Body_ComputeAABB` hand back a `lowerBound` and an `upperBound`, so
	seeing what the solver thinks a body's extent is costs one line:

		aabb := b3.Shape_GetAABB(shape)
		matchbox.draw_bounds_wires(aabb.lowerBound, aabb.upperBound, matchbox.RED)

	Matchbox owns no bounding box type of its own and is not getting one -- see
	D7 in 3d.md -- so this takes two plain vectors and stays ignorant of
	whichever library produced them.
*/
draw_bounds_wires :: proc(lower, upper: [3]f32, color: [4]f32 = WHITE) {
	draw_cube_wires((lower + upper) * 0.5, upper - lower, color)
}

/*
	A grid of lines on the ground plane, centred on the origin, `slices` squares
	across and `spacing` units to a square.

	One grid is kept and reused. Asking for different numbers rebuilds it, which
	is a vertex buffer upload -- fine once, and something to know about before
	animating either argument.
*/
draw_grid :: proc(slices: int = 10, spacing: f32 = 1, color: [4]f32 = {1, 1, 1, 0.35}) {
	r := &mbi.renderer

	if r.grid.parts == nil || r.grid_slices != slices || r.grid_spacing != spacing {
		if r.grid.parts != nil do destroy_model(&r.grid)

		r.grid         = grid_model(slices, spacing)
		r.grid_slices  = slices
		r.grid_spacing = spacing
	}

	draw_model(r.grid, transform_identity(), color)
}
