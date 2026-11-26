package mbsc

import "core:fmt"
import "core:strings"

/*
	The light built-ins, `light_diffuse(quat, view)` and `light_specular(quat, view)`, on PC and the Vita (G2 L3,
	docs/3ds_fragment_lighting_plan.md). The 3DS writes no code for them: its fragment lighting unit does the work and
	the `.tev` plan says how it is set (tev.odin). Here they are written as functions that follow what that unit
	computes, so a scene lights the same on all three targets, within the 8-bit and table rounding the 3DS adds:

	- the normal is +Z turned by the interpolated quaternion, normalized first, as the unit renormalizes it
	- primary = the scene's ambient + each light's diffuse colour * max(L.N, 0) * its fade
	- secondary = (each light's specular colour * (N.H)^shininess * its fade, only where L.N > 0) * the part's specular strength.
	  The `L.N > 0` gate is the unit's "clamp highlights", without which a light behind a surface still leaves a
	  highlight on it. The power is the D0 table the 3DS builds with LightLut_Phong
	- each result clamped to [0, 1]; the diffuse's alpha is 1 and the specular's 0. The `.tev` plan combines whole
	  colours, so `diffuse * texture + specular` adds the alphas too: a highlight of alpha 1 would make every lit pixel
	  opaque and break cut-outs and blending. At 0 a highlight adds colour and leaves the texture's alpha alone (the
	  3DS gets the same from an all-zero Fresnel table in the secondary alpha, measured on hardware in G2 L4-0)

	- a point or spot light's L is the way to its eye-space position (a sun's is its direction), and its fade is
	  1 / (1 + 0.09 d + 0.032 d^2) with d the distance in world units, times for a spot smoothstep(cos outer, cos inner,
	  cos of the angle from its axis). The curve is main's, fixed, no per-light range; the 3DS's DA and SP tables give
	  it to the level (G2 L8-0, measured on the real unit)

	The values arrive in the engine's lights block, filled once a frame with directions already in eye space (the
	unit's convention: the quaternion and `view` are eye space, see docs/shader_pica.md, "Fragment lighting (L0)"),
	and the material in the `render` block, once a draw. Names are fixed (`lights_*`, `<render block>_shininess`)
	because the Vita runtime finds uniforms by name.

	A light slot with nothing in it is zero colour, and a zero direction is kept zero rather than normalized into a
	NaN, so an unused slot adds exactly nothing. PC has 64 slots (decided 2026-11-25: a PC-only game is not held to the handhelds' 8), and
	64 turns for a scene with one sun would be every lit pixel paying for the most a game could set, so PC's block
	ends with `lights_count` and its loops stop there. The Vita's per-pixel shader is written differently for speed, see
	CG_LIGHT_FUNCTIONS: its first lit build, which ran all 8 slots twice, drew at 26 fps with one sun on the real Vita. The engine keeps the slots past the count zero as well, so a
	count that were ever too high would still add nothing.
*/

// get_max_lights is how many light slots a target has, which sizes the lights block. The 3DS's unit has 8 and the
// Vita matches it; PC has 64 (the engine's MAX_PC_LIGHTS). The engine's array size for each target must say the same
// (matchbox/light.odin), since the engine fills the block this sizes.
// get_max_joints is how many joints one skinned draw carries on a target (G6): the palette's size, and what a shader's
// JOINT_SLOT_COUNT is. The engine's limit for the target (mbi.skin_settings in matchbox/backend_*.odin) must say the
// same, since the engine fills the block this sizes. 22 on the 3DS is what its 96 float registers leave (three a joint)
// after the lit shader's own; revisit with the PC's 256 and the Vita's 64 (docs/g6_skinned_animation_plan.md)
get_max_joints :: proc(target: Target) -> int {
	switch target {
	case .PC:
		return 256
	case .VITA:
		return 64
	case .PICA200:
		return 22
	}
	return 22
}

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
// for every slot the direction (towards the light for a sun, back along the axis for a spot), its diffuse and specular
// colours, its position (w = kind: 0 directional, 1 point, 2 spot) and its cone (cos outer, cos inner, k = 1 / their difference, -outer * k), each a [4]f32. PC's
// block adds `lights_count` (an int) after them (hlsl.odin).
@(rodata)
LIGHT_UNIFORM_NAMES := [?]string{"lights_ambient", "lights_direction", "lights_diffuse", "lights_specular", "lights_position", "lights_cone"}

// write_light_basics writes the two small functions both forms of the light functions use: the normal from the
// quaternion, and a normalize that leaves a zero vector zero.
write_light_basics :: proc(builder: ^strings.Builder) {
	fmt.sbprintln(builder, "\n// The light built-ins, following the 3DS's fragment lighting unit (mbsc's lighting.odin says how).")
	fmt.sbprintln(builder, "float3 mbs_light_normal(float4 q) {")
	fmt.sbprintln(builder, "    float4 u = normalize(q);")
	fmt.sbprintln(builder, "    return float3(2.0 * (u.x * u.z + u.w * u.y), 2.0 * (u.y * u.z - u.w * u.x), 1.0 - 2.0 * (u.x * u.x + u.y * u.y));")
	fmt.sbprintln(builder, "}")
	fmt.sbprintln(builder, "\nfloat3 mbs_light_unit(float3 d) {")
	fmt.sbprintln(builder, "    return d * rsqrt(max(dot(d, d), 1e-12));")
	fmt.sbprintln(builder, "}")
}

