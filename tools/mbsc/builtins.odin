package mbsc

// The built-in functions (docs/shader_language.md, part 2, section 13) and what each one accepts. Which targets
// can run each one is not decided here: that is the job of the backends and `mbsc --check` (S7). This table only
// says what is a well-typed call.
//
// `T` in a signature means f32 or a float vector ([2]f32, [3]f32, [4]f32).

Builtin_Rule :: enum {
	UNARY, // (T) -> T
	BINARY_SAME, // (T, T) -> T
	BINARY_BROADCAST, // (T, T) -> T, and the second may be an f32 used for every component
	STEP, // (edge: T or f32, a: T) -> T
	CLAMP, // (T, lo, hi) -> T; lo and hi are both T or both f32
	LERP, // (T, T, t: T or f32) -> T
	SMOOTHSTEP, // (e0, e1, a: T) -> T; the edges are both T or both f32
	FLOAT_TEST, // (f32) -> bool
	DOT, // (V, V) -> f32 for float vectors
	LENGTH, // (V) -> f32
	DISTANCE, // (V, V) -> f32
	NORMALIZE, // (V) -> V
	CROSS, // ([3]f32, [3]f32) -> [3]f32
	REFLECT, // (V, V) -> V
	REFRACT, // ([3]f32, [3]f32, f32) -> [3]f32
	DOT3_SIGNED, // (V, V) -> f32 for [3]f32 or [4]f32
	NORMAL_QUATERNION, // ([3]f32) -> [4]f32
	LIGHTING, // (quat: [4]f32, view: [3]f32) -> [4]f32
	TRANSPOSE, // (matrix[R, C]f32) -> matrix[C, R]f32
	DETERMINANT, // (matrix[N, N]f32) -> f32
	SAMPLE, // (Texture2D, [2]f32) -> [4]f32
	SAMPLE_LOD, // (Texture2D, [2]f32, f32) -> [4]f32
	SAMPLE_BIAS, // (Texture2D, [2]f32, f32) -> [4]f32
	SAMPLE_GRAD, // (Texture2D, [2]f32, [2]f32, [2]f32) -> [4]f32
	DERIVATIVE, // (T) -> T
	DISCARD, // () -> nothing
}

Builtin :: struct {
	name:          string,
	rule:          Builtin_Rule,
	signature:     string, // shown in a message when a call doesn't fit
	fragment_only: bool, // a vertex stage can't use it (MBS-E26)
}

