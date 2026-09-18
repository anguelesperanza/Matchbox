package matchbox

import "core:math"

/*
	PSX geometry
	------------
	The two things the PlayStation got wrong while drawing a triangle, which a
	game going for its look wants back: vertices that jitter between whole
	pixels, and textures that swim across large polygons.

	**These are not post effects, and that is why they are here rather than on
	`Post_Effect`.** `draw_post` works on a finished picture, and by then both
	of these have already not happened -- a vertex has been placed at its exact
	position and a texture mapped with perspective correction, and nothing
	reading the pixels afterwards can tell where a triangle's corners were.
	Both have to be done while the model is drawn, in the vertex shader and the
	fragment shader it feeds (shaders/psx_geometry.hlsli).

	**Both are off unless a game turns them on**, through `Lighting_Settings.psx`
	-- most games are not going for this look, and the zero value draws exactly
	what Matchbox drew before this existed. Rides on `Lighting_Settings` for the
	reason `Post_Settings` does: scene state, set when the look is chosen and
	read by the 3D pass.

	The procedures below are the CPU mirrors of that include, statement for
	statement, and are what the tests check -- there is no GPU capture here, so
	the shader is trusted to match them rather than measured, the same
	arrangement tonemap.odin has with tonemap.frag.hlsl.
*/

/*
	How a scene's models are rasterized, for a PlayStation look.

		mb.set_lighting({
			enabled = true,
			psx     = {snap_vertices = true, affine_textures = true},
		})
		...
		mb.draw_post(scene, .PIXELATE, {320, 240})

	- `snap_vertices` rounds every vertex to a corner of `grid`, a grid of
	  cells across wherever 3D is being drawn. It moves where a vertex lands
	  on screen and nothing else: lighting, fog and shadows still use the
	  exact position, so they stay put while the edges jitter.
	- `grid` wants to be the grid given to `draw_post` for `.PSX` or
	  `.PIXELATE`, so the triangles' edges fall on the edges of the coarse
	  pixels. Zero reads as 320x240, the PlayStation's own; a snap to no cells
	  is not a value anybody could mean.
	- `affine_textures` maps textures linearly across the screen rather than
	  with perspective correction, so they bend and swim on anything large and
	  close to the camera -- the floor under the player, mostly. It changes
	  nothing under an orthographic camera, which has no perspective to leave
	  out.

	Neither applies to the shadow pass: a shadow map drawn from a snapped
	model would put the shadow a fraction of a cell away from the surface
	it is tested against, which reads as acne rather than as a look.

	The three are independent -- either switch works without the other, and
	without `draw_post` -- but the PlayStation's picture is all three on the
	same grid. Snapping alone jitters edges by whole cells across a picture
	that is otherwise sharp, which reads less like a console than like a bug.
*/
Psx_Geometry :: struct {
	snap_vertices:   bool,
	grid:            [2]f32,
	affine_textures: bool,
}

// A grid of zero cells in either direction is replaced with this. See
// Psx_Geometry.grid.
PSX_GEOMETRY_DEFAULTS :: Psx_Geometry{grid = {320, 240}}

// See lighting_settings_normalized for the rule. `grid` alone has no
// sensible zero; both switches are off at zero, which is what off means.
@(private)
psx_geometry_normalized :: proc(settings: Psx_Geometry) -> Psx_Geometry {
	s := settings
	if s.grid.x <= 0 || s.grid.y <= 0 do s.grid = PSX_GEOMETRY_DEFAULTS.grid
	return s
}

/*
	What `draw_model_immediate` pushes in `Mesh_Vert_Data` for one draw: the
	grid to snap to, zero when snapping is off, and 1 or 0 for affine mapping.

	Zero for both during a shadow pass, whatever the settings say -- see
	Psx_Geometry's own doc comment for why a snapped shadow caster is a bug
	rather than part of the look.
*/
@(private)
psx_geometry_switches :: proc(settings: Psx_Geometry, in_shadow_pass: bool) -> (snap_grid: [2]f32, affine: f32) {
	if in_shadow_pass do return

	if settings.snap_vertices   do snap_grid = settings.grid
	if settings.affine_textures do affine    = 1
	return
}

// psx_snap (psx_geometry.hlsli), on the CPU. See that procedure for the
// reasoning.
@(private)
psx_snap :: proc(clip: [4]f32, grid: [2]f32) -> [4]f32 {
	if grid.x <= 0 || grid.y <= 0 || clip.w <= 0 do return clip

	ndc   := clip.xy / clip.w
	cells := [2]f32{
		math.floor((ndc.x * 0.5 + 0.5) * grid.x + 0.5),
		math.floor((ndc.y * 0.5 + 0.5) * grid.y + 0.5),
	}

	out := clip
	out.xy = (cells / grid * 2 - 1) * clip.w
	return out
}

// psx_uv (psx_geometry.hlsli), on the CPU.
@(private)
psx_uv :: proc(uv: [2]f32, clip: [4]f32, affine: f32) -> [3]f32 {
	q := clip.w if affine > 0.5 else 1
	return {uv.x * q, uv.y * q, q}
}

// psx_uv_resolve (psx_geometry.hlsli), on the CPU.
@(private)
psx_uv_resolve :: proc(uvq: [3]f32) -> [2]f32 {
	return uvq.xy / uvq.z
}
