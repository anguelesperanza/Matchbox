package mbsc_probe

/*
	mbsc_probe: which built-ins each target's own compiler accepts
	==============================================================
	The Matchbox shader compiler (mbsc) turns one shader into HLSL (PC), Cg (Vita)
	and PICA200 assembly (3DS). Before mbsc can say "this built-in works on every
	target", somebody has to find out what each target's compiler really accepts.
	This tool does that by measurement.

	For every built-in in the table below it writes the smallest valid shader that uses
	it, once per target, and runs the target's compiler on it:

		PC       d3dcompiler (vs_5_0 or ps_5_0), the same compiler the engine uses
		Vita     Sony's psp2cgc.exe (profile sce_vp_psp2 or sce_fp_psp2)
		3DS      picasso (vertex shaders only; the fragment stage is TexEnv, not a program)

	The 3DS has no built-in functions, only instructions. So its snippet is the instruction
	sequence mbsc would emit for the built-in (a lowering), and for a built-in that has no
	instruction it is an attempt to use a made-up instruction of that name, which picasso
	must reject. Either way, a pass means "picasso assembles it". It does not prove the
	sequence computes the right number; that is what mbsc's own tests are for.

	Usage:
		odin run tools/mbsc_probe.odin -file -- [-out:report.md] [-work:dir]
			[-psp2cgc:path\to\psp2cgc.exe] [-picasso:path\to\picasso.exe]

	psp2cgc is found with -psp2cgc:, then the PSP2CGC environment variable (the one
	vito's build_shaders.py uses). Without it the Vita column is left as "not run".
	picasso is found on PATH unless -picasso: says otherwise.

	Exit code: 0 when every 3DS result matches what the capability table claims,
	1 when one does not, 2 when a tool could not be run.
*/

import "core:fmt"
import "core:os"
import "core:strings"
import "vendor:directx/d3d11"
import "vendor:directx/d3d_compiler"

Stage :: enum {
	VERTEX,
	FRAGMENT,
}

Probe :: struct {
	name:string,     // the Matchbox built-in
	group:string,
	stage:Stage,
	expr:string,     // shared HLSL/Cg: an expression giving a float4, or statements that `return` one
	hlsl:string,     // set when HLSL needs different text from `expr`
	cg:string,       // set when Cg needs different text from `expr`
	pica:string,     // the PICA200 instruction body; "" = no 3DS vertex version to test
	pica_ok:bool,    // what the capability table claims: does picasso assemble it?
	mark:string,     // the table's mark for the 3DS column: ok, =, ~ or x
	extra:string,    // more PICA text placed after the main procedure
}

Outcome :: struct {
	ran:bool,
	ok:bool,
	message:string,
}

Result :: struct {
	probe:Probe,
	pc:Outcome,
	vita:Outcome,
	pica:Outcome,
}

row :: proc(name, group:string, stage:Stage, expr:string, pica:string, pica_ok:bool, mark:string,
	hlsl := "", cg := "", extra := "") -> Probe {
	return Probe{name, group, stage, expr, hlsl, cg, pica, pica_ok, mark, extra}
}

// ---------------------------------------------------------------------------------------
// The table. Inputs a, b, c are float4. M is a float4x4, `flag` a bool, tex a 2D texture.
// PICA bodies find the inputs in r0, r1, r2 and must write the result to outpos.
// Constants available to PICA bodies: zero one half two three log2e ln2 log10_2
// rad_per_deg deg_per_rad, the uniform matrix m[0..3], the bool flag, the integer cnt.
// ---------------------------------------------------------------------------------------

