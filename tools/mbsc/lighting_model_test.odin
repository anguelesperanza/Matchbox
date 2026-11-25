package mbsc

import "core:fmt"
import "core:math"
import "core:testing"

/*
	The light built-ins three ways (G2 L3, docs/3ds_fragment_lighting_plan.md):
	- `calculate_light_reference` is what they mean, in f64: the formula lighting.odin's comment states. It stands
	  where the IR interpreter would: the built-ins are fragment only and have no PICA program to run it against.
	- `calculate_light_3ds` is what the 3DS's fragment lighting unit does with the same scene, as the runtime will set
	  it (L4): colours stored as 8-bit, the specular power read from the 256-entry D0 table LightLut_Phong builds
	  (12-bit entries, 11-bit differences, linear between entries, indexed by |N.H|), and the results written as 8-bit.
	- the generated HLSL, run on the D3D software device (lighting_pixels_windows_test.odin).

	Only pixels facing the eye are compared. One seen from behind (drawn only with culling off) differs on purpose:
	the unit indexes D0 by |N.H|, so a highlight can show there where the formula's max(N.H, 0) gives none.

	The model of the unit follows how citro3d builds its registers and tables (LightLut_FromFunc, the material
	products in C3D_LightEnvMaterial). The unit's own fixed-point dot products are not modelled; their error is well
	under the 8-bit steps the tolerance allows for.
*/

// Light_Scene is what the lights block and the part's material hold, before any target stores it.
Light_Scene :: struct {
	ambient:           [3]f32,
	direction:         [8][3]f32, // towards the light, eye space; zero in an unused slot
	diffuse:           [8][3]f32,
	specular:          [8][3]f32,
	shininess:         f32,
	specular_strength: f32,
}

// Light_Result is the two built-ins' answers for one pixel, alpha left out: both are 1 on every target.
Light_Result :: struct {
	diffuse:  [3]f64,
	specular: [3]f64,
}

// calculate_light_normal is +Z turned by the quaternion (vector part, scalar), the quaternion normalized first.
calculate_light_normal :: proc(quat: [4]f32) -> [3]f64 {
	q := [4]f64{f64(quat.x), f64(quat.y), f64(quat.z), f64(quat.w)}
	length := math.sqrt(q.x * q.x + q.y * q.y + q.z * q.z + q.w * q.w)
	q /= length
	return {2 * (q.x * q.z + q.w * q.y), 2 * (q.y * q.z - q.w * q.x), 1 - 2 * (q.x * q.x + q.y * q.y)}
}

@(private = "file")
calculate_unit :: proc(v: [3]f64) -> [3]f64 {
	length_squared := v.x * v.x + v.y * v.y + v.z * v.z
	if length_squared < 1e-24 {
		return {}
	}
	return v / math.sqrt(length_squared)
}

@(private = "file")
dot3 :: proc(a, b: [3]f64) -> f64 {
	return a.x * b.x + a.y * b.y + a.z * b.z
}

@(private = "file")
widen :: proc(v: [3]f32) -> [3]f64 {
	return {f64(v.x), f64(v.y), f64(v.z)}
}

@(private = "file")
saturate3 :: proc(v: [3]f64) -> [3]f64 {
	return {clamp(v.x, 0, 1), clamp(v.y, 0, 1), clamp(v.z, 0, 1)}
}

calculate_light_reference :: proc(scene: Light_Scene, quat: [4]f32, view: [3]f32) -> Light_Result {
	n := calculate_light_normal(quat)
	v := calculate_unit(widen(view))
	diffuse := widen(scene.ambient)
	specular: [3]f64
	for slot in 0 ..< 8 {
		l := calculate_unit(widen(scene.direction[slot]))
		h := calculate_unit(l + v)
		diffuse += widen(scene.diffuse[slot]) * max(dot3(l, n), 0)
		if dot3(l, n) > 0 {
			specular += widen(scene.specular[slot]) * math.pow(max(dot3(n, h), 1e-8), f64(scene.shininess))
		}
	}
	return {saturate3(diffuse), saturate3(specular * f64(scene.specular_strength))}
}