@(rodata)
BUILTINS := [?]Builtin {
	// arithmetic
	{"abs", .UNARY, "abs(a: T) -> T", false},
	{"sign", .UNARY, "sign(a: T) -> T", false},
	{"floor", .UNARY, "floor(a: T) -> T", false},
	{"ceil", .UNARY, "ceil(a: T) -> T", false},
	{"trunc", .UNARY, "trunc(a: T) -> T", false},
	{"round", .UNARY, "round(a: T) -> T", false},
	{"fract", .UNARY, "fract(a: T) -> T", false},
	{"saturate", .UNARY, "saturate(a: T) -> T", false},
	{"min", .BINARY_BROADCAST, "min(a: T, b: T or f32) -> T", false},
	{"max", .BINARY_BROADCAST, "max(a: T, b: T or f32) -> T", false},
	{"clamp", .CLAMP, "clamp(a: T, lo: T, hi: T), or with lo and hi both f32 -> T", false},
	{"fmod", .BINARY_BROADCAST, "fmod(a: T, b: T or f32) -> T", false},
	{"mod", .BINARY_BROADCAST, "mod(a: T, b: T or f32) -> T", false},
	{"step", .STEP, "step(edge: T or f32, a: T) -> T", false},
	{"lerp", .LERP, "lerp(a: T, b: T, t: T or f32) -> T", false},
	{"smoothstep", .SMOOTHSTEP, "smoothstep(e0: T, e1: T, a: T), or with e0 and e1 both f32 -> T", false},

	// powers, roots, logarithms
	{"sqrt", .UNARY, "sqrt(a: T) -> T", false},
	{"inverse_sqrt", .UNARY, "inverse_sqrt(a: T) -> T", false},
	{"exp", .UNARY, "exp(a: T) -> T", false},
	{"exp2", .UNARY, "exp2(a: T) -> T", false},
	{"ln", .UNARY, "ln(a: T) -> T", false},
	{"log2", .UNARY, "log2(a: T) -> T", false},
	{"log10", .UNARY, "log10(a: T) -> T", false},
	{"pow", .BINARY_BROADCAST, "pow(a: T, b: T or f32) -> T", false},

	// angles
	{"to_radians", .UNARY, "to_radians(a: T) -> T", false},
	{"to_degrees", .UNARY, "to_degrees(a: T) -> T", false},
	{"sin_approx", .UNARY, "sin_approx(a: T) -> T", false},
	{"cos_approx", .UNARY, "cos_approx(a: T) -> T", false},

	// extended: PC and Vita only
	{"sin", .UNARY, "sin(a: T) -> T", false},
	{"cos", .UNARY, "cos(a: T) -> T", false},
	{"tan", .UNARY, "tan(a: T) -> T", false},
	{"asin", .UNARY, "asin(a: T) -> T", false},
	{"acos", .UNARY, "acos(a: T) -> T", false},
	{"atan", .UNARY, "atan(a: T) -> T", false},
	{"atan2", .BINARY_BROADCAST, "atan2(y: T, x: T or f32) -> T", false},
	{"sinh", .UNARY, "sinh(a: T) -> T", false},
	{"cosh", .UNARY, "cosh(a: T) -> T", false},
	{"tanh", .UNARY, "tanh(a: T) -> T", false},
	{"ldexp", .BINARY_SAME, "ldexp(a: T, exponent: T) -> T", false},
	{"is_nan", .FLOAT_TEST, "is_nan(a: f32) -> bool", false},
	{"is_inf", .FLOAT_TEST, "is_inf(a: f32) -> bool", false},

	// vectors
	{"dot", .DOT, "dot(a: V, b: V) -> f32, for float vectors of the same length", false},
	{"length", .LENGTH, "length(a: V) -> f32, for a float vector", false},
	{"distance", .DISTANCE, "distance(a: V, b: V) -> f32, for float vectors of the same length", false},
	{"normalize", .NORMALIZE, "normalize(a: V) -> V, for a float vector", false},
	{"cross", .CROSS, "cross(a: [3]f32, b: [3]f32) -> [3]f32", false},
	{"reflect", .REFLECT, "reflect(i: V, n: V) -> V, for float vectors of the same length", false},
	{"refract", .REFRACT, "refract(i: [3]f32, n: [3]f32, eta: f32) -> [3]f32", false},
	{"dot3_signed", .DOT3_SIGNED, "dot3_signed(a: V, b: V) -> f32, for [3]f32 or [4]f32", true},
	// The rotation taking +Z to `n`, as (vector part, scalar): what the 3DS's fragment lighting unit reads from a
	// vertex stage's `out:"normalquat"`. `n` is expected normalised. The formula was proved on a New 3DS LL in the
	// lighting plan's L0 (docs/shader_pica.md, "Fragment lighting (L0)"); every target writes the same one
	{"normal_quaternion", .NORMAL_QUATERNION, "normal_quaternion(n: [3]f32) -> [4]f32", false},
	// The scene's lights falling on the surface whose normal `quat` holds (an `out:"normalquat"`) seen from `view`
	// (an `out:"view"`): the colour the lights give it, ambient and diffuse, and the highlight they leave, specular.
	// On the 3DS these are the fragment lighting unit's two results, FRAGMENT_PRIMARY and FRAGMENT_SECONDARY, and
	// the arguments must be those two varyings unchanged; PC and the Vita come in the lighting plan's L3
	// (docs/3ds_fragment_lighting_plan.md). Two built-ins because the language returns one value
	{"light_diffuse", .LIGHTING, "light_diffuse(quat: [4]f32, view: [3]f32) -> [4]f32", true},
	{"light_specular", .LIGHTING, "light_specular(quat: [4]f32, view: [3]f32) -> [4]f32", true},
	// PC only (call it under `when TARGET == .PC`): the scene's exposure, tonemap and fog applied to a lit colour, with
	// `view` the pixel's `out:"view"` varying so the fog can tell how far away it is. See lighting.odin
	{"light_finish", .LIGHTING, "light_finish(color: [4]f32, view: [3]f32) -> [4]f32", true},

	// matrices
	{"transpose", .TRANSPOSE, "transpose(m: matrix[R, C]f32) -> matrix[C, R]f32", false},
	{"determinant", .DETERMINANT, "determinant(m: matrix[N, N]f32) -> f32", false},

	// textures and the fragment stage
	{"sample", .SAMPLE, "sample(tex: Texture2D, uv: [2]f32) -> [4]f32", false},
	{"sample_lod", .SAMPLE_LOD, "sample_lod(tex: Texture2D, uv: [2]f32, lod: f32) -> [4]f32", false},
	{"sample_bias", .SAMPLE_BIAS, "sample_bias(tex: Texture2D, uv: [2]f32, bias: f32) -> [4]f32", true},
	{"sample_grad", .SAMPLE_GRAD, "sample_grad(tex: Texture2D, uv: [2]f32, dx: [2]f32, dy: [2]f32) -> [4]f32", true},
	{"ddx", .DERIVATIVE, "ddx(a: T) -> T", true},
	{"ddy", .DERIVATIVE, "ddy(a: T) -> T", true},
	{"fwidth", .DERIVATIVE, "fwidth(a: T) -> T", true},
	{"discard", .DISCARD, "discard()", true},
}