build_probes :: proc() -> [dynamic]Probe {
	list:[dynamic]Probe

	// ---- Arithmetic ----
	append(&list, row("a + b", "Arithmetic", .VERTEX, "a + b", "add outpos, r0, r1", true, "ok"))
	append(&list, row("a - b", "Arithmetic", .VERTEX, "a - b", "add outpos, r0, -r1", true, "ok"))
	append(&list, row("a * b", "Arithmetic", .VERTEX, "a * b", "mul outpos, r0, r1", true, "ok"))
	append(&list, row("a / b", "Arithmetic", .VERTEX, "a / b", "rcp r3, r1\n\tmul outpos, r0, r3", true, "="))
	append(&list, row("a * b + c", "Arithmetic", .VERTEX, "a * b + c", "mad outpos, r0, r1, r2", true, "ok"))
	append(&list, row("abs", "Arithmetic", .VERTEX, "abs(a)", "max outpos, r0, -r0", true, "="))
	append(&list, row("min", "Arithmetic", .VERTEX, "min(a, b)", "min outpos, r0, r1", true, "ok"))
	append(&list, row("max", "Arithmetic", .VERTEX, "max(a, b)", "max outpos, r0, r1", true, "ok"))
	append(&list, row("clamp", "Arithmetic", .VERTEX, "clamp(a, b, c)", "max r3, r0, r1\n\tmin outpos, r3, r2", true, "="))
	append(&list, row("saturate", "Arithmetic", .VERTEX, "saturate(a)", "max r3, zero, r0\n\tmin outpos, one, r3", true, "="))
	append(&list, row("floor", "Arithmetic", .VERTEX, "floor(a)", "flr outpos, r0", true, "ok"))
	append(&list, row("ceil", "Arithmetic", .VERTEX, "ceil(a)", "mov r3, -r0\n\tflr r3, r3\n\tmov outpos, -r3", true, "="))
	append(&list, row("fract", "Arithmetic", .VERTEX, "frac(a)", "flr r3, r0\n\tadd outpos, r0, -r3", true, "="))
	append(&list, row("trunc", "Arithmetic", .VERTEX, "trunc(a)",
		"sge r3, r0, zero\n\tslt r4, r0, zero\n\tadd r3, r3, -r4\n\tmax r4, r0, -r0\n\tflr r4, r4\n\tmul outpos, r4, r3", true, "="))
	append(&list, row("round", "Arithmetic", .VERTEX, "round(a)", "add r3, half, r0\n\tflr r4, r3\n\tslt r5, r4, r3\n\tmov r6, one\n\tadd r5, r6, -r5\n\tmul r7, half, r4\n\tflr r8, r7\n\tslt r8, r8, r7\n\tmul r5, r5, r8\n\tadd outpos, r4, -r5", true, "="))
	append(&list, row("sign", "Arithmetic", .VERTEX, "sign(a)",
		"mov r3, zero\n\tslt r4, r3, r0\n\tslt r5, r0, zero\n\tadd outpos, r4, -r5", true, "="))
	append(&list, row("fmod", "Arithmetic", .VERTEX, "fmod(a, b)", "rcp r3, r1\n\tmul r3, r0, r3\n\tmax r4, r3, -r3\n\tflr r5, r4\n\tadd r4, r4, -r5\n\tmul r4, r4, r1\n\tsge r6, r3, zero\n\tadd r6, r6, r6\n\tmov r7, one\n\tadd r6, r6, -r7\n\tmul outpos, r4, r6", true, "="))
	append(&list, row("mod", "Arithmetic", .VERTEX, "a - b * floor(a / b)",
		"rcp r3, r1\n\tmul r3, r0, r3\n\tflr r3, r3\n\tmul r3, r1, r3\n\tadd outpos, r0, -r3", true, "="))
	append(&list, row("step", "Arithmetic", .VERTEX, "step(a, b)", "sge outpos, r1, r0", true, "ok"))
	append(&list, row("lerp / mix", "Arithmetic", .VERTEX, "lerp(a, b, c)", "add r3, r1, -r0\n\tmad outpos, r2, r3, r0", true, "="))
	append(&list, row("smoothstep", "Arithmetic", .VERTEX, "smoothstep(a, b, c)",
		"add r3, r2, -r0\n\tadd r4, r1, -r0\n\trcp r4, r4\n\tmul r3, r3, r4\n\tmax r3, zero, r3\n\tmin r3, one, r3\n\tmul r5, r3, r3\n\tmul r6, two, r3\n\tadd r6, three, -r6\n\tmul outpos, r5, r6",
		true, "="))
	append(&list, row("sqrt", "Arithmetic", .VERTEX, "sqrt(a)", "rsq r3, r0\n\trcp outpos, r3", true, "="))
	append(&list, row("inverse_sqrt", "Arithmetic", .VERTEX, "rsqrt(a)", "rsq outpos, r0", true, "ok"))
	append(&list, row("rcp", "Not built-ins", .VERTEX, "rcp(a)", "rcp outpos, r0", true, "ok"))
	append(&list, row("exp2", "Arithmetic", .VERTEX, "exp2(a)", "ex2 outpos, r0", true, "ok"))
	append(&list, row("log2", "Arithmetic", .VERTEX, "log2(a)", "lg2 outpos, r0", true, "ok"))
	append(&list, row("exp", "Arithmetic", .VERTEX, "exp(a)", "mul r3, log2e, r0\n\tex2 outpos, r3", true, "="))
	append(&list, row("ln", "Arithmetic", .VERTEX, "log(a)", "lg2 r3, r0\n\tmul outpos, ln2, r3", true, "="))
	append(&list, row("log10", "Arithmetic", .VERTEX, "log10(a)", "lg2 r3, r0\n\tmul outpos, log10_2, r3", true, "="))
	append(&list, row("pow", "Arithmetic", .VERTEX, "pow(a, b)", "lg2 r3, r0\n\tmul r3, r1, r3\n\tex2 outpos, r3", true, "="))
	append(&list, row("to_radians", "Arithmetic", .VERTEX, "radians(a)", "mul outpos, rad_per_deg, r0", true, "="))
	append(&list, row("to_degrees", "Arithmetic", .VERTEX, "degrees(a)", "mul outpos, deg_per_rad, r0", true, "="))

	// ---- The explicit approximations: the same polynomial on every target ----
	append(&list, row("sin_approx", "Approximations", .VERTEX, "float4 k = floor(a * 0.15915494309189535 + 0.5); float4 r = a - 6.283185307179586 * k; float4 t = r * r; float4 p = 2.1478728533851322e-06; p = p * t - 0.0001926499619928568; p = p * t + 0.008308984952537351; p = p * t - 0.16662438501484986; p = p * t + 0.9999793879828708; return r * p;", "mov r9, half\n\tmad r3, r0, inv2pi, r9\n\tflr r3, r3\n\tmad r3, r3, neg_twopi, r0\n\tmul r4, r3, r3\n\tmov r5, sin_c4\n\tmad r5, r5, r4, sin_c3\n\tmad r5, r5, r4, sin_c2\n\tmad r5, r5, r4, sin_c1\n\tmad r5, r5, r4, sin_c0\n\tmul outpos, r5, r3", true, "="))
	append(&list, row("cos_approx", "Approximations", .VERTEX, "float4 k = floor(a * 0.15915494309189535 + 0.5); float4 r = a - 6.283185307179586 * k; float4 t = r * r; float4 p = -2.1978878103077777e-07; p = p * t + 2.4204400324072683e-05; p = p * t - 0.001385891587244809; p = p * t + 0.041659822182074986; p = p * t - 0.4999942680922626; p = p * t + 0.9999992215743202; return p;", "mov r9, half\n\tmad r3, r0, inv2pi, r9\n\tflr r3, r3\n\tmad r3, r3, neg_twopi, r0\n\tmul r4, r3, r3\n\tmov r5, cos_c5\n\tmad r5, r5, r4, cos_c4\n\tmad r5, r5, r4, cos_c3\n\tmad r5, r5, r4, cos_c2\n\tmad r5, r5, r4, cos_c1\n\tmad r5, r5, r4, cos_c0\n\tmov outpos, r5", true, "="))

	// ---- Trigonometry and friends: no 3DS instruction, so the attempt must be refused ----
	append(&list, row("sin", "Trigonometry", .VERTEX, "sin(a)", "sin outpos, r0", false, "x"))
	append(&list, row("cos", "Trigonometry", .VERTEX, "cos(a)", "cos outpos, r0", false, "x"))
	append(&list, row("tan", "Trigonometry", .VERTEX, "tan(a)", "tan outpos, r0", false, "x"))
	append(&list, row("asin", "Trigonometry", .VERTEX, "asin(a)", "asin outpos, r0", false, "x"))
	append(&list, row("acos", "Trigonometry", .VERTEX, "acos(a)", "acos outpos, r0", false, "x"))
	append(&list, row("atan", "Trigonometry", .VERTEX, "atan(a)", "atan outpos, r0", false, "x"))
	append(&list, row("atan2", "Trigonometry", .VERTEX, "atan2(a, b)", "atan2 outpos, r0, r1", false, "x"))
	append(&list, row("sinh", "Trigonometry", .VERTEX, "sinh(a)", "sinh outpos, r0", false, "x"))
	append(&list, row("cosh", "Trigonometry", .VERTEX, "cosh(a)", "cosh outpos, r0", false, "x"))
	append(&list, row("tanh", "Trigonometry", .VERTEX, "tanh(a)", "tanh outpos, r0", false, "x"))
	append(&list, row("sincos", "Not built-ins", .VERTEX, "float4 s, c2; sincos(a, s, c2); return s + c2;", "sincos outpos, r0", false, "x"))

	// ---- Float inspection ----
	append(&list, row("frexp", "Not built-ins", .VERTEX, "float4 e; float4 m = frexp(a, e); return m + e;", "frexp outpos, r0", false, "x"))
	append(&list, row("ldexp", "Float inspection", .VERTEX, "ldexp(a, b)", "ldexp outpos, r0, r1", false, "x"))
	append(&list, row("modf", "Float inspection", .VERTEX, "float4 ip; float4 f = modf(a, ip); return f + ip;", "modf outpos, r0", false, "x"))
	append(&list, row("is_nan", "Float inspection", .VERTEX, "float4(isnan(a))", "isnan outpos, r0", false, "x"))
	append(&list, row("is_inf", "Float inspection", .VERTEX, "float4(isinf(a))", "isinf outpos, r0", false, "x"))
	append(&list, row("isfinite", "Not built-ins", .VERTEX, "float4(isfinite(a))", "isfinite outpos, r0", false, "x"))
	append(&list, row("noise", "Not built-ins", .VERTEX, "noise(a).xxxx", "noise outpos, r0", false, "x"))

	// ---- Vectors ----
	append(&list, row("dot (vec4)", "Vectors", .VERTEX, "dot(a, b).xxxx", "dp4 outpos, r0, r1", true, "ok"))
	append(&list, row("dot (vec3)", "Vectors", .VERTEX, "dot(a.xyz, b.xyz).xxxx", "dp3 outpos, r0, r1", true, "ok"))
	append(&list, row("dot (vec3, 1 as w)", "Vectors", .VERTEX, "dot(float4(a.xyz, 1), b).xxxx", "dph outpos, r0, r1", true, "ok"))
	append(&list, row("length", "Vectors", .VERTEX, "length(a).xxxx", "dp3 r3, r0, r0\n\trsq r3, r3\n\trcp outpos, r3", true, "="))
	append(&list, row("distance", "Vectors", .VERTEX, "distance(a, b).xxxx",
		"add r3, r0, -r1\n\tdp3 r3, r3, r3\n\trsq r3, r3\n\trcp outpos, r3", true, "="))
	append(&list, row("normalize", "Vectors", .VERTEX, "normalize(a)", "dp3 r3, r0, r0\n\trsq r3, r3\n\tmul outpos, r0, r3", true, "="))
	append(&list, row("cross", "Vectors", .VERTEX, "float4(cross(a.xyz, b.xyz), 0)",
		"mul r3, r0.zxyw, r1.yzxw\n\tmad outpos, r0.yzxw, r1.zxyw, -r3", true, "="))
	append(&list, row("reflect", "Vectors", .VERTEX, "reflect(a, b)", "dp3 r3, r1, r0\n\tadd r3, r3, r3\n\tmad outpos, -r3, r1, r0", true, "="))
	append(&list, row("faceforward", "Not built-ins", .VERTEX, "faceforward(a, b, c)",
		"dp3 r3, r2, r1\n\tslt r3, r3, zero\n\tadd r3, r3, r3\n\tmov r5, one\n\tadd r3, r3, -r5\n\tmul outpos, r3, r0", true, "="))
	append(&list, row("refract", "Vectors", .VERTEX, "float4(refract(a.xyz, b.xyz, c.x), 0)", "dp3 r3, r1, r0\n\tmul r4, r3, r3\n\tadd r4, one, -r4\n\tmul r5, r2.xxxx, r2.xxxx\n\tmul r4, r5, r4\n\tadd r4, one, -r4\n\tsge r7, r4, zero\n\tmax r4, zero, r4\n\trsq r8, r4\n\trcp r8, r8\n\tmul r9, r2.xxxx, r3\n\tadd r9, r9, r8\n\tmul r9, r9, r1\n\tmul r10, r2.xxxx, r0\n\tadd r10, r10, -r9\n\tmul outpos, r10, r7", true, "="))
	append(&list, row("lit", "Not built-ins", .VERTEX, "lit(a.x, a.y, a.z)", "litp outpos, r0", true, "ok"))

	// ---- Matrices ----
	append(&list, row("matrix * vector", "Matrices", .VERTEX, "mul(M, a)",
		"dp4 outpos.x, m[0], r0\n\tdp4 outpos.y, m[1], r0\n\tdp4 outpos.z, m[2], r0\n\tdp4 outpos.w, m[3], r0", true, "="))
	append(&list, row("vector * matrix", "Matrices", .VERTEX, "mul(a, M)",
		"dp4 outpos.x, m[0], r0\n\tdp4 outpos.y, m[1], r0\n\tdp4 outpos.z, m[2], r0\n\tdp4 outpos.w, m[3], r0", true, "="))
	append(&list, row("matrix * matrix", "Matrices", .VERTEX, "mul(M, M)[0]", "", false, "="))
	append(&list, row("transpose", "Matrices", .VERTEX, "transpose(M)[0]", "", false, "="))
	append(&list, row("determinant", "Matrices", .VERTEX, "determinant(M).xxxx", "det outpos, r0", false, "x"))
	append(&list, row("inverse", "Not built-ins", .VERTEX, "inverse(M)[0]", "inverse outpos, r0", false, "x"))

	// ---- Flow control and selection ----
	append(&list, row("select (c ? a : b)", "Flow", .VERTEX, "a.x > 0 ? b : c",
		"sge r3, r0, half\n\tadd r4, r1, -r2\n\tmad outpos, r3, r4, r2", true, "="))
	append(&list, row("if (comparison)", "Flow", .VERTEX, "if (a.x > b.x) { return b; } else { return c; }",
		"cmp r0, gt, gt, r1\n\tifc cmp.x\n\t\tmov outpos, r1\n\t.else\n\t\tmov outpos, r2\n\t.end", true, "ok"))
	append(&list, row("if (bool uniform)", "Flow", .VERTEX, "if (flag) { return b; } else { return c; }",
		"ifu flag\n\t\tmov outpos, r1\n\t.else\n\t\tmov outpos, r2\n\t.end", true, "ok"))
	append(&list, row("for (constant count)", "Flow", .VERTEX, "float4 s = float4(0, 0, 0, 0); for (int i = 0; i < 4; i++) { s += a; } return s;",
		"mov r3, zero\n\tfor cnt\n\t\tadd r3, r3, r0\n\t.end\n\tmov outpos, r3", true, "ok"))
	append(&list, row("for (computed count)", "Flow", .VERTEX, "float4 s = float4(0, 0, 0, 0); for (int i = 0; i < int(b.x); i++) { s += a; } return s;",
		"for r1\n\t\tmov outpos, r0\n\t.end", false, "x"))
	append(&list, row("while", "Flow", .VERTEX, "float4 s = a; while (s.x < b.x) { s += a; } return s;",
		"while r0\n\t\tmov outpos, r0\n\t.end", false, "x"))
	append(&list, row("procedure call", "Flow", .VERTEX, "a + b",
		"call helper\n\tmov outpos, r3", true, "ok", extra = ".proc helper\n\tadd r3, r0, r1\n.end\n"))

	// ---- Integers ----
	append(&list, row("i32 arithmetic", "Integers", .VERTEX, "float4(int(a.x) + int(b.x), 0, 0, 0)", "", false, "x"))

	// ---- Textures and fragment-only built-ins (the 3DS fragment stage is TexEnv, not tested here) ----
	append(&list, row("sample (fragment)", "Textures", .FRAGMENT, "", "", false, "",
		hlsl = "tex.Sample(smp, b.xy)", cg = "tex2D(tex, b.xy)"))
	append(&list, row("sample (vertex)", "Textures", .VERTEX, "", "tex outpos, r0", false, "x",
		hlsl = "tex.SampleLevel(smp, b.xy, 0)", cg = "tex2Dlod(tex, float4(b.xy, 0, 0))"))
	append(&list, row("sample_lod", "Textures", .FRAGMENT, "", "", false, "",
		hlsl = "tex.SampleLevel(smp, b.xy, c.x)", cg = "tex2Dlod(tex, float4(b.xy, 0, c.x))"))
	append(&list, row("sample_bias", "Textures", .FRAGMENT, "", "", false, "",
		hlsl = "tex.SampleBias(smp, b.xy, c.x)", cg = "tex2Dbias(tex, float4(b.xy, 0, c.x))"))
	append(&list, row("sample_grad", "Textures", .FRAGMENT, "", "", false, "",
		hlsl = "tex.SampleGrad(smp, b.xy, c.xy, c.zw)", cg = "tex2D(tex, b.xy, c.xy, c.zw)"))
	append(&list, row("discard", "Fragment", .FRAGMENT, "if (a.x < b.x) { discard; } return c;", "", false, ""))
	append(&list, row("clip", "Fragment", .FRAGMENT, "clip(a.x); return b;", "", false, ""))
	append(&list, row("ddx", "Fragment", .FRAGMENT, "ddx(a)", "", false, ""))
	append(&list, row("ddy", "Fragment", .FRAGMENT, "ddy(a)", "", false, ""))
	append(&list, row("fwidth", "Fragment", .FRAGMENT, "fwidth(a)", "", false, ""))

	return list
}