// write_light_functions writes the functions the light built-ins call. HLSL and Cg read them the same way, so both
// backends share this text; each declares the uniforms it reads in its own way first. `render_block` is the name the
// shader gave its `.RENDER` block (or the one the backend declared for it), whose material fields the specular
// reads. `loop_end` is what the loops count up to: a number, or the name of the uniform holding the count.
write_light_functions :: proc(builder: ^strings.Builder, render_block: string, loop_end: string) {
	write_light_basics(builder)

	// One light seen from a pixel: the way to it in `l`, and how much of it arrives (the distance fade and a spot's
	// cone), 1 for a sun. `position` is the pixel in eye space, which is the view vector negated
	// Written without a branch on the kind: Vita3K's recompiled shader drew a point light on only a scatter of
	// pixels when the distance and the cone sat inside `if`s, and a lerp by 0 or 1 costs the same on a GPU that runs
	// both sides anyway. A sun gets a harmless `to` (its position row is zero) that the lerp throws away
	fmt.sbprintln(builder, "\nfloat mbs_light_sample(int i, float3 position, out float3 l) {")
	fmt.sbprintln(builder, "    float kind = lights_position[i].w;")
	fmt.sbprintln(builder, "    float is_point = step(0.5, kind);")
	fmt.sbprintln(builder, "    float is_spot = step(1.5, kind);")
	fmt.sbprintln(builder, "    float3 axis = lights_direction[i].xyz;")
	fmt.sbprintln(builder, "    float3 to = lights_position[i].xyz - position;")
	fmt.sbprintln(builder, "    float squared = max(dot(to, to), 1e-12);")
	fmt.sbprintln(builder, "    float inverse = rsqrt(squared);")
	fmt.sbprintln(builder, "    float d = squared * inverse;")
	fmt.sbprintln(builder, "    l = lerp(axis, to * inverse, is_point);")
	fmt.sbprintln(builder, "    float fade = lerp(1.0, 1.0 / (1.0 + d * (0.09 + 0.032 * d)), is_point);")
	// smoothstep(cos outer, cos inner, cos angle), written out: HLSL's is undefined for equal edges
	fmt.sbprintln(builder, "    float t = saturate(dot(l, axis) * lights_cone[i].z + lights_cone[i].w);")
	fmt.sbprintln(builder, "    return fade * lerp(1.0, t * t * (3.0 - 2.0 * t), is_spot);")
	fmt.sbprintln(builder, "}")

	fmt.sbprintln(builder, "\nfloat4 mbs_light_diffuse(float4 q, float3 view) {")
	fmt.sbprintln(builder, "    float3 n = mbs_light_normal(q);")
	fmt.sbprintln(builder, "    float3 sum = lights_ambient.rgb;")
	fmt.sbprintfln(builder, "    int total = (int)(%s);", loop_end)
	fmt.sbprintln(builder, "    for (int i = 0; i < total; i++) {")
	fmt.sbprintln(builder, "        float3 l;")
	fmt.sbprintln(builder, "        float fade = mbs_light_sample(i, -view, l);")
	fmt.sbprintln(builder, "        sum += lights_diffuse[i].rgb * (max(dot(l, n), 0.0) * fade);")
	fmt.sbprintln(builder, "    }")
	fmt.sbprintln(builder, "    return float4(saturate(sum), 1.0);")
	fmt.sbprintln(builder, "}")

	// pow of exactly 0 is exp2(s * log2(0)), a NaN when the shininess is 0 too, so the base is kept just above it
	fmt.sbprintln(builder, "\nfloat4 mbs_light_specular(float4 q, float3 view) {")
	fmt.sbprintln(builder, "    float3 n = mbs_light_normal(q);")
	fmt.sbprintln(builder, "    float3 v = mbs_light_unit(view);")
	fmt.sbprintln(builder, "    float3 sum = float3(0.0, 0.0, 0.0);")
	fmt.sbprintfln(builder, "    int total = (int)(%s);", loop_end)
	fmt.sbprintln(builder, "    for (int i = 0; i < total; i++) {")
	fmt.sbprintln(builder, "        float3 l;")
	fmt.sbprintln(builder, "        float fade = mbs_light_sample(i, -view, l);")
	fmt.sbprintln(builder, "        float3 h = mbs_light_unit(l + v);")
	fmt.sbprintln(builder, "        float facing = dot(l, n) > 0.0 ? 1.0 : 0.0;")
	fmt.sbprintfln(builder, "        sum += lights_specular[i].rgb * (facing * fade * pow(max(dot(n, h), 1e-8), %s_shininess));", render_block)
	fmt.sbprintln(builder, "    }")
	fmt.sbprintfln(builder, "    return float4(saturate(sum * %s_specular_strength), 0.0);", render_block)
	fmt.sbprintln(builder, "}")
}

