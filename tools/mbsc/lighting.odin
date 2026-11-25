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
	- each result clamped to [0, 1]; the diffuse's alpha is 1 and the specular's 0. The `.tev` plan combines whole
	  colours, so `diffuse * texture + specular` adds the alphas too: a highlight of alpha 1 would make every lit pixel
	  opaque and break cut-outs and blending. At 0 a highlight adds colour and leaves the texture's alpha alone (the
	  3DS gets the same from an all-zero Fresnel table in the secondary alpha, measured on hardware in G2 L4-0)

	The values arrive in the engine's lights block, filled once a frame with directions already in eye space (the
	unit's convention: the quaternion and `view` are eye space, see docs/shader_pica.md, "Fragment lighting (L0)"),
	and the material in the `render` block, once a draw. Names are fixed (`lights_*`, `<render block>_shininess`)
	because the Vita runtime finds uniforms by name.

	A light slot with nothing in it is zero colour, and a zero direction is kept zero rather than normalized into a
	NaN, so an unused slot adds exactly nothing. On the Vita the loops run every slot: 8 turns is cheap, and there is
	no count to keep in step. PC has 64 slots (decided 2026-11-25: a PC-only game is not held to the handhelds' 8), and
	64 turns for a scene with one sun would be every lit pixel paying for the most a game could set, so PC's block
	ends with `lights_count` and its loops stop there. The engine keeps the slots past the count zero as well, so a
	count that were ever too high would still add nothing.
*/

// get_max_lights is how many light slots a target has, which sizes the lights block. The 3DS's unit has 8 and the
// Vita matches it; PC has 64 (the engine's MAX_PC_LIGHTS). The engine's array size for each target must say the same
// (matchbox/light.odin), since the engine fills the block this sizes.
get_max_lights :: proc(target: Target) -> int {
	switch target {
	case .PC:
		return 64
	case .VITA:
		return 8
	case .PICA200:
		return 8
	}
	return 8
}

// LIGHT_UNIFORM_NAMES are the lights block's fields, in the order the engine fills them: the ambient colour, then
// for every slot the direction towards the light, its diffuse colour and its specular colour, each a [4]f32. PC's
// block adds `lights_count` (an int) after them (hlsl.odin).
@(rodata)
LIGHT_UNIFORM_NAMES := [?]string{"lights_ambient", "lights_direction", "lights_diffuse", "lights_specular"}

// write_light_functions writes the functions the light built-ins call. HLSL and Cg read them the same way, so both
// backends share this text; each declares the uniforms it reads in its own way first. `render_block` is the name the
// shader gave its `.RENDER` block (or the one the backend declared for it), whose material fields the specular
// reads. `loop_end` is what the loops count up to: a number, or the name of the uniform holding the count.
write_light_functions :: proc(builder: ^strings.Builder, render_block: string, loop_end: string) {
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
	fmt.sbprintfln(builder, "    for (int i = 0; i < %s; i++) {{", loop_end)
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
	fmt.sbprintfln(builder, "    for (int i = 0; i < %s; i++) {{", loop_end)
	fmt.sbprintln(builder, "        float3 l = mbs_light_unit(lights_direction[i].xyz);")
	fmt.sbprintln(builder, "        float3 h = mbs_light_unit(l + v);")
	fmt.sbprintln(builder, "        float facing = dot(l, n) > 0.0 ? 1.0 : 0.0;")
	fmt.sbprintfln(builder, "        sum += lights_specular[i].rgb * (facing * pow(max(dot(n, h), 1e-8), %s_shininess));", render_block)
	fmt.sbprintln(builder, "    }")
	fmt.sbprintfln(builder, "    return float4(saturate(sum * %s_specular_strength), 0.0);", render_block)
	fmt.sbprintln(builder, "}")
}

// calls_light_builtin says whether any procedure of the module calls `light_diffuse` or `light_specular`, which is
// what brings in the lights block. The HLSL and Cg backends notice it while they write the call; the reflection file
// is written without writing the shader, so it walks the IR instead.
calls_light_builtin :: proc(ir: ^IR_Module) -> bool {
	for info in ir.procs {
		if statements_call_light(info.body) {
			return true
		}
	}
	return false
}

@(private = "file")
statements_call_light :: proc(statements: []^IR_Stmt) -> bool {
	for statement in statements {
		switch s in statement.variant {
		case IR_Declare:
			if expression_calls_light(s.init) do return true
		case IR_Assign:
			if expression_calls_light(s.target) || expression_calls_light(s.value) do return true
		case IR_If:
			if expression_calls_light(s.condition) || statements_call_light(s.then) || statements_call_light(s.otherwise) do return true
		case IR_For:
			if expression_calls_light(s.from) || expression_calls_light(s.to) || statements_call_light(s.body) do return true
		case IR_Return:
			if expression_calls_light(s.value) do return true
		case IR_Eval:
			if expression_calls_light(s.call) do return true
		case IR_Block:
			if statements_call_light(s.body) do return true
		}
	}
	return false
}

@(private = "file")
expression_calls_light :: proc(expression: ^IR_Expr) -> bool {
	if expression == nil {
		return false
	}
	switch e in expression.variant {
	case IR_Float, IR_Int, IR_Bool, IR_Zero, IR_Var_Ref, IR_Uniform_Ref, IR_Texture_Ref:
		return false
	case IR_Unary:
		return expression_calls_light(e.operand)
	case IR_Binary:
		return expression_calls_light(e.left) || expression_calls_light(e.right)
	case IR_Swizzle:
		return expression_calls_light(e.base)
	case IR_Field:
		return expression_calls_light(e.base)
	case IR_Index:
		return expression_calls_light(e.base) || expression_calls_light(e.index)
	case IR_Convert:
		return expression_calls_light(e.operand)
	case IR_Construct:
		return any_calls_light(e.args)
	case IR_Builtin_Call:
		return e.name == "light_diffuse" || e.name == "light_specular" || any_calls_light(e.args)
	case IR_Proc_Call:
		// the callee is in ir.procs too, so its body is walked there
		return any_calls_light(e.args)
	}
	return false
}

@(private = "file")
any_calls_light :: proc(expressions: []^IR_Expr) -> bool {
	for expression in expressions {
		if expression_calls_light(expression) do return true
	}
	return false
}

/*
	write_light_reflection writes the PC lights block's `block` line, or its `value` lines, into a reflection file, so
	the engine can check its own Lights_Block against what the HLSL declares when it starts, as it does `frame` and
	`render`. The layout is HLSL's: the ambient row, then each array at one row a slot, then `lights_count` on a row
	of its own, the block rounded up to whole rows.
*/
write_light_reflection :: proc(builder: ^strings.Builder, values: bool) {
	slots := get_max_lights(.PC)
	row := 16
	array_size := slots * row
	count_offset := row + (len(LIGHT_UNIFORM_NAMES) - 1) * array_size
	if values == false {
		fmt.sbprintfln(builder, "block lights %d %d", LIGHTS_REGISTER, count_offset + row)
		return
	}
	fmt.sbprintfln(builder, "value lights ambient [4]f32 0 %d 0 0", row)
	for name, index in LIGHT_UNIFORM_NAMES[1:] {
		// the reflection names a field without the block's `lights_` in front, as frame's and render's are
		fmt.sbprintfln(builder, "value lights %s [4]f32 %d %d %d %d", strings.trim_prefix(name, "lights_"), row + index * array_size, array_size, slots, row)
	}
	fmt.sbprintfln(builder, "value lights count i32 %d 4 0 0", count_offset)
}
