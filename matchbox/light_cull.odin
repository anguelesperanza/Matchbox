package matchbox

/*
	Light culling -- clustered forward
	------------------------------------
	Frustum culling and cluster assignment for `Render_Pipeline_Kind.CLUSTERED`
	(lighting.odin). The view frustum is chopped into a fixed grid of clusters
	-- `Cluster_Grid`, below -- and every frame's own light list is walked once
	to work out which clusters each light actually reaches; `shade_lights`
	(shaders/lighting_core.hlsli) then loops a fragment's own cluster instead
	of every light in the scene.

	**Why this runs on the CPU, not in a compute shader.** Clustered forward
	is conventionally built with a compute pass assigning lights to clusters,
	and that is the better long-term answer once this package has one -- but
	it has none today. `build_shaders.bat`/`.sh` compile `*.vert.hlsl` and
	`*.frag.hlsl` only; there is no `*.comp.hlsl` pattern, no `cs_6_0` target,
	and nothing anywhere calls `CreateGPUComputePipeline` or
	`BeginGPUComputePass`. Adding one would mean new build-script surface, new
	SDL_GPU API surface this package has never exercised, and -- for a rework
	whose every phase has had to verify itself on the CPU, because there is no
	GPU or capture tooling in this environment (`lighting_rework.md` section
	8) -- landing the one part of this phase that is hardest to get right on
	hardware nobody here can inspect. CPU-side assignment, uploaded as a
	storage buffer the same way `set_lights` (light.odin) already uploads the
	light list itself, costs none of that: no build-script change, no new
	API surface, and the assignment is directly testable
	(`light_cull_test.odin`) the way nothing running only on a GPU could be.
	A 16x9x24 grid is 3456 clusters; testing a handful of lights against all
	of them, every frame, is not work worth measuring. `sample_light`
	(lighting_core.hlsli) still reads the same `Light` `StructuredBuffer`
	either way, so moving the assignment to a compute shader later changes
	who produces `cluster_ranges`/`cluster_light_indices` below and not how
	`shade_lights` consumes them.

	**Grid shape.** 16 columns by 9 rows matches the aspect ratio nearly
	every window this package runs in actually has, so a tile is close to
	square instead of being stretched by an aspect the grid never accounted
	for. 24 depth slices is the number Doom (2016) settled on for the same
	problem and every clustered-forward writeup since has copied for the same
	reason: enough resolution near the camera (where lights are dense and
	overlapping) without paying for a slice count that stops mattering once a
	handful of lights are spread over a whole scene's depth.

	**Z slicing is exponential, not linear.** A linear split wastes most of
	its resolution far from the camera, where a fixed depth range covers many
	more screen pixels than the same range does up close -- the opposite of
	where clustering needs resolution. `cluster_z_bounds` below is the
	standard `near * (far/near)^(slice/count)` curve, which grows each
	slice's own depth range as depth grows, keeping a cluster's world-space
	size roughly comparable near and far.

	**Only PERSPECTIVE gets a shaped frustum.** `cluster_test` builds a
	radial pyramid for a perspective camera -- exact, not an over-approximating
	box, because a tile's own screen-space edges are dead straight lines
	through the eye in view space for a perspective projection, so the four
	side planes of a cluster pass through the origin regardless of which
	depth slice it is. An orthographic camera's tiles are parallel-sided
	instead (there is no eye for them to converge on), so `cluster_test`'s
	other branch is a plain axis-aligned box, exact for the same reason and
	simpler to build. Both are the real cluster shape, not a padded stand-in
	for it -- see this file's own top comment on the gate this gets checked
	against.

	**The shader-side half of this has a real limitation, stated rather than
	hidden.** `cluster_index_for_fragment` (lighting_core.hlsli) recovers a
	fragment's own view-space depth from `1 / SV_Position.w`, which is exact
	for a perspective projection (clip-space w is `-view_z` there) and wrong
	for an orthographic one (clip-space w is always 1, so every fragment
	reads slice 0). `CLUSTERED` under an orthographic camera therefore
	behaves as if there were one depth slice rather than `grid.z` of them --
	not fixed this phase, since a lit scene using an orthographic camera is
	not what `lighting_plan.md`'s clustered-forward section is aimed at, and
	fixing it needs either a raw view-space-z interpolant threaded through
	the vertex stage or a depth-buffer reconstruction, either of which is
	more plumbing than this phase's scope buys back. CPU-side assignment
	(`cluster_build` below) is correct for both projections regardless --
	`light_cull_test.odin` sweeps both -- so the CPU half of this file is not
	the half that has the limitation.
*/