// CG_LIGHT_FUNCTIONS is the Vita's form of the light functions (the HLSL's are write_light_functions), made for what
// the Vita's fragment unit is bound by: a lit pixel measured 26 fps with one sun and 11 with two more lights on the real
// console, against 60 per vertex. Four things differ from the HLSL's, none of them in what a pixel comes out as:
//  - one pass, not two. light_diffuse and light_specular both run `mbs_light_all`, which keeps its results in statics
//    and works once; the second call finds them done (psp2cgc sees the flag is set and drops the test, so the program
//    is as long as one pass). The cost is that both calls must pass the same arguments, which mbsc checks;
//  - the lights arrive sorted by kind (suns, then points, then spots; matchbox/light.odin does it for the Vita), with
//    `lights_split` holding where each run ends and the total, so a sun is a direction and nothing else and a point
//    has no cone;
//  - the loops run the engine's counts, so a scene with one sun runs one turn;
//  - the highlight is skipped for a part whose specular strength is 0 (a pixel gets the same black, for a whole third of
//    the program: measured on the Vita, a floor with strength 0 ran 31 fps against 24 with the bulbs on), and N.H is
//    worked from the half vector without normalising it first, which is the same number in fewer instructions.
// `@RENDER@` is the render block's name.
CG_LIGHT_FUNCTIONS :: `
static float3 mbs_light_diffuse_sum;
static float3 mbs_light_specular_sum;
static float mbs_light_done = 0.0;

// One light's share, given the way to it and how much of it arrives.
void mbs_light_add(int i, float3 l, float fade, float3 n, float3 v) {
    float facing = dot(l, n);
    mbs_light_diffuse_sum += lights_diffuse[i].rgb * (max(facing, 0.0) * fade);
    if (@RENDER@_specular_strength > 0.0) {
        float3 hu = l + v;
        float nh = dot(n, hu) * rsqrt(max(dot(hu, hu), 1e-12));
        mbs_light_specular_sum += lights_specular[i].rgb * ((facing > 0.0 ? 1.0 : 0.0) * fade * pow(max(nh, 1e-8), @RENDER@_shininess));
    }
}

// The distance fade of a bulb at distance d: 1 / (1 + 0.09 d + 0.032 d d).
float mbs_light_fade(float d) {
    return 1.0 / (1.0 + d * (0.09 + 0.032 * d));
}

void mbs_light_all(float4 q, float3 view) {
    if (mbs_light_done == 0.0) {
        float3 n = mbs_light_normal(q);
        float3 v = mbs_light_unit(view);
        float3 position = -view;
        mbs_light_diffuse_sum = lights_ambient.rgb;
        mbs_light_specular_sum = float3(0.0, 0.0, 0.0);
        int suns = (int)(lights_split.x);
        int points = (int)(lights_split.y);
        int total = (int)(lights_split.z);
        for (int i = 0; i < suns; i++) {
            mbs_light_add(i, lights_direction[i].xyz, 1.0, n, v);
        }
        for (int i = suns; i < points; i++) {
            float3 to = lights_position[i].xyz - position;
            float squared = max(dot(to, to), 1e-12);
            float inverse = rsqrt(squared);
            mbs_light_add(i, to * inverse, mbs_light_fade(squared * inverse), n, v);
        }
        for (int i = points; i < total; i++) {
            float3 to = lights_position[i].xyz - position;
            float squared = max(dot(to, to), 1e-12);
            float inverse = rsqrt(squared);
            float3 l = to * inverse;
            // smoothstep(cos outer, cos inner, cos angle), written out: Cg's is undefined for equal edges
            float t = saturate(dot(l, lights_direction[i].xyz) * lights_cone[i].z + lights_cone[i].w);
            mbs_light_add(i, l, mbs_light_fade(squared * inverse) * (t * t * (3.0 - 2.0 * t)), n, v);
        }
        mbs_light_diffuse_sum = saturate(mbs_light_diffuse_sum);
        mbs_light_specular_sum = saturate(mbs_light_specular_sum * @RENDER@_specular_strength);
        mbs_light_done = 1.0;
    }
}

float4 mbs_light_diffuse(float4 q, float3 view) {
    mbs_light_all(q, view);
    return float4(mbs_light_diffuse_sum, 1.0);
}

float4 mbs_light_specular(float4 q, float3 view) {
    mbs_light_all(q, view);
    return float4(mbs_light_specular_sum, 0.0);
}
`

// write_light_functions_cg writes the Vita's light functions (CG_LIGHT_FUNCTIONS); `render_block` is as in write_light_functions.
write_light_functions_cg :: proc(builder: ^strings.Builder, render_block: string) {
	write_light_basics(builder)
	text, _ := strings.replace_all(CG_LIGHT_FUNCTIONS, "@RENDER@", render_block, context.temp_allocator)
	fmt.sbprint(builder, text)
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

// declares_lights says whether the shader declares the lights block itself (`@(uniform = .LIGHTS) lights`, G2 L5).
declares_lights :: proc(ir: ^IR_Module) -> bool {
	for uniform in ir.uniforms {
		if uniform.kind == .LIGHTS do return true
	}
	return false
}