// ---------------------------------------------------------------------------------------
// Snippet text per target
// ---------------------------------------------------------------------------------------

// The body of the shared helper: `return EXPR;` unless the row wrote its own statements
body_of :: proc(text:string) -> string {
	if strings.contains(text, "return") do return text
	return fmt.tprintf("return %s;", text)
}

// fmt treats `{` in a format string as a verb, so the braces are written as plain text
write_body :: proc(b:^strings.Builder, header, text:string) {
	strings.write_string(b, header)
	strings.write_string(b, " { ")
	strings.write_string(b, body_of(text))
	strings.write_string(b, " }\n")
}

hlsl_source :: proc(p:Probe) -> string {
	text := p.hlsl if len(p.hlsl) > 0 else p.expr
	b := strings.builder_make(context.temp_allocator)
	fmt.sbprintln(&b, "float4x4 M;")
	fmt.sbprintln(&b, "bool flag;")
	fmt.sbprintln(&b, "Texture2D tex;")
	fmt.sbprintln(&b, "SamplerState smp;")
	write_body(&b, "float4 body(float4 a, float4 b, float4 c)", text)
	switch p.stage {
	case .VERTEX:
		fmt.sbprintln(&b, "float4 main(float4 a : POSITION, float4 b : TEXCOORD0, float4 c : TEXCOORD1) : SV_POSITION { return body(a, b, c); }")
	case .FRAGMENT:
		fmt.sbprintln(&b, "float4 main(float4 pos : SV_POSITION, float4 a : TEXCOORD0, float4 b : TEXCOORD1, float4 c : TEXCOORD2) : SV_TARGET { return body(a, b, c); }")
	}
	return strings.to_string(b)
}

