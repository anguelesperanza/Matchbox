package matchbox

/*
	Area lights -- the representative-point approximation
	---------------------------------------------------------
	`lighting_rework.md` section 8's own P4 gate: "a rect light's contribution
	must fall off correctly with distance and must approach a point light's as
	its area approaches zero... computable on the CPU." There is no GPU here to
	render `sample_light`'s (`shaders/lighting_core.hlsli`) own HLSL, so this
	file is a hand-written CPU mirror of `area_light_representative_point`,
	the one function that method lives in -- the same "mirror the shader
	maths, do not import it" pattern `pbr_test.odin`/`brdf_test.odin` already
	use, since there is nothing on this side of the language boundary to
	import.

	Three things get checked, independently sourced per CLAUDE.md's "verify
	by measuring":

	- **The point-light limit.** As a rectangle's half-extents shrink to zero,
	  its representative point must converge on the light's own position,
	  independent of the view/reflection geometry that fed it -- this is what
	  makes an area light "reduce to a point light of the same colour as the
	  rectangle shrinks to nothing" (light.odin's own doc comment on
	  `create_area_rect_light`), not an assumption resting on the geometry
	  argument alone.
	- **A hand-derived clamp case.** One configuration worked out by hand,
	  in this comment, from the plane geometry alone -- not by running the
	  mirror function and copying its answer -- for both the rectangle and
	  the disk.
	- **Monotonic falloff with distance**, using the *same* attenuation curve
	  a point light already gets (`sample_light`'s own doc comment): once the
	  representative point is fixed by geometry, the distance term is
	  identical arithmetic to a point light's, so what this actually checks
	  is that the mirror computes the right distance, not a new formula.
*/

import "core:math"
import "core:math/linalg"
import "core:testing"

// Mirrors area_light_representative_point (shaders/lighting_core.hlsli)
// statement for statement -- same reflection-ray-against-plane
// construction, same per-axis clamp for a rect, same radial clamp for a
// disk. `surface_normal`/`surface_view` stand in for the two Surface
// fields the real function reads; `light` is packed through `light_uniform`
// first so this exercises the identical bytes the shader would receive,
// not a shape only the CPU side ever sees.
@(private = "file")
area_light_test_representative_point :: proc(light: Light, surface_pos, surface_normal, surface_view: [3]f32) -> [3]f32 {
	u := light_uniform(light, Shadow_Bias{})

	center := u.position.xyz
	normal := linalg.normalize([3]f32{u.target.x, u.target.y, u.target.z})

	right_hint := [3]f32{u.area_right.x, u.area_right.y, u.area_right.z}
	if linalg.dot(right_hint, right_hint) < 1e-8 {
		right_hint = abs(normal.y) < 0.99 ? [3]f32{0, 1, 0} : [3]f32{1, 0, 0}
	}
	right := linalg.normalize(right_hint - normal * linalg.dot(right_hint, normal))
	up    := cross3(normal, right)

	refl  := linalg.reflect(-surface_view, surface_normal)
	denom := linalg.dot(refl, normal)

	point_on_plane: [3]f32
	if abs(denom) > 1e-5 {
		t := linalg.dot(center - surface_pos, normal) / denom
		point_on_plane = t > 0 ? surface_pos + refl * t : center
	} else {
		point_on_plane = center
	}

	local := point_on_plane - center
	lr := linalg.dot(local, right)
	lu := linalg.dot(local, up)

	if u.target.w > 3.5 { // AREA_DISK
		radius := u.area_right.w
		r := math.sqrt(lr * lr + lu * lu)
		if r > radius && r > 0 {
			lr *= radius / r
			lu *= radius / r
		}
	} else { // AREA_RECT
		half_width  := u.area_right.w
		half_height := u.area_size.x
		lr = clamp(lr, -half_width, half_width)
		lu = clamp(lu, -half_height, half_height)
	}

	return center + right * lr + up * lu
}

// linalg.reflect(I, N) here mirrors HLSL's reflect(I, N) = I - 2*dot(N,I)*N
// exactly -- checked once, directly, since every test below depends on the
// two languages agreeing on this one primitive.
@(test)
test_reflect_matches_hlsl_convention :: proc(t: ^testing.T) {
	i := [3]f32{0, 0, 1}
	n := [3]f32{0, 0, -1}
	got := linalg.reflect(i, n)
	// I - 2*dot(N,I)*N = (0,0,1) - 2*(-1)*(0,0,-1) = (0,0,1) - (0,0,2) = (0,0,-1)
	expect_close3(t, got, {0, 0, -1}, "reflect(I,N) must match HLSL's I - 2*dot(N,I)*N")
}