// ---- the 3DS ----------------------------------------------------------------------------------------------------

// What citro3d stores for a colour: 255 times the value, cut to a whole number, kept in 0..255.
@(private = "file")
calculate_stored_color :: proc(v: [3]f64) -> [3]f64 {
	result: [3]f64
	for lane in 0 ..< 3 {
		result[lane] = clamp(math.floor(255 * v[lane]), 0, 255) / 255
	}
	return result
}

// D0 as LightLut_Phong fills it: entry i is x^shininess at i/256 in 12 bits, with the step to the next entry in 11
// bits and a sign, and the unit reads between entries along that step.
@(private = "file")
calculate_phong_table :: proc(x: f64, shininess: f64) -> f64 {
	index := min(int(math.floor(x * 256)), 255)
	fraction := x * 256 - f64(index)
	here := math.pow(f64(index) / 256, shininess)
	next := math.pow(f64(index + 1) / 256, shininess)
	entry := min(math.floor(here * 4096), 4095) / 4096
	step := next - here
	stored_step := min(math.floor(abs(step) * 2048), 2047) / 2048
	if step < 0 {
		stored_step = -stored_step
	}
	return entry + stored_step * fraction
}

calculate_light_3ds :: proc(scene: Light_Scene, quat: [4]f32, view: [3]f32) -> Light_Result {
	n := calculate_light_normal(quat)
	v := calculate_unit(widen(view))
	// the material the runtime sets: ambient and diffuse 1, so the scene's ambient and the lights' colours pass
	// through, and the specular strength as the material's specular0
	diffuse := calculate_stored_color(widen(scene.ambient))
	specular: [3]f64
	strength := f64(scene.specular_strength)
	for slot in 0 ..< 8 {
		l := calculate_unit(widen(scene.direction[slot]))
		h := calculate_unit(l + v)
		diffuse += calculate_stored_color(widen(scene.diffuse[slot])) * max(dot3(l, n), 0)
		if dot3(l, n) > 0 { 	// clamp highlights
			specular += calculate_stored_color(widen(scene.specular[slot]) * strength) * calculate_phong_table(abs(dot3(n, h)), f64(scene.shininess))
		}
	}
	return {calculate_stored_color(saturate3(diffuse)), calculate_stored_color(saturate3(specular))}
}

// ---- random scenes ----------------------------------------------------------------------------------------------

// A small generator of its own, so the scenes are the same on every run and every machine.
Light_Random :: struct {
	state: u64,
}

calculate_light_random :: proc(random: ^Light_Random) -> f32 {
	random.state = random.state * 6364136223846793005 + 1442695040888963407
	return f32(random.state >> 40) / f32(1 << 24)
}

@(private = "file")
calculate_random_direction :: proc(random: ^Light_Random) -> [3]f32 {
	for {
		d := [3]f32{calculate_light_random(random) * 2 - 1, calculate_light_random(random) * 2 - 1, calculate_light_random(random) * 2 - 1}
		length_squared := d.x * d.x + d.y * d.y + d.z * d.z
		if length_squared > 0.01 && length_squared <= 1 {
			return d / math.sqrt(length_squared)
		}
	}
}