import "core:log"
import "core:math"
import "core:math/linalg"

import sdl "vendor:sdl3"

/*
	How many tiles the view frustum is chopped into along the window's width,
	its height, and view-space depth. See this file's own top comment for why
	16x9x24.

	A fixed array bound would be the wrong shape here even though CLAUDE.md
	carves array sizes out as an exception to "no loose constants": nothing in
	this package holds a `[16][9][24]` array anywhere. `Cluster_State.ranges`/
	`light_indices` (below) are `[dynamic]`, sized off `grid.x*grid.y*grid.z`
	at build time, so a game that wants a coarser or finer grid changes three
	numbers and nothing else needs to know.
*/
Cluster_Grid :: struct {
	x, y, z: int,
}

CLUSTER_GRID_DEFAULTS :: Cluster_Grid{x = 16, y = 9, z = 24}

/*
	Everything `cluster_build` needs besides the camera and the light list
	itself.

	`cutoff` is the attenuation value below which a point/spot/area light's
	own reach is treated as having ended -- see `light_cull_radius`'s own doc
	comment for why a radius has to be manufactured at all, since no light in
	this package stores one. 1/256 is under half a percent of a light's own
	full brightness, which is below what an 8-bit display channel can show as
	a difference from black once tonemapped -- a light beyond that distance
	would not visibly change the picture if it were culled a little early or
	late, which is what makes this a defensible default rather than an
	arbitrary one. Configurable per CLAUDE.md's "configuration rides in as a
	defaulted struct": a game with very bright lights and a wide dynamic
	range under an HDR tonemap curve may want a smaller cutoff so a light
	that is still visibly contributing is not culled at the default's
	distance.
*/
Cluster_Settings :: struct {
	grid:   Cluster_Grid,
	cutoff: f32,
}

CLUSTER_DEFAULTS :: Cluster_Settings{grid = CLUSTER_GRID_DEFAULTS, cutoff = 1.0 / 256.0}

/*
	One cluster's own slice of `Cluster_State.light_indices` -- `offset`
	lights starting there, `count` of them. Matches `Cluster_Range` in
	shaders/lighting_core.hlsli byte for byte: two plain `u32`s, no padding
	either side needs, unlike every uniform-block struct elsewhere in this
	package (`Light_Uniform`, `Scene_Frag_Data`) -- those are cbuffer members
	and HLSL pads a cbuffer to 16-byte boundaries; a `StructuredBuffer`
	element is not a cbuffer and packs its plain scalars tightly, so two
	`u32`s really are 8 bytes on both sides with nothing to assert about it.
*/
Cluster_Range :: struct {
	offset: u32,
	count:  u32,
}

/*
	CPU and GPU state for `CLUSTERED` -- lives on `Lighting.cluster`
	(render.odin) alongside the light list's own `light_data`/`light_buffer`,
	rebuilt and reuploaded once a frame by `pipeline_clustered_begin`
	(pipeline_clustered.odin) rather than only when a game calls a setter,
	because a cluster's own shape depends on the camera and the camera moves
	every frame even when the lights do not.

	`ranges`/`light_indices` are the CPU-side result of `cluster_build`;
	`*_buffer`/`*_transfer` are their GPU-side twins, grown on demand and
	rewritten through the transfer buffer rather than recreated -- the exact
	shape `light.odin`'s own `upload_light_buffer` already established for
	the light list, copied here rather than reinvented. `*_capacity` is how
	many elements the buffer currently holds, which is not `len(ranges)`/
	`len(light_indices)` once either has shrunk from a previous, larger grid
	or a previous frame with more lights reaching more clusters.
*/
Cluster_State :: struct {
	settings: Cluster_Settings,

	ranges:        [dynamic]Cluster_Range,
	light_indices: [dynamic]u32,

	ranges_buffer:   ^sdl.GPUBuffer,
	ranges_transfer: ^sdl.GPUTransferBuffer,
	ranges_capacity: int,

	light_indices_buffer:   ^sdl.GPUBuffer,
	light_indices_transfer: ^sdl.GPUTransferBuffer,
	light_indices_capacity: int,
}