cg_source :: proc(p:Probe) -> string {
	text := p.cg if len(p.cg) > 0 else p.expr
	b := strings.builder_make(context.temp_allocator)
	write_body(&b, "float4 body(float4 a, float4 b, float4 c, float4x4 M, bool flag, sampler2D tex)", text)
	switch p.stage {
	case .VERTEX:
		fmt.sbprintln(&b, "void main(float4 a : POSITION, float4 b : TEXCOORD0, float4 c : TEXCOORD1,")
		fmt.sbprintln(&b, "\tuniform float4x4 M, uniform bool flag, uniform sampler2D tex, out float4 result : POSITION)")
		fmt.sbprintln(&b, "{ result = body(a, b, c, M, flag, tex); }")
	case .FRAGMENT:
		fmt.sbprintln(&b, "float4 main(float4 a : TEXCOORD0, float4 b : TEXCOORD1, float4 c : TEXCOORD2,")
		fmt.sbprintln(&b, "\tuniform float4x4 M, uniform bool flag, uniform sampler2D tex) : COLOR")
		fmt.sbprintln(&b, "{ return body(a, b, c, M, flag, tex); }")
	}
	return strings.to_string(b)
}

PICA_HEAD :: `.fvec m[4]
.constf zero(0.0, 0.0, 0.0, 0.0)
.constf one(1.0, 1.0, 1.0, 1.0)
.constf half(0.5, 0.5, 0.5, 0.5)
.constf two(2.0, 2.0, 2.0, 2.0)
.constf three(3.0, 3.0, 3.0, 3.0)
.constf log2e(1.4426950408889634, 1.4426950408889634, 1.4426950408889634, 1.4426950408889634)
.constf ln2(0.6931471805599453, 0.6931471805599453, 0.6931471805599453, 0.6931471805599453)
.constf log10_2(0.30102999566398120, 0.30102999566398120, 0.30102999566398120, 0.30102999566398120)
.constf rad_per_deg(0.017453292519943295, 0.017453292519943295, 0.017453292519943295, 0.017453292519943295)
.constf deg_per_rad(57.29577951308232, 57.29577951308232, 57.29577951308232, 57.29577951308232)
.constf inv2pi(0.15915494309189535, 0.15915494309189535, 0.15915494309189535, 0.15915494309189535)
.constf neg_twopi(-6.283185307179586, -6.283185307179586, -6.283185307179586, -6.283185307179586)
.constf sin_c0(0.9999793879828708, 0.9999793879828708, 0.9999793879828708, 0.9999793879828708)
.constf sin_c1(-0.16662438501484986, -0.16662438501484986, -0.16662438501484986, -0.16662438501484986)
.constf sin_c2(0.008308984952537351, 0.008308984952537351, 0.008308984952537351, 0.008308984952537351)
.constf sin_c3(-0.0001926499619928568, -0.0001926499619928568, -0.0001926499619928568, -0.0001926499619928568)
.constf sin_c4(2.1478728533851322e-06, 2.1478728533851322e-06, 2.1478728533851322e-06, 2.1478728533851322e-06)
.constf cos_c0(0.9999992215743202, 0.9999992215743202, 0.9999992215743202, 0.9999992215743202)
.constf cos_c1(-0.4999942680922626, -0.4999942680922626, -0.4999942680922626, -0.4999942680922626)
.constf cos_c2(0.041659822182074986, 0.041659822182074986, 0.041659822182074986, 0.041659822182074986)
.constf cos_c3(-0.001385891587244809, -0.001385891587244809, -0.001385891587244809, -0.001385891587244809)
.constf cos_c4(2.4204400324072683e-05, 2.4204400324072683e-05, 2.4204400324072683e-05, 2.4204400324072683e-05)
.constf cos_c5(-2.1978878103077777e-07, -2.1978878103077777e-07, -2.1978878103077777e-07, -2.1978878103077777e-07)
.bool flag
.consti cnt(4, 0, 1, 0)
.out outpos position
.proc main
	mov r0, v0
	mov r1, v1
	mov r2, v2
`