// Names that look like built-ins but aren't, with the reason (part 2, "Not built-ins").
Not_Builtin :: struct {
	name:   string,
	reason: string,
	help:   string,
}

@(rodata)
NOT_BUILTINS := [?]Not_Builtin {
	{"frexp", "the Vita compiler rejects it", "split the number with `floor` and `log2`"},
	{"noise", "no target accepts it", "use a texture of random values, or a hash of the position"},
	{"inverse", "no target has it", "compute the inverse on the CPU and pass it as a uniform"},
	{"rcp", "Cg has no `rcp`, so it wouldn't build for the Vita", "write `1.0 / a`; mbsc uses `rcp` on the 3DS"},
	{"sincos", "it returns two values, which the language can't express", "call `sin_approx` and `cos_approx`, or `sin` and `cos` where the target has them"},
	{"modf", "it returns two values, which the language can't express", "use `trunc(a)` for the whole part and `fract(a)` for the fraction"},
	{"isfinite", "it isn't in Odin's math and is rarely needed", "test with `is_nan` and `is_inf`"},
	{"lit", "it isn't in Odin's math and is rarely needed", "write the lighting terms out with `max` and `pow`"},
	{"clip", "it isn't in Odin's math and is rarely needed", "use `discard()`"},
	{"face_forward", "nothing in the first shaders needs it", "write `dot(n, i) < 0.0` and negate by hand"},
}

find_builtin :: proc(name: string) -> (builtin: Builtin, found: bool) {
	for candidate in BUILTINS {
		if candidate.name == name {
			return candidate, true
		}
	}
	return {}, false
}

find_not_builtin :: proc(name: string) -> (entry: Not_Builtin, found: bool) {
	for candidate in NOT_BUILTINS {
		if candidate.name == name {
			return candidate, true
		}
	}
	return {}, false
}