/*
	Zero means the default, the same rule `lighting_settings_normalized`
	(lighting.odin) states once and applies to every settings struct in this
	package. `grid.x`/`grid.y`/`grid.z` of zero is not a legitimate grid --
	a cluster count of zero along any axis divides by zero the moment
	`cluster_build` works out a tile's own NDC width -- so it reads as "not
	set" the same way `Lighting_Settings.exposure` does. `cutoff` of zero
	would ask for a light to reach every cluster its attenuation curve is
	merely still positive at, which is every cluster in any reasonably sized
	scene (the curve is asymptotic, never truly zero) -- the one value that
	would make clustering pointless is exactly the one this treats as unset.
*/
@(private)
cluster_settings_normalized :: proc(settings: Cluster_Settings) -> Cluster_Settings {
	s := settings
	if s.grid.x == 0 do s.grid.x = CLUSTER_GRID_DEFAULTS.x
	if s.grid.y == 0 do s.grid.y = CLUSTER_GRID_DEFAULTS.y
	if s.grid.z == 0 do s.grid.z = CLUSTER_GRID_DEFAULTS.z
	if s.cutoff == 0 do s.cutoff = CLUSTER_DEFAULTS.cutoff
	return s
}

// -----------------------------------------------------------------------
// Geometry
// -----------------------------------------------------------------------

/*
	The view frustum's own shape, worked out once per frame from the camera
	and the window rather than per cluster -- `cluster_test` below reads this
	for every one of a grid's clusters, and none of it changes between them.

	`tan_x`/`tan_y` are PERSPECTIVE's own half-angle tangents at view-space
	depth 1: the frustum's half-width/half-height at any depth `d` is
	`d * tan_x`/`d * tan_y`, which is what makes a tile's own side planes
	radial (pass through the origin) rather than needing a per-depth
	recomputation. `half_w`/`half_h` are ORTHOGRAPHIC's own constant
	half-extent instead, the same at every depth by definition -- see this
	file's own top comment for why the two projections get different
	branches in `cluster_test` rather than a shared approximation.
*/
@(private)
Cluster_Frustum :: struct {
	projection:     Camera3D_Projection,
	tan_x, tan_y:   f32,
	half_w, half_h: f32,
	near, far:      f32,
	nx, ny, nz:     int,
}

@(private)
cluster_frustum_from_camera :: proc(camera: Camera3D, grid: Cluster_Grid) -> Cluster_Frustum {
	c := camera3d_defaults(camera)

	width  := f32(mbi.window_width)
	height := f32(mbi.window_height)
	aspect: f32 = 1
	if height > 0 do aspect = width / height

	f: Cluster_Frustum
	f.projection = c.projection
	f.near = c.near
	f.far  = c.far
	f.nx = max(grid.x, 1)
	f.ny = max(grid.y, 1)
	f.nz = max(grid.z, 1)

	switch c.projection {
	case .ORTHOGRAPHIC:
		f.half_h = c.fov * 0.5 // Camera3D_Projection's own doc comment: fov is a world-space height here, not an angle
		f.half_w = f.half_h * aspect
	case .PERSPECTIVE:
		fallthrough
	case:
		f.tan_y = math.tan(math.to_radians(c.fov) * 0.5)
		f.tan_x = f.tan_y * aspect
	}

	return f
}

// The NDC range tile `t` (of `n`) covers along X: tile 0 starts at NDC -1,
// tile n-1 ends at NDC 1, increasing left to right the same way NDC does.
@(private)
cluster_ndc_range :: proc(t, n: int) -> (lo, hi: f32) {
	lo = -1 + 2 * f32(t) / f32(n)
	hi = -1 + 2 * f32(t + 1) / f32(n)
	return
}