pica_source :: proc(p:Probe) -> string {
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, PICA_HEAD)
	fmt.sbprintfln(&b, "\t%s", p.pica)
	strings.write_string(&b, "\tend\n.end\n")
	strings.write_string(&b, p.extra)
	return strings.to_string(b)
}

// ---------------------------------------------------------------------------------------
// Running the compilers
// ---------------------------------------------------------------------------------------

// The line to show for a result: the first one that says "error" (a compiler may print
// warnings first), otherwise the first line
first_line :: proc(text:string) -> string {
	trimmed := strings.trim_space(text)
	rest := trimmed
	for line in strings.split_lines_iterator(&rest) {
		if strings.contains(line, "error") do return strings.trim_space(line)
	}
	line, _, _ := strings.partition(trimmed, "\n")
	return strings.trim_space(line)
}

run_hlsl :: proc(source:string, stage:Stage) -> Outcome {
	target:cstring = "vs_5_0" if stage == .VERTEX else "ps_5_0"
	blob:^d3d11.IBlob
	errors:^d3d11.IBlob

	res := d3d_compiler.Compile(
		pSrcData = raw_data(source),
		SrcDataSize = uint(len(source)),
		pSourceName = "probe.hlsl",
		pDefines = nil,
		pInclude = nil,
		pEntrypoint = "main",
		pTarget = target,
		Flags1 = 0,
		Flags2 = 0,
		ppCode = &blob,
		ppErrorMsgs = &errors,
	)

	outcome := Outcome{ran = true, ok = res >= 0}
	if errors != nil {
		text := string(([^]u8)(errors->GetBufferPointer())[:errors->GetBufferSize()])
		outcome.message = strings.clone(first_line(text))
		errors->Release()
	}
	if blob != nil do blob->Release()
	return outcome
}