/*
	The hand-derived case from this file's own top comment. A rect light
	centred at (0,0,10), facing -Z (target = (0,0,-1)), right = (1,0,0),
	6 wide / 2 tall (half-extents 3/1). A shading point at (5,2,0) whose
	surface.normal == surface.view == (0,0,1) -- chosen specifically because
	reflect(-view, normal) with view == normal reduces to
	reflect(-normal, normal) = -normal - 2*dot(normal,-normal)*normal =
	-normal + 2*normal = normal, i.e. exactly (0,0,1), which removes the
	reflection formula from the arithmetic and leaves only plane geometry:

		normal_light = (0,0,-1), right = (1,0,0), up = cross(normal,right)
		             = (0,-1,0)
		t = dot(center - surface_pos, normal_light) / dot(refl, normal_light)
		  = dot((-5,-2,10), (0,0,-1)) / dot((0,0,1), (0,0,-1))
		  = -10 / -1 = 10
		point_on_plane = (5,2,0) + (0,0,1)*10 = (5,2,10)
		local = (5,2,10) - (0,0,10) = (5,2,0)
		lr = dot(local,right) = 5,  lu = dot(local,up) = dot((5,2,0),(0,-1,0)) = -2
		clamp: half_width=3 -> lr=3.  half_height=1 -> lu=-1
		rep = (0,0,10) + (1,0,0)*3 + (0,-1,0)*(-1) = (3,1,10)

	Worked out from the plane geometry alone, before this test ever ran --
	not by executing area_light_test_representative_point and reading its
	answer back.
*/
@(test)
test_area_rect_representative_point_hand_derived_clamp :: proc(t: ^testing.T) {
	light := create_area_rect_light(
		position = {0, 0, 10}, normal = {0, 0, -1}, right = {1, 0, 0},
		width = 6, height = 2,
	)

	got := area_light_test_representative_point(light, {5, 2, 0}, {0, 0, 1}, {0, 0, 1})
	expect_close3(t, got, {3, 1, 10}, "rect light representative point")
}

/*
	The disk equivalent of the same hand-derived setup: same light centre,
	facing and reflection geometry, radius 2 (bigger than either rect
	half-extent above so the same unclamped point (5,2,0) local, whose
	radius is sqrt(5^2+2^2) = sqrt(29) =~ 5.385, still clamps).

		r = sqrt(29), radius = 2
		scale = radius / r = 2 / sqrt(29)
		lr = 5 * scale, lu = -2 * scale
		rep = center + right*lr + up*lu

	`right`/`up` are the same (0,0,-1)-facing basis as the rect case (a disk
	still needs a tangent internally to express "in-plane", even though it
	has no preferred one of its own -- light.odin's own doc comment on
	`Light.area_right`), so the clamp direction is identical; only the
	radial (rather than per-axis) clamp differs.
*/
@(test)
test_area_disk_representative_point_hand_derived_clamp :: proc(t: ^testing.T) {
	light := create_area_disk_light(position = {0, 0, 10}, normal = {0, 0, -1}, radius = 2)

	got := area_light_test_representative_point(light, {5, 2, 0}, {0, 0, 1}, {0, 0, 1})

	// r = sqrt(29), radius = 2, scale = radius / r.  lr = 5*scale, lu = -2*scale
	// (unclamped local coords, same as the rect case above before its own
	// per-axis clamp). right = (1,0,0), up = (0,-1,0), so
	// right*lr + up*lu = (5*scale, 0, 0) + (0, 2*scale, 0) = (5*scale, 2*scale, 0)
	// -- the up axis flips the sign of lu's own contribution, which is why the
	// y component below is +2*scale rather than -2*scale.
	scale := f32(2) / math.sqrt(f32(29))
	want  := [3]f32{5 * scale, 2 * scale, 10}

	expect_close3(t, got, want, "disk light representative point")
}