/*
	The NDC range tile `t` (of `n`) covers along Y -- top-down, so tile 0 is
	the top row of the screen, matching `SV_Position.y`'s own orientation
	(row 0 at the top, increasing downward). NDC +1 is top (math3d.odin's own
	top comment on SDL3_GPU's convention), so tile 0's own NDC range is the
	*high* end and tile n-1's is the low end -- the reverse of X, which is
	why this is not just `cluster_ndc_range` called with the axes swapped.
	`cluster_index_for_fragment` (lighting_core.hlsli) needs no flip to
	match this, unlike `shadow_sample_pcf`'s own V-flip (shaders/shadow/pcf.hlsli)
	for a different mapping.
*/
@(private)
cluster_ndc_range_y :: proc(t, n: int) -> (lo, hi: f32) {
	hi = 1 - 2 * f32(t) / f32(n)
	lo = 1 - 2 * f32(t + 1) / f32(n)
	return
}

/*
	Slice `s`'s own view-space depth range (of `count` total), the
	exponential curve this file's own top comment names --
	`near * (far/near)^(s/count)`. `cluster_index_for_fragment`
	(lighting_core.hlsli) inverts this same formula to recover which slice a
	fragment's own depth falls in; the two must agree, or a fragment reads a
	neighbouring cluster's light list instead of its own.
*/
@(private)
cluster_z_bounds :: proc(s, count: int, near, far: f32) -> (z_near, z_far: f32) {
	ratio := far / near
	z_near = near * math.pow(ratio, f32(s) / f32(count))
	z_far  = near * math.pow(ratio, f32(s + 1) / f32(count))
	return
}

/*
	Whether a sphere at `p` (view space) with radius `r` crosses to the
	inside of the half-space `n . p >= 0`, where `n` need not be unit length
	-- every plane `cluster_test` builds passes through the origin (see
	`Cluster_Frustum`'s own doc comment on why), so there is no per-plane
	distance term to add here the way a general plane equation would need.

	A degenerate `n` (length under `1e-8`) returns true rather than dividing
	by it -- unreachable for a real camera (`tan_x`/`tan_y` are never zero
	for a finite fov, and `x0`/`x1`/`y0`/`y1` never both land on zero for a
	tile that exists at all), kept as a defensive fallback rather than an
	unchecked division the same way `area_light_representative_point`
	(lighting_core.hlsli) guards its own near-zero denominator.
*/
@(private)
cluster_plane_overlap :: proc(p: [3]f32, r: f32, n: [3]f32) -> bool {
	length := linalg.length(n)
	if length < 1e-8 do return true
	distance := linalg.dot(p, n) / length
	return distance >= -r
}

/*
	Whether a sphere at `view_center` (view space) with radius `radius`
	reaches cluster `(tx, ty, tz)` of `f`'s own grid -- the one predicate
	`cluster_build` calls once per light per candidate cluster.

	The Z slab is checked before either X/Y branch, since it is the same
	arithmetic either way and rejects the common case (a light far outside a
	cluster's own depth range) without needing the camera's projection at
	all.

	See `Cluster_Frustum`'s own doc comment for why PERSPECTIVE gets four
	radial planes and ORTHOGRAPHIC gets a plain box -- both are the cluster's
	real shape, not a stand-in for it, which is what `light_cull_test.odin`'s
	own sweep checks against an independently-derived expectation rather than
	trusting the geometry argument alone.
*/
@(private)
cluster_test :: proc(f: Cluster_Frustum, view_center: [3]f32, radius: f32, tx, ty, tz: int) -> bool {
	z_near, z_far := cluster_z_bounds(tz, f.nz, f.near, f.far)
	d := -view_center.z
	if d + radius < z_near do return false
	if d - radius > z_far  do return false

	x0, x1 := cluster_ndc_range(tx, f.nx)
	y0, y1 := cluster_ndc_range_y(ty, f.ny)

	switch f.projection {
	case .ORTHOGRAPHIC:
		lo_x := x0 * f.half_w
		hi_x := x1 * f.half_w
		lo_y := y0 * f.half_h
		hi_y := y1 * f.half_h
		if view_center.x + radius < lo_x do return false
		if view_center.x - radius > hi_x do return false
		if view_center.y + radius < lo_y do return false
		if view_center.y - radius > hi_y do return false
		return true
	case .PERSPECTIVE:
		fallthrough
	case:
		if !cluster_plane_overlap(view_center, radius, {1, 0, f.tan_x * x0})   do return false
		if !cluster_plane_overlap(view_center, radius, {-1, 0, -f.tan_x * x1}) do return false
		if !cluster_plane_overlap(view_center, radius, {0, 1, f.tan_y * y0})   do return false
		if !cluster_plane_overlap(view_center, radius, {0, -1, -f.tan_y * y1}) do return false
		return true
	}
}