run_tool :: proc(command:[]string) -> Outcome {
	state, out, err, run_err := os.process_exec(os.Process_Desc{command = command}, context.allocator)
	defer delete(out)
	defer delete(err)

	if run_err != nil {
		return Outcome{ran = false, message = fmt.aprintf("could not run %s: %v", command[0], run_err)}
	}

	text := strings.concatenate({string(err), "\n", string(out)}, context.temp_allocator)
	failed := state.exit_code != 0 || strings.contains(text, "error")
	return Outcome{ran = true, ok = failed == false, message = strings.clone(first_line(text))}
}

main :: proc() {
	work := "mbsc_probe_work"
	report := ""
	psp2cgc, _ := os.lookup_env("PSP2CGC", context.allocator)
	picasso := "picasso"

	for arg in os.args[1:] {
		switch {
		case strings.has_prefix(arg, "-out:"): report = arg[len("-out:"):]
		case strings.has_prefix(arg, "-work:"): work = arg[len("-work:"):]
		case strings.has_prefix(arg, "-psp2cgc:"): psp2cgc = arg[len("-psp2cgc:"):]
		case strings.has_prefix(arg, "-picasso:"): picasso = arg[len("-picasso:"):]
		case:
			fmt.eprintfln("unknown argument %q. See the comment at the top of mbsc_probe.odin", arg)
			os.exit(2)
		}
	}

	if err := os.make_directory_all(work); err != nil {
		fmt.eprintfln("could not make %s: %v", work, err)
		os.exit(2)
	}

	// picasso must exist, or every 3DS row would "fail" for the wrong reason
	if probe := run_tool({picasso, "--version"}); probe.ran == false {
		fmt.eprintfln("picasso: %s", probe.message)
		os.exit(2)
	}

	probes := build_probes()
	results := make([dynamic]Result)
	mismatches := 0

	for p, i in probes {
		free_all(context.temp_allocator)
		r := Result{probe = p}

		stem := fmt.tprintf("%s/%02d", work, i)

		// PC
		hlsl := hlsl_source(p)
		_ = os.write_entire_file(fmt.tprintf("%s.hlsl", stem), hlsl)
		r.pc = run_hlsl(hlsl, p.stage)

		// Vita
		if len(psp2cgc) > 0 {
			cg := cg_source(p)
			cg_path := fmt.tprintf("%s%s.cg", stem, "_v" if p.stage == .VERTEX else "_f")
			_ = os.write_entire_file(cg_path, cg)
			profile := "sce_vp_psp2" if p.stage == .VERTEX else "sce_fp_psp2"
			r.vita = run_tool({psp2cgc, "-profile", profile, "-W4", "-nocolor", "-o", fmt.tprintf("%s.gxp", stem), cg_path})
		}

		// 3DS vertex
		if p.stage == .VERTEX && len(p.pica) > 0 {
			src := pica_source(p)
			pica_path := fmt.tprintf("%s.v.pica", stem)
			_ = os.write_entire_file(pica_path, src)
			r.pica = run_tool({picasso, "-o", fmt.tprintf("%s.shbin", stem), pica_path})
			if r.pica.ok != p.pica_ok do mismatches += 1
		}

		append(&results, r)
	}

	text := render_report(results[:], len(psp2cgc) > 0, mismatches)
	if len(report) > 0 {
		if err := os.write_entire_file(report, text); err != nil {
			fmt.eprintfln("could not write %s: %v", report, err)
			os.exit(2)
		}
		fmt.printfln("wrote %s (%d built-ins, %d 3DS mismatches)", report, len(results), mismatches)
	} else {
		fmt.print(text)
	}

	if mismatches > 0 do os.exit(1)
}