/*
	The point-light limit: shrink a rect light's half-extents toward zero
	while holding a deliberately off-axis view/reflection fixed (the same
	kind of configuration `test_area_rect_representative_point_hand_derived_clamp`
	forces a real clamp for), and the representative point must converge on
	the light's own centre regardless -- `Light_Kind`'s own doc comment
	(light.odin) states this as the defining property of the approximation,
	and this is what checks it rather than trusts the algebra.
*/
@(test)
test_area_rect_converges_to_point_light_as_area_shrinks :: proc(t: ^testing.T) {
	sizes := []f32{1.0, 0.1, 0.01, 0.001, 0.0001}

	prev_distance := f32(math.F32_MAX)
	for size in sizes {
		light := create_area_rect_light(
			position = {0, 0, 10}, normal = {0, 0, -1}, right = {1, 0, 0},
			width = size, height = size,
		)

		got := area_light_test_representative_point(light, {5, 2, 0}, {0, 0, 1}, {0, 0, 1})
		dist := linalg.length(got - [3]f32{0, 0, 10})

		testing.expectf(t, dist < prev_distance || size == sizes[0],
			"representative point should move strictly closer to the light's centre as its area shrinks (size=%.4f, dist=%.6f, prev=%.6f)",
			size, dist, prev_distance)

		prev_distance = dist
	}

	testing.expectf(t, prev_distance < 1e-3,
		"at width=height=0.0001 the representative point should be within 1e-3 of the light's own centre, got distance %.6f", prev_distance)
}

// Same limit, for the disk -- radius shrinking to zero rather than a
// rectangle's two half-extents.
@(test)
test_area_disk_converges_to_point_light_as_radius_shrinks :: proc(t: ^testing.T) {
	radii := []f32{1.0, 0.1, 0.01, 0.001, 0.0001}

	prev_distance := f32(math.F32_MAX)
	for radius in radii {
		light := create_area_disk_light(position = {0, 0, 10}, normal = {0, 0, -1}, radius = radius)

		got := area_light_test_representative_point(light, {5, 2, 0}, {0, 0, 1}, {0, 0, 1})
		dist := linalg.length(got - [3]f32{0, 0, 10})

		testing.expectf(t, dist < prev_distance || radius == radii[0],
			"representative point should move strictly closer to the light's centre as its radius shrinks (radius=%.4f, dist=%.6f, prev=%.6f)",
			radius, dist, prev_distance)

		prev_distance = dist
	}

	testing.expectf(t, prev_distance < 1e-3,
		"at radius=0.0001 the representative point should be within 1e-3 of the light's own centre, got distance %.6f", prev_distance)
}

/*
	Distance falloff: `sample_light`'s own doc comment says an area light
	fades by exactly the point-light curve (`1 / (1 + 0.09*d + 0.032*d^2)`)
	once its representative point is fixed -- so the thing worth checking
	independently is that *this* curve, evaluated at the mirror's own
	distance, is monotonically decreasing as a light is moved further away
	along its own facing normal (which keeps the representative point pinned
	to the light's own centre throughout, since the surface stays on-axis).
	The curve's own monotonicity is a one-line fact checkable by inspection
	(each term is added, never subtracted, as d grows), not something this
	test discovers -- what it actually exercises is that the mirror's own
	distance calculation feeds that curve a growing `d` as the light itself
	moves further from a fixed surface point.
*/
@(test)
test_area_light_attenuation_falls_off_monotonically_with_distance :: proc(t: ^testing.T) {
	surface_pos    := [3]f32{0, 0, 0}
	surface_normal := [3]f32{0, 0, 1}
	surface_view   := [3]f32{0, 0, 1} // on-axis: reflect(-view,normal) == normal == (0,0,1), so the ray points straight at the light's own centre every time

	distances := []f32{2, 5, 10, 20, 50}

	prev_attenuation := f32(math.F32_MAX)
	for d in distances {
		light := create_area_rect_light(
			position = {0, 0, d}, normal = {0, 0, -1}, right = {1, 0, 0},
			width = 1, height = 1,
		)

		rep := area_light_test_representative_point(light, surface_pos, surface_normal, surface_view)
		// On-axis, so this must land exactly on the light's own centre --
		// checked directly rather than assumed, since the falloff check
		// below is only meaningful if the geometry actually stayed pinned.
		expect_close3(t, rep, light.position, "on-axis representative point must equal the light's own position")

		dist        := linalg.length(rep - surface_pos)
		attenuation := 1.0 / (1.0 + 0.09 * dist + 0.032 * dist * dist)

		testing.expectf(t, attenuation < prev_attenuation,
			"attenuation must fall as distance grows (d=%.1f, attenuation=%.6f, prev=%.6f)",
			d, attenuation, prev_attenuation)

		prev_attenuation = attenuation
	}
}