/*
	The distance at which the point/spot/area attenuation curve
	(`sample_light`'s own doc comment, lighting_core.hlsli:
	`1 / (1 + 0.09*d + 0.032*d^2)`) drops to `cutoff` -- the radius
	`cluster_build` gives a light with no radius of its own to give it. No
	light in this package stores one: `Light` (light.odin) has a position and
	a colour, and how far it reaches has always been an emergent property of
	the curve rather than a stated number, unlike, say, Unity or Unreal's own
	point lights which carry an explicit range. Manufacturing one here rather
	than adding a field to `Light` keeps this a property of the curve
	(already shared, already the one both `FORWARD` and `CLUSTERED` shade
	against) instead of a second number a game would have to keep in step
	with a light's own colour and distance falloff by hand.

	Solved directly rather than searched for: `1/(1+0.09d+0.032d^2) = cutoff`
	rearranges to `0.032d^2 + 0.09d + (1 - 1/cutoff) = 0`, a plain quadratic
	in `d` with `0.032`/`0.09` copied verbatim from the shader's own curve.
	`1 - 1/cutoff` is negative for any `cutoff` under 1 (the only sensible
	range), which makes the discriminant strictly positive and the positive
	root the only one worth taking -- there is always a real answer, never a
	NaN to guard against.
*/
@(private)
light_cull_radius :: proc(cutoff: f32) -> f32 {
	a: f32 = 0.032
	b: f32 = 0.09
	c := 1 - 1 / cutoff
	discriminant := b * b - 4 * a * c
	return (-b + math.sqrt(discriminant)) / (2 * a)
}

/*
	The world-space sphere `cluster_build` tests a light against, read off
	the same `Light_Uniform` bytes `sample_light` (lighting_core.hlsli)
	shades from -- not the `Light` a game built, which `set_lights`
	(light.odin) has already converted and discarded by the time a frame's
	own clustering runs. `always == true` (a directional light) means
	"every cluster", the same "no position, not culled" property
	`Ambient` (lighting.odin) already has for a different reason -- `center`/
	`radius` are meaningless for it and left zero.

	**Area lights are padded, not measured exactly.** `sample_light` shades
	an area light from a representative point that can land anywhere on its
	own rectangle or disk (`area_light_representative_point`'s own doc
	comment, lighting_core.hlsli), not from `position` itself -- so a sphere
	centred on `position` alone would be too small by up to the shape's own
	half-extent. `linalg.length(area_size)` is that shape's own diagonal
	(a rectangle's half-width/half-height, or a disk's radius with its
	unused second component at zero -- `Light.area_size`'s own doc comment,
	light.odin, for why both fit the same two floats), added to the
	punctual-light radius so the padded sphere always contains every point
	the representative-point method could ever pick. This can only ever
	include a light in *more* clusters than its shape strictly reaches, never
	fewer -- the safe direction for the property this file's own gate
	insists on.
*/
@(private)
cluster_light_sphere :: proc(u: Light_Uniform, cutoff: f32) -> (center: [3]f32, radius: f32, always: bool) {
	kind := u.target.w

	if kind < 0.5 { // DIRECTIONAL
		return {}, 0, true
	}

	center = u.position.xyz

	if kind < 2.5 { // POINT, SPOT
		return center, light_cull_radius(cutoff), false
	}

	// AREA_RECT, AREA_DISK
	padding := linalg.length([2]f32{u.area_right.w, u.area_size.x})
	return center, light_cull_radius(cutoff) + padding, false
}