// ---------------------------------------------------------------------------------------
// The report
// ---------------------------------------------------------------------------------------

cell :: proc(o:Outcome, applicable := true) -> string {
	if applicable == false do return "-"
	if o.ran == false do return "not run"
	return "ok" if o.ok else "REJECTED"
}

render_report :: proc(results:[]Result, vita_ran:bool, mismatches:int) -> string {
	b := strings.builder_make()

	fmt.sbprintln(&b, "# Built-in probe results")
	fmt.sbprintln(&b, "")
	fmt.sbprintln(&b, "Made by `tools/mbsc_probe.odin`. Each cell says whether the target's own compiler accepted a")
	fmt.sbprintln(&b, "tiny shader using that built-in. `-` means the target has no such stage or version to test.")
	fmt.sbprintln(&b, "For the 3DS, `ok` means picasso assembled the lowering, and `REJECTED` on a built-in the")
	fmt.sbprintln(&b, "table marks `x` is the expected, confirmed answer.")
	fmt.sbprintln(&b, "")
	if vita_ran == false {
		fmt.sbprintln(&b, "> The Vita column was not run: pass `-psp2cgc:<path>` or set `PSP2CGC`.")
		fmt.sbprintln(&b, "")
	}
	fmt.sbprintln(&b, "| Built-in | Stage | PC (HLSL) | Vita (Cg) | 3DS vertex (picasso) | Table says (3DS) | Match |")
	fmt.sbprintln(&b, "|---|---|---|---|---|---|---|")

	for r in results {
		p := r.probe
		pica_tested := p.stage == .VERTEX && len(p.pica) > 0
		match := "-"
		if pica_tested {
			match = "yes" if r.pica.ok == p.pica_ok else "**NO**"
		}
		mark := p.mark if len(p.mark) > 0 else "-"
		fmt.sbprintfln(&b, "| `%s` | %v | %s | %s | %s | %s | %s |",
			p.name, p.stage, cell(r.pc), cell(r.vita), cell(r.pica, pica_tested), mark, match)
	}

	fmt.sbprintln(&b, "")
	fmt.sbprintln(&b, "## Messages from the compilers")
	fmt.sbprintln(&b, "")
	fmt.sbprintln(&b, "First line of each rejection, so a result can be understood without rerunning.")
	fmt.sbprintln(&b, "")
	for r in results {
		for pair in ([3]struct{target:string, o:Outcome}{{"PC", r.pc}, {"Vita", r.vita}, {"3DS", r.pica}}) {
			if pair.o.ran && pair.o.ok == false {
				fmt.sbprintfln(&b, "- `%s` on %s: %s", r.probe.name, pair.target, pair.o.message)
			}
		}
	}

	fmt.sbprintln(&b, "")
	if mismatches == 0 {
		fmt.sbprintln(&b, "Every 3DS result matches the capability table.")
	} else {
		fmt.sbprintfln(&b, "**%d 3DS result(s) do not match the capability table.** Fix the table or the lowering.", mismatches)
	}

	return strings.to_string(b)
}