/*
	create_light_case makes a scene with `lights` slots in use and the rest empty, and a pixel to light: a normal
	facing the eye side (+Z in eye space) and a view vector towards the eye, as a visible pixel has. Directions are
	left unnormalized and scaled, and the quaternion scaled, since the built-ins normalize both
*/
create_light_case :: proc(random: ^Light_Random, lights: int) -> (scene: Light_Scene, quat: [4]f32, view: [3]f32) {
	scene.ambient = {calculate_light_random(random) * 0.3, calculate_light_random(random) * 0.3, calculate_light_random(random) * 0.3}
	for slot in 0 ..< lights {
		scene.direction[slot] = calculate_random_direction(random) * (0.5 + calculate_light_random(random) * 2)
		scene.diffuse[slot] = {calculate_light_random(random), calculate_light_random(random), calculate_light_random(random)} * 0.6
		scene.specular[slot] = {calculate_light_random(random), calculate_light_random(random), calculate_light_random(random)}
	}
	scene.shininess = 1 + calculate_light_random(random) * 63
	scene.specular_strength = calculate_light_random(random)

	n := calculate_random_direction(random)
	n.z = abs(n.z)
	q := [4]f32{-n.y, n.x, 0, max(1 + n.z, 0.00001)}
	quat = q * (0.5 + calculate_light_random(random) * 2)
	// the view on the side the normal faces: a pixel seen from behind is culled before it is lit
	for {
		view = calculate_random_direction(random)
		if view.x * n.x + view.y * n.y + view.z * n.z > 0.05 {
			break
		}
	}
	view *= 1 + calculate_light_random(random) * 10
	return
}

// ---- tests ------------------------------------------------------------------------------------------------------

@(test)
the_quaternion_turns_plus_z_back_into_the_normal :: proc(t: ^testing.T) {
	random := Light_Random{state = 7}
	worst: f64
	for _ in 0 ..< 200 {
		n := calculate_random_direction(&random)
		if n.z < -0.99 {
			continue // the degenerate case is the identity on purpose (docs/shader_pica.md)
		}
		got := calculate_light_normal({-n.y, n.x, 0, max(1 + n.z, 0.00001)})
		for lane in 0 ..< 3 {
			worst = max(worst, abs(got[lane] - f64(n[lane])))
		}
	}
	testing.expectf(t, worst < 1e-6, "the normal came back off by %v", worst)
}

/*
	The 3DS's unit and the formula PC and the Vita run agree within the 8-bit steps the unit works in: each light's
	colour is stored as 8-bit and so is each result, so the stated tolerance is (lights + 1) / 255, plus 1/256 for the
	D0 table's entries, steps and reading between them
*/
@(test)
the_3ds_unit_follows_the_formula_within_its_8_bit_steps :: proc(t: ^testing.T) {
	random := Light_Random{state = 2026_11_25}
	for lights in 1 ..= 8 {
		tolerance := f64(lights + 1) / 255 + 1.0 / 256
		worst: f64
		for _ in 0 ..< 400 {
			scene, quat, view := create_light_case(&random, lights)
			want := calculate_light_reference(scene, quat, view)
			got := calculate_light_3ds(scene, quat, view)
			for lane in 0 ..< 3 {
				worst = max(worst, abs(got.diffuse[lane] - want.diffuse[lane]), abs(got.specular[lane] - want.specular[lane]))
			}
		}
		testing.expectf(t, worst <= tolerance, "%d lights: the 3DS model is %v from the formula, more than %v", lights, worst, tolerance)
		fmt.printfln("light model: %d lights, worst %.5f (allowed %.5f)", lights, worst, tolerance)
	}
}

// An empty slot adds nothing, and a light behind the surface leaves no highlight (the unit's "clamp highlights")
@(test)
empty_slots_and_lights_behind_add_nothing :: proc(t: ^testing.T) {
	scene: Light_Scene
	scene.ambient = {0.1, 0.2, 0.3}
	scene.direction[0] = {0, 0, -1} // behind a surface facing +Z
	scene.diffuse[0] = {1, 1, 1}
	scene.specular[0] = {1, 1, 1}
	scene.shininess = 8
	scene.specular_strength = 1
	quat := [4]f32{0, 0, 0, 1} // normal +Z
	view := [3]f32{0, 0, -1} // a view from behind, which would make N.H large if the gate were missing
	for result in ([2]Light_Result{calculate_light_reference(scene, quat, view), calculate_light_3ds(scene, quat, view)}) {
		testing.expectf(t, abs(result.diffuse.x - 0.1) < 0.01 && abs(result.diffuse.z - 0.3) < 0.01, "diffuse %v", result.diffuse)
		testing.expectf(t, result.specular == {0, 0, 0}, "specular %v", result.specular)
	}
}