// builtin_result says what type a call gives, or ok = false when the arguments don't fit the signature.
builtin_result :: proc(rule: Builtin_Rule, args: []^Type) -> (result: ^Type, ok: bool) {
	count := len(args)
	switch rule {
	case .UNARY:
		if count == 1 && is_float_gen(args[0]) {
			return args[0], true
		}
	case .BINARY_SAME:
		if count == 2 && is_float_gen(args[0]) && types_equal(args[0], args[1]) {
			return args[0], true
		}
	case .BINARY_BROADCAST:
		if count == 2 && is_float_gen(args[0]) && (types_equal(args[0], args[1]) || args[1].kind == .F32) {
			return args[0], true
		}
	case .STEP:
		if count == 2 && is_float_gen(args[1]) && (types_equal(args[0], args[1]) || args[0].kind == .F32) {
			return args[1], true
		}
	case .CLAMP:
		if count == 3 && is_float_gen(args[0]) {
			same := types_equal(args[0], args[1]) && types_equal(args[0], args[2])
			scalars := args[1].kind == .F32 && args[2].kind == .F32
			if same || scalars {
				return args[0], true
			}
		}
	case .LERP:
		if count == 3 && is_float_gen(args[0]) && types_equal(args[0], args[1]) && (types_equal(args[0], args[2]) || args[2].kind == .F32) {
			return args[0], true
		}
	case .SMOOTHSTEP:
		if count == 3 && is_float_gen(args[2]) {
			same := types_equal(args[2], args[0]) && types_equal(args[2], args[1])
			scalars := args[0].kind == .F32 && args[1].kind == .F32
			if same || scalars {
				return args[2], true
			}
		}
	case .FLOAT_TEST:
		if count == 1 && args[0].kind == .F32 {
			return &TYPE_BOOL, true
		}
	case .DOT, .DISTANCE:
		if count == 2 && is_float_vector(args[0]) && types_equal(args[0], args[1]) {
			return &TYPE_F32, true
		}
	case .LENGTH:
		if count == 1 && is_float_vector(args[0]) {
			return &TYPE_F32, true
		}
	case .NORMALIZE:
		if count == 1 && is_float_vector(args[0]) {
			return args[0], true
		}
	case .CROSS:
		if count == 2 && is_float_vector(args[0]) && args[0].count == 3 && types_equal(args[0], args[1]) {
			return args[0], true
		}
	case .NORMAL_QUATERNION:
		if count == 1 && is_float_vector(args[0]) && args[0].count == 3 {
			return make_vector(&TYPE_F32, 4), true
		}
	case .LIGHTING:
		if count == 2 && is_float_vector(args[0]) && args[0].count == 4 && is_float_vector(args[1]) && args[1].count == 3 {
			return make_vector(&TYPE_F32, 4), true
		}
	case .REFLECT:
		if count == 2 && is_float_vector(args[0]) && types_equal(args[0], args[1]) {
			return args[0], true
		}
	case .REFRACT:
		if count == 3 && is_float_vector(args[0]) && args[0].count == 3 && types_equal(args[0], args[1]) && args[2].kind == .F32 {
			return args[0], true
		}
	case .DOT3_SIGNED:
		if count == 2 && is_float_vector(args[0]) && args[0].count >= 3 && types_equal(args[0], args[1]) {
			return &TYPE_F32, true
		}
	case .TRANSPOSE:
		if count == 1 && args[0].kind == .MATRIX {
			return make_matrix(args[0].cols, args[0].rows), true
		}
	case .DETERMINANT:
		if count == 1 && args[0].kind == .MATRIX && args[0].rows == args[0].cols {
			return &TYPE_F32, true
		}
	case .SAMPLE:
		if count == 2 && args[0].kind == .TEXTURE2D && is_float_vector(args[1]) && args[1].count == 2 {
			return make_vector(&TYPE_F32, 4), true
		}
	case .SAMPLE_LOD, .SAMPLE_BIAS:
		if count == 3 && args[0].kind == .TEXTURE2D && is_float_vector(args[1]) && args[1].count == 2 && args[2].kind == .F32 {
			return make_vector(&TYPE_F32, 4), true
		}
	case .SAMPLE_GRAD:
		if count == 4 && args[0].kind == .TEXTURE2D && is_float_vector(args[1]) && args[1].count == 2 && types_equal(args[1], args[2]) && types_equal(args[1], args[3]) {
			return make_vector(&TYPE_F32, 4), true
		}
	case .DERIVATIVE:
		if count == 1 && is_float_gen(args[0]) {
			return args[0], true
		}
	case .DISCARD:
		if count == 0 {
			return &TYPE_VOID, true
		}
	}
	return nil, false
}
