package mbsc

import "core:fmt"
import "core:strings"

/*
	The light built-ins, `light_diffuse(quat, view)` and `light_specular(quat, view)`, on PC and the Vita (G2 L3,
	docs/3ds_fragment_lighting_plan.md). The 3DS writes no code for them: its fragment lighting unit does the work and
	the `.tev` plan says how it is set (tev.odin). Here they are written as functions that follow what that unit
	computes, so a scene lights the same on all three targets, within the 8-bit and table rounding the 3DS adds:

	- the normal is +Z turned by the interpolated quaternion, normalized first, as the unit renormalizes it
	- primary = the scene's ambient + each light's diffuse colour * max(L.N, 0)
	- secondary = (each light's specular colour * (N.H)^shininess, only where L.N > 0) * the part's specular strength.
	  The `L.N > 0` gate is the unit's "clamp highlights", without which a light behind a surface still leaves a
	  highlight on it. The power is the D0 table the 3DS builds with LightLut_Phong
	- each result clamped to [0, 1], alpha 1

	The values arrive in the engine's lights block, filled once a frame with directions already in eye space (the
	unit's convention: the quaternion and `view` are eye space, see docs/shader_pica.md, "Fragment lighting (L0)"),
	and the material in the `render` block, once a draw. Names are fixed (`lights_*`, `<render block>_shininess`)
	because the Vita runtime finds uniforms by name.

	A light slot with nothing in it is zero colour, so the loops always run every slot: no count to keep in step, and
	no integer uniform, which the 3DS keeps for loop counters only. A zero direction is kept zero rather than
	normalized into a NaN, so an unused slot adds exactly nothing.
*/

// get_max_lights is how many light slots a target has, which sizes the lights block. Each target answers on its own
// so one can be raised without the others once it is measured; the 3DS's unit has 8 and sets the floor. The
// engine's own array size for the target must say the same (docs/3ds_fragment_lighting_plan.md, decision 2).
get_max_lights :: proc(target: Target) -> int {
	switch target {
	case .PC:
		return 8
	case .VITA:
		return 8
	case .PICA200:
		return 8
	}
	return 8
}

// LIGHT_UNIFORM_NAMES are the lights block's fields, in the order the engine fills them: the ambient colour, then
// for every slot the direction towards the light, its diffuse colour and its specular colour, each a [4]f32.
@(rodata)
LIGHT_UNIFORM_NAMES := [?]string{"lights_ambient", "lights_direction", "lights_diffuse", "lights_specular"}

// write_light_functions writes the functions the light built-ins call. HLSL and Cg read them the same way, so both
// backends share this text; each declares the uniforms it reads in its own way first. `render_block` is the name the
// shader gave its `.RENDER` block (or the one the backend declared for it), whose material fields the specular
// reads.
write_light_functions :: proc(builder: ^strings.Builder, render_block: string, light_count: int) {
	fmt.sbprintln(builder, "\n// The light built-ins, following the 3DS's fragment lighting unit (mbsc's lighting.odin says how).")
	fmt.sbprintln(builder, "float3 mbs_light_normal(float4 q) {")
	fmt.sbprintln(builder, "    float4 u = normalize(q);")
	fmt.sbprintln(builder, "    return float3(2.0 * (u.x * u.z + u.w * u.y), 2.0 * (u.y * u.z - u.w * u.x), 1.0 - 2.0 * (u.x * u.x + u.y * u.y));")
	fmt.sbprintln(builder, "}")
	fmt.sbprintln(builder, "\nfloat3 mbs_light_unit(float3 d) {")
	fmt.sbprintln(builder, "    return d * rsqrt(max(dot(d, d), 1e-12));")
	fmt.sbprintln(builder, "}")

	fmt.sbprintln(builder, "\nfloat4 mbs_light_diffuse(float4 q, float3 view) {")
	fmt.sbprintln(builder, "    float3 n = mbs_light_normal(q);")
	fmt.sbprintln(builder, "    float3 sum = lights_ambient.rgb;")
	fmt.sbprintfln(builder, "    for (int i = 0; i < %d; i++) {{", light_count)
	fmt.sbprintln(builder, "        float3 l = mbs_light_unit(lights_direction[i].xyz);")
	fmt.sbprintln(builder, "        sum += lights_diffuse[i].rgb * max(dot(l, n), 0.0);")
	fmt.sbprintln(builder, "    }")
	fmt.sbprintln(builder, "    return float4(saturate(sum), 1.0);")
	fmt.sbprintln(builder, "}")

	// pow of exactly 0 is exp2(s * log2(0)), a NaN when the shininess is 0 too, so the base is kept just above it
	fmt.sbprintln(builder, "\nfloat4 mbs_light_specular(float4 q, float3 view) {")
	fmt.sbprintln(builder, "    float3 n = mbs_light_normal(q);")
	fmt.sbprintln(builder, "    float3 v = mbs_light_unit(view);")
	fmt.sbprintln(builder, "    float3 sum = float3(0.0, 0.0, 0.0);")
	fmt.sbprintfln(builder, "    for (int i = 0; i < %d; i++) {{", light_count)
	fmt.sbprintln(builder, "        float3 l = mbs_light_unit(lights_direction[i].xyz);")
	fmt.sbprintln(builder, "        float3 h = mbs_light_unit(l + v);")
	fmt.sbprintln(builder, "        float lit = dot(l, n) > 0.0 ? 1.0 : 0.0;")
	fmt.sbprintfln(builder, "        sum += lights_specular[i].rgb * (lit * pow(max(dot(n, h), 1e-8), %s_shininess));", render_block)
	fmt.sbprintln(builder, "    }")
	fmt.sbprintfln(builder, "    return float4(saturate(sum * %s_specular_strength), 1.0);", render_block)
	fmt.sbprintln(builder, "}")
}