/*
	Assigns every light in `light_data` to the clusters its own influence
	reaches, filling `ranges`/`indices` -- `Cluster_State.ranges`/
	`light_indices` at the one call site (`cluster_build_and_upload`,
	below), a pair of plain out-parameters here so `light_cull_test.odin` can
	drive this directly with a scratch pair of its own and no GPU, `Renderer`
	or frame in sight.

	**Counted, then flattened**, rather than appended to `indices` as each
	light is found to reach a cluster: a light found to reach cluster 40
	before cluster 12 would otherwise split cluster 12's own entries across
	two disjoint ranges, and `Cluster_Range` only has room for one `offset`/
	`count` pair. `per_cluster` collects each cluster's own list first (on
	`context.temp_allocator`, freed with everything else this frame allocated
	there rather than needing its own delete), and the final pass writes each
	one's own contiguous slice into `indices` while recording where it
	started.

	Every cluster gets a range even if `count` is 0 -- `ranges` is
	`resize`d up front to `nx*ny*nz` entries, indexed by
	`tx + ty*nx + tz*nx*ny`, so `cluster_index_for_fragment`
	(lighting_core.hlsli) can compute a fragment's own index and read
	`ranges[index]` unconditionally rather than needing a bounds check for
	"is anything here at all".
*/
@(private)
cluster_build :: proc(
	camera:     Camera3D,
	light_data: []Light_Uniform,
	settings:   Cluster_Settings,
	ranges:     ^[dynamic]Cluster_Range,
	indices:    ^[dynamic]u32,
) {
	grid := settings.grid
	nx, ny, nz := max(grid.x, 1), max(grid.y, 1), max(grid.z, 1)
	total := nx * ny * nz

	clear(ranges)
	resize(ranges, total)
	clear(indices)

	view := camera3d_view(camera)
	f    := cluster_frustum_from_camera(camera, grid)

	per_cluster := make([][dynamic]u32, total, context.temp_allocator)
	for i in 0 ..< total {
		per_cluster[i] = make([dynamic]u32, 0, context.temp_allocator)
	}

	for u, light_index in light_data {
		center, radius, always := cluster_light_sphere(u, settings.cutoff)

		if always {
			for i in 0 ..< total {
				append(&per_cluster[i], u32(light_index))
			}
			continue
		}

		view_point  := view * [4]f32{center.x, center.y, center.z, 1}
		view_center := view_point.xyz

		for tz in 0 ..< nz {
			z_near, z_far := cluster_z_bounds(tz, nz, f.near, f.far)
			d := -view_center.z
			if d + radius < z_near do continue
			if d - radius > z_far  do continue

			for ty in 0 ..< ny {
				for tx in 0 ..< nx {
					if cluster_test(f, view_center, radius, tx, ty, tz) {
						append(&per_cluster[tx + ty * nx + tz * nx * ny], u32(light_index))
					}
				}
			}
		}
	}

	offset: u32 = 0
	for i in 0 ..< total {
		count := u32(len(per_cluster[i]))
		ranges[i] = Cluster_Range{offset = offset, count = count}
		for v in per_cluster[i] {
			append(indices, v)
		}
		offset += count
	}
}

// -----------------------------------------------------------------------
// GPU upload
// -----------------------------------------------------------------------

/*
	Rebuilds `Lighting.cluster`'s own CPU lists for the camera `begin_drawing_3d`
	was just called with, and reuploads both -- called once a frame, from
	`pipeline_clustered_begin` (pipeline_clustered.odin), unlike the light
	list itself which only rebuilds when a game calls `set_lights`. A
	cluster's own shape depends on the camera, and the camera is free to move
	every frame even when not one light does, so there is no cheaper trigger
	to rebuild on than "every frame this pipeline is selected" -- the same
	reasoning `push_lighting` already applies to the camera-derived half of
	`Scene_Frag_Data`.
*/
@(private)
cluster_build_and_upload :: proc(camera: Camera3D) {
	l := &mbi.renderer.lighting
	c := &l.cluster

	cluster_build(camera, l.light_data[:], c.settings, &c.ranges, &c.light_indices)
	cluster_upload_ranges()
	cluster_upload_light_indices()
}

/*
	Grows and rewrites `Cluster_State.ranges_buffer` from `ranges` -- the
	identical shape `upload_light_buffer` (light.odin) already established
	for the light list, copied rather than shared behind a generic helper:
	CLAUDE.md's own "write the reasoning" asks for comments that explain a
	real decision, and there is no decision left to explain a second time
	here that `upload_light_buffer`'s own doc comment does not already cover
	-- this is that same shape, done again for a different buffer.

	At least one element always exists, even with every cluster empty: the
	mesh fragment shader declares `cluster_ranges` unconditionally (see
	lighting_core.hlsli's own comment on why `lights` already has to work
	this way), so a scene with `CLUSTERED` selected and zero lights set still
	needs something valid bound.
*/
@(private)
cluster_upload_ranges :: proc() {
	c := &mbi.renderer.lighting.cluster
	if mbi.renderer.device == nil do return

	scratch := [1]Cluster_Range{}
	data    := c.ranges[:] if len(c.ranges) > 0 else scratch[:]
	size    := u32(len(data)) * size_of(Cluster_Range)

	if len(data) > c.ranges_capacity {
		if c.ranges_buffer   != nil do sdl.ReleaseGPUBuffer(mbi.renderer.device, c.ranges_buffer)
		if c.ranges_transfer != nil do sdl.ReleaseGPUTransferBuffer(mbi.renderer.device, c.ranges_transfer)
		c.ranges_buffer, c.ranges_transfer, c.ranges_capacity = nil, nil, 0

		buffer, err := upload_buffer(raw_data(data), size, {.GRAPHICS_STORAGE_READ})
		if err != nil {
			log.errorf("could not create the cluster range buffer: %v", err)
			return
		}

		c.ranges_buffer   = buffer
		c.ranges_transfer = sdl.CreateGPUTransferBuffer(mbi.renderer.device, {usage = .UPLOAD, size = size})
		c.ranges_capacity = len(data)
		return
	}

	if c.ranges_buffer == nil || c.ranges_transfer == nil do return

	if err := rewrite_buffer(c.ranges_buffer, c.ranges_transfer, raw_data(data), size); err != nil {
		log.errorf("could not update the cluster range buffer: %v", err)
	}
}

// The same shape as `cluster_upload_ranges` just above, for the flat light
// index list instead of the per-cluster ranges into it.
@(private)
cluster_upload_light_indices :: proc() {
	c := &mbi.renderer.lighting.cluster
	if mbi.renderer.device == nil do return

	scratch := [1]u32{0}
	data    := c.light_indices[:] if len(c.light_indices) > 0 else scratch[:]
	size    := u32(len(data)) * size_of(u32)

	if len(data) > c.light_indices_capacity {
		if c.light_indices_buffer   != nil do sdl.ReleaseGPUBuffer(mbi.renderer.device, c.light_indices_buffer)
		if c.light_indices_transfer != nil do sdl.ReleaseGPUTransferBuffer(mbi.renderer.device, c.light_indices_transfer)
		c.light_indices_buffer, c.light_indices_transfer, c.light_indices_capacity = nil, nil, 0

		buffer, err := upload_buffer(raw_data(data), size, {.GRAPHICS_STORAGE_READ})
		if err != nil {
			log.errorf("could not create the cluster light-index buffer: %v", err)
			return
		}

		c.light_indices_buffer   = buffer
		c.light_indices_transfer = sdl.CreateGPUTransferBuffer(mbi.renderer.device, {usage = .UPLOAD, size = size})
		c.light_indices_capacity = len(data)
		return
	}

	if c.light_indices_buffer == nil || c.light_indices_transfer == nil do return

	if err := rewrite_buffer(c.light_indices_buffer, c.light_indices_transfer, raw_data(data), size); err != nil {
		log.errorf("could not update the cluster light-index buffer: %v", err)
	}
}
