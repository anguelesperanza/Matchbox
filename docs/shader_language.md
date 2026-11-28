# The Matchbox shader language

**Status: draft, all three parts written, part 3 awaiting approval.** Part 1 is the language, part 2 the built-in functions, part 3 the 3DS fragment stage.
Errors are listed in [shader_errors.md](shader_errors.md) as `MBS-E<n>`. What each target can do is measured in
[shader_capabilities.md](shader_capabilities.md).

## 1. What this is

A shader is one file, `name.mbs`, in `matchbox/shaders/`. It is written in a subset of Odin and compiled by
**mbsc**, the Matchbox Shader Compiler, once per target:

| Target | Name in `when` | mbsc produces | Then |
|---|---|---|---|
| PC | `.PC` | HLSL | compiled at startup by `d3dcompiler` |
| Vita | `.VITA` | Cg (`name_v.cg`, `name_f.cg`) | vito turns Cg into `.gxp` (not mbsc's job) |
| 3DS | `.PICA200` | PICA assembly for the vertex stage, a TexEnv table for the fragment stage | `picasso` makes the `.shbin` |

One rule runs through everything: **mbsc never quietly swaps one operation for another.** If a target can't do
something, the build for that target fails with an `MBS-E` error that says why and offers a fix. The other
targets still build. Where shading languages already agree on how something behaves (how `round` treats halves, what
happens outside a function's domain), Matchbox keeps that behaviour and makes every target match it.

## 2. The Odin subset

Because it is Odin syntax, `.mbs` files get Odin syntax highlighting and an Odin parser reads them
(`core:odin/parser`). Only this part of Odin is a shader:

**Allowed**

- Declarations: `name :: value` (constant), `name: type`, `name := value`, `name: type = value`.
- Procedures: `name :: proc(a: f32, b: [2]f32) -> [4]f32 { ... }`, with one return value.
- Structs, with field tags.
- Statements: `if` / `else`, `for` over a range, `return`, assignment, and `when`.
- Operators: `+ - * /`, comparisons, `&&`, `||`, `!`, unary `-`, and `*` for matrix times vector or matrix.
- Swizzles: `.x .y .z .w` and `.r .g .b .a`, in any order and repeated: `v.zyx`, `v.xxxx`.
- Casts between numeric types, written as calls: `f32(i)`, `i32(x)`.

**Not allowed** (each is `MBS-E16`, "Odin feature not available in shaders")

- Pointers, slices, strings, maps, dynamic arrays, `new`, `make`, `delete`.
- Single elements of a matrix (`m[0, 1]`): a matrix is used whole, with `*`, `transpose` and `determinant`.
- `union`, `enum` values used as data, `bit_set`, `any`, `typeid`.
- `defer`, `switch`, `goto`, labels, `using`, `context`.
- `import` and `foreign`. A shader is one file.
- Recursion, direct or through other procedures (`MBS-E17`).

`switch` is left out because the PICA200 has no jump table and the other two targets can use `if` chains. It may come
back later.

## 3. Types

| Type | Meaning | Where it can be used |
|---|---|---|
| `bool` | true or false | everywhere; on the 3DS only as a uniform or the result of a comparison |
| `f32` | 32-bit float | everywhere (24-bit on the 3DS) |
| `i32`, `u32` | integer | PC and Vita fully. 3DS: loop counters and array indexes only (`MBS-E9`) |
| `[2]f32`, `[3]f32`, `[4]f32` | float vectors | everywhere |
| `[2]i32`, `[3]i32`, `[4]i32` | integer vectors | as `i32`; 3DS only for a loop uniform |
| `matrix[2, 2]f32` ... `matrix[4, 4]f32` | float matrices | everywhere; each row takes one uniform register on the 3DS |
| `Texture2D` | a 2D texture | `@(texture = N)` declarations only |
| fixed arrays `[N]T` | N elements, N a constant | uniforms and locals; 3DS: constant or loop-counter index (`MBS-E10`) |
| structs | named groups of the above | everywhere |

Notes:

- There is no `f16`, `f64`, `i8` to `i64` or `u8` to `u64` yet. They can be added when a target needs them.
- There is **no implicit conversion.** `x + 1` is an error if `x` is `f32` and the literal is read as an integer.
  Write `x + 1.0`. A literal with a dot is `f32`; without one it is an integer. (`MBS-E13` shows the fix.)
- Vector arithmetic is per component. `a * b` multiplies component by component for two vectors, and scales for
  a scalar. A matrix times a vector, or a matrix times a matrix, is `*` too.
- Matrices are written the way Odin writes them. mbsc picks the multiplication order each backend needs (HLSL
  `mul(M, v)`, Cg `mul(v, M)`, PICA `dp4` per row), so the shader never says which.

## 4. Entry points

A shader defines two procedures with fixed names:

```odin
vertex_main   :: proc(input: Vertex_In) -> Varying { ... }
fragment_main :: proc(v: Varying) -> [4]f32 { ... }
```

A missing or wrongly shaped entry point is `MBS-E15`. The parameter can't be called `in`: that is an Odin keyword, so a
shader that used it would not parse. This guide uses `input` and `output`.

### Vertex input

A struct of fields, each tagged with the attribute it reads. The tag text matches the engine's vertex layout:

```odin
Vertex_In :: struct {
	position: [3]f32 `attr:"position"`,
	uv:       [2]f32 `attr:"texcoord"`,
	color:    [4]f32 `attr:"color"`,
}
```

The engine's mesh format today is exactly these three. More (`normal`, `tangent`, `bone_index`) are added with the
3D work (Phase G) and get their own tags then.

### Varyings

The struct the vertex stage returns and the fragment stage receives:

```odin
Varying :: struct {
	position: [4]f32 `out:"position"`, // required: the clip-space position
	uv:       [2]f32 `out:"texcoord0"`,
	color:    [4]f32 `out:"color"`,
}
```

- `out:"position"` is required exactly once (`MBS-E15` if missing).
- A field without an `out:` tag is allowed on PC and Vita, where the compiler picks a register. **On the 3DS it
  has nowhere to go:** the fragment stage can read only colour and texcoords (`MBS-E6`). Tag fields as
  `texcoord0`, `texcoord1`, `texcoord2` or `color` to keep a shader portable.
- Tag names a target can carry: `position`, `color`, `texcoord0`, `texcoord1`, `texcoord2`. The 3DS adds
  `normalquat` and `view` for its lighting unit; those are in part 3, section 21. Every target accepts them (on PC
  and the Vita they are ordinary varyings), and they must be `[4]f32` and `[3]f32` (`MBS-E15`): `normalquat` is
  what `normal_quaternion` makes, `view` the eye-space position negated.
- The vertex input's `attr:` names are `position`, `texcoord`, `color` and `normal` (`normal` since 2026-11-24, for
  lighting; the engine's own vertex gains it in G2).
- `texcoord0` is two components on the 3DS (a third, for cube textures, is `texcoord0w`). The other targets can
  carry up to four.

### Fragment output

`fragment_main` returns one `[4]f32`: the colour written to the screen, red green blue alpha. There is one render
target. Blending and the depth test are not part of the shader; the game's render state sets them.

## 5. Uniforms and textures

A **uniform** is a value that is the same for every vertex and pixel of one draw.

### Engine-owned uniforms

The engine fills these. A shader declares them with exactly this shape so every shader and every target agrees:

```odin
@(uniform = .FRAME) frame: struct {
	view_projection: matrix[4, 4]f32,
	time:            f32, // seconds since the game started
	view:            matrix[4, 4]f32, // the camera's view alone: eye space, where lighting is worked out
}

@(uniform = .RENDER) render: struct {
	model:        matrix[4, 4]f32,
	tint:         [4]f32,
	uv_rectangle: [4]f32, // sub-rectangle of the texture: left, top, right, bottom
	alpha_cutoff: f32,
	shininess:         f32, // the part's material, which light_specular reads (G2 L3)
	specular_strength: f32,
}
```

A shader may declare any subset of the fields, in any order. A field name the engine doesn't have is `MBS-E18`.
The engine's current `Frame_Constants` and `Render_Constants` (in `render_windows.odin`) are the reference; `time`
is new and comes with S3.

The scene's lights are a third block (G2 L5), filled by `set_lights` and `set_lighting` once per camera:

```odin
@(uniform = .LIGHTS) lights: struct {
	ambient:   [4]f32,                   // the light every surface gets
	direction: [LIGHT_SLOT_COUNT][4]f32, // towards each light, in eye space (multiply by frame.view to get there)
	diffuse:   [LIGHT_SLOT_COUNT][4]f32,
	specular:  [LIGHT_SLOT_COUNT][4]f32,
}
```

- **`LIGHT_SLOT_COUNT`** is a constant every shader has: the target's number of light slots, 8 on the 3DS and the
  Vita and 64 on PC. Size the arrays with it and loop to it (`for i in 0 ..< LIGHT_SLOT_COUNT`), and one shader is
  right on every target. An empty slot is all zeros, so it adds nothing to a sum.
- The block **must be named `lights`** (`MBS-E13` otherwise): the light built-ins and the runtimes find its fields
  as `lights_ambient`, `lights_direction`, ...
- It is the block `light_diffuse` and `light_specular` read, so a shader may declare it and call them too.
- It can be read in either stage. Per-vertex lighting reads it in the vertex stage, where the 3DS unrolls the loop
  (an index there must be a constant or a loop counter, `MBS-E10`).

A skinned draw's joints are a fourth engine block (G6), `skin`, filled by the engine from the frame's joint arena:

```odin
@(uniform = .SKIN) skin: struct {
	row0: [JOINT_SLOT_COUNT][4]f32, // the first row of every joint's skin matrix (the last row is always 0 0 0 1)
	row1: [JOINT_SLOT_COUNT][4]f32,
	row2: [JOINT_SLOT_COUNT][4]f32,
}
```

- **`JOINT_SLOT_COUNT`** is the target's most joints per draw: 256 on PC, 64 on the Vita, 22 on the 3DS
  (`mbi.skin_settings.joint_limit`; provisional, see `docs/g6_skinned_animation_plan.md`). A shader built for one limit is refused by an
  engine with another.
- The vertex input gains the attributes **`joints`** and **`weights`**, `[4]f32` each, which only a skinned mesh has. The 3DS and the
  Vita read `joints` as the numbers 0..255, the PC as 0..1 (scale by 255 under `when TARGET == .PC`); `weights` are 0..1 on the PC
  and the Vita and 0..255 on the 3DS (scale by 1/255 under `when TARGET == .PICA200`). `mesh_skinned_lit.mbs` is the model.
- **Indexing with a joint.** `skin.row0[i32(input.joints[k])]` is allowed on the 3DS, where an index otherwise has to be a constant or a
  loop counter (`MBS-E10`): the cast must be written inline in the index, and mbsc reads the register through the vertex unit's
  address register (`mova a0.x`). One such read per instruction operand; the generated program reads each row array into a temporary.

### Game-owned uniforms

A uniform the game sets by name:

```odin
@(uniform) flash: f32            // game: set_shader_value("flash", 0.5)
@(uniform) palette: [8][4]f32    // an array of 8 colours
```

`set_shader_value(name, value)` takes the uniform's name and a value of its type (`0.5` for an `f32`, a `[3]f32` for
a `[3]f32`, a slice with every element for an array); a field of a struct is named `"key_light.strength"`. The
value stays until it is set again. Where each uniform sits in its buffer is in the reflection file
(`docs/shader_reflection.md`). Today the engine has one shader, so there is no shader argument; it comes with
custom shaders.

- Types: `f32`, vectors, matrices, `bool`, and fixed arrays of those. A struct is allowed and is flattened.
- `i32` uniforms are allowed on PC and Vita. On the 3DS an `i32` uniform is an integer register, used only as a
  loop count (`MBS-E7`, `MBS-E9`).
- The 3DS has **96 float registers in all**, shared with the engine's own. A `[4]f32` takes one, a
  `matrix[4, 4]f32` takes four. mbsc reports the total when it is exceeded (`MBS-E4`).
- Uniforms are read-only inside a shader.

### Textures

```odin
@(texture = 0) albedo: Texture2D
```

- `N` is a slot. PC and Vita have many; the 3DS has **three** (slots 0 to 2).
- Sampling filter and wrap mode are set on the texture by the game (`load_texture`), not in the shader.
- `sample(albedo, uv)` reads it. The 3DS fragment stage can use a texture only as a combiner input (part 3), and
  its vertex stage can't sample at all (`MBS-E8`).

## 6. Different code for different targets

```odin
pulse :: proc(time: f32) -> f32 {
	when TARGET == .PICA200 {
		return 1.0
	} else {
		return 0.75 + 0.25 * sin_approx(time * 8.0)
	}
}
```

- `TARGET` is a constant of type `Target`, with values `.PC`, `.VITA`, `.PICA200`. It is known when mbsc runs, so
  only the chosen branch is compiled and checked.
- `when` can wrap statements and declarations. `when TARGET != .PICA200` works too.
- This is how a shader gives the 3DS its own version when a feature isn't there. An error's `help` line often
  suggests it.
- There is no `when` for the stage; the two entry points already separate them.

## 7. Procedures and control flow

- **Helper procedures** are allowed. mbsc inlines them, so they cost nothing at run time and have no call overhead,
  but they can't recurse (`MBS-E17`).
- `if` / `else` on a `bool`. A condition built from two comparisons joined with `&&` or `||` is the most the 3DS
  can hold (`MBS-E11`). A condition is a real branch on PC and Vita.
- `for i in 0..<N` with `N` a constant, or an integer uniform on the 3DS (`MBS-E7`). There is no `while`.
- `return` ends the procedure. A procedure with a result returns on every path.
- `discard()` in the fragment stage throws the pixel away. On the 3DS it must be `if color.a < constant_or_uniform`,
  which becomes the alpha test (`MBS-E12`, part 3).

## 8. A complete shader

The engine's sprite and mesh shader, `mesh.hlsl` today, in the language:

```odin
Vertex_In :: struct {
	position: [3]f32 `attr:"position"`,
	uv:       [2]f32 `attr:"texcoord"`,
	color:    [4]f32 `attr:"color"`,
}

Varying :: struct {
	position: [4]f32 `out:"position"`,
	uv:       [2]f32 `out:"texcoord0"`,
	color:    [4]f32 `out:"color"`,
}

@(uniform = .FRAME) frame: struct { view_projection: matrix[4, 4]f32 }
@(uniform = .RENDER)  render:  struct {
	model:        matrix[4, 4]f32,
	tint:         [4]f32,
	uv_rectangle: [4]f32,
	alpha_cutoff: f32,
}

@(texture = 0) tex: Texture2D

vertex_main :: proc(input: Vertex_In) -> Varying {
	output: Varying

	world := render.model * [4]f32{input.position.x, input.position.y, input.position.z, 1.0}
	output.position = frame.view_projection * world
	output.color = input.color * render.tint
	output.uv = lerp(render.uv_rectangle.xy, render.uv_rectangle.zw, input.uv)
	return output
}

fragment_main :: proc(v: Varying) -> [4]f32 {
	color := sample(tex, v.uv) * v.color
	if color.a < render.alpha_cutoff do discard()
	return color
}
```

This one file builds for all three targets. On the 3DS the vertex stage becomes about a dozen PICA instructions, the
`sample` and the multiply become one TexEnv stage, and `discard()` becomes the alpha test. `lerp` is the same name Odin, HLSL and Cg use, so it needs no renaming
on any target.

## 9. Errors from this part

| Code | When |
|---|---|
| `MBS-E13` | a type mismatch, including an integer literal where a float belongs |
| `MBS-E14` | a name that isn't declared |
| `MBS-E15` | a missing or wrong entry point, or a missing `position` output |
| `MBS-E16` | an Odin feature outside the shader subset (pointer, `switch`, `defer`, ...) |
| `MBS-E17` | recursion |
| `MBS-E18` | an engine uniform field that doesn't exist |
| `MBS-E22` | the file isn't valid Odin (a syntax error) |
| `MBS-E23` | a `when` condition that isn't a test of `TARGET` |
| `MBS-E24` | an unknown or misplaced attribute or tag |
| `MBS-E25` | a name, an engine block, a texture slot or an output declared twice |
| `MBS-E26` | a fragment-only built-in used in the vertex stage |
| `MBS-E27` | an assignment to a parameter, uniform, texture, constant or call result |
| `MBS-E28` | something HLSL can't express: an array result, an array literal passed on, a sampling helper used by both stages, a struct uniform written inline |
| `MBS-E1`, `E4`, `E6`, `E7`, `E8`, `E9`, `E10`, `E11`, `E12`, `E19`, `E20` | target limits, see their entries. Found by `mbsc` for the target being built (`mbsc --check` with no `-target:` checks all three and says what compiles where) |
| `MBS-E2` (built-ins), `E3`, `E5`, `E21` | the 3DS fragment stage and its registers. `E2` is reported for a built-in that isn't a combiner operation; the rest (combiner stage count, registers, constants) wait for the backends of S5 and S6 |

## Decided for this part

- `discard()` is a call, because Odin has no `discard` keyword and a call parses as ordinary Odin.
- `switch` is not in the subset.
- Structs are allowed as uniforms and are flattened.
- Linear interpolation is called `lerp`, the name Odin, HLSL and Cg all use.

---

# Part 2: built-in functions

Every mark in this part comes from a probe, not from a manual: `tools/mbsc_probe.odin` compiled a tiny shader per
built-in with `d3dcompiler` (PC), `psp2cgc` (Vita) and `picasso` (3DS). The last run was 87 probes with no 3DS
mismatch. A pass means the target's compiler accepted the code; whether a lowering computes the right number is
tested by mbsc itself (S2 onwards), and the 3DS ones are checked on the New 3DS LL (S5).

## 10. Names

A built-in uses **Odin's name** where `core:math` or `core:math/linalg` has one, so the shader reads like the Odin
you write elsewhere. HLSL names that Odin doesn't use are not used here:

| Matchbox | HLSL / Cg call it |
|---|---|
| `fract` | `frac` |
| `inverse_sqrt` | `rsqrt` |
| `ln` (natural log) | `log` |
| `to_radians`, `to_degrees` | `radians`, `degrees` |
| `is_nan`, `is_inf` | `isnan`, `isinf` |
| `lerp`, `fmod`, `round`, `pow` | the same name |
| `mod` | not in HLSL. It is Odin's `linalg.mod`, and `fmod` is HLSL's remainder (the table says how they differ) |

Built-ins work **per component** on a scalar or a vector (`[2]f32`, `[3]f32`, `[4]f32`) unless the table says
otherwise. `T` below means `f32` or a float vector.

### The rule behind the names and the results

Where shading languages already agree on how something behaves, Matchbox keeps that behaviour and makes every target do the
same. That covers how `round` treats halves, what `fmod` returns for negative numbers, and what happens outside a function's
domain. mbsc doesn't invent its own rule for these. What mbsc never does is quietly **swap one operation for another** (a
`sin` that is really a polynomial): that is an error, and `sin_approx` is the built-in that says what it is.

## 11. How to read the marks

| Mark | Meaning |
|---|---|
| `ok` | the target has this directly |
| `=N` | exact on the 3DS, made from `N` instructions in a row (a 4-wide vector costs the same as a scalar) |
| `x` | not available on the 3DS. mbsc stops with `MBS-E1` for that target and the message says what to do instead (section 14) |

On PC and Vita every built-in below is `ok` unless the Vita column says otherwise.

## 12. Results outside a function's domain

`sqrt` of a negative, `ln` or `log2` of zero or less, `pow` with a base of zero or less, `inverse_sqrt` of zero or less,
dividing by zero, `normalize` of a zero vector and `mod` by zero are **unspecified**: each target may return a different
number or NaN. mbsc can't check them, because the values aren't known when it runs. It reports a constant argument that
is already outside the domain (`MBS-W1`, planned). A shader should keep these out of the range, as it would on a GPU anyway.

## 13. The built-ins

### Arithmetic

| Built-in | Meaning | 3DS |
|---|---|---|
| `a + b`, `a - b`, `a * b` | per component | ok (1 each) |
| `a / b` | divide | =2 (`rcp`, `mul`) |
| `a * b + c` | multiply-add | ok (1, `mad`) |
| `abs(a)` | absolute value | =1 |
| `min(a, b)`, `max(a, b)` | smaller, larger | ok |
| `clamp(a, lo, hi)` | limit to a range | =2 |
| `saturate(a)` | clamp to 0..1 | =2 |
| `floor(a)` | round down | ok |
| `ceil(a)` | round up | =3 |
| `trunc(a)` | round toward zero | =6 |
| `round(a)` | nearest whole number; a half goes to the even neighbour (2.5 gives 2, 3.5 gives 4), which is HLSL's rule (`round_ne`) | =10 |
| `fract(a)` | `a - floor(a)` | =2 |
| `sign(a)` | -1, 0 or 1 | =3 |
| `fmod(a, b)` | HLSL's remainder: the sign of `a / b`, times `fract(abs(a / b))`, times `b`. The result has the sign of `a` | =11 |
| `mod(a, b)` | Odin's `linalg.mod`: `a - b * floor(a / b)`. The result has the sign of `b`. Use it for wrapping a value into a range | =5 |
| `step(edge, a)` | 0 where `a < edge`, otherwise 1 | ok |
| `lerp(a, b, t)` | `a + t * (b - a)` | =2 |
| `smoothstep(e0, e1, a)` | smooth 0 to 1 between the edges | =10 |

### Powers, roots and logarithms

| Built-in | Meaning | 3DS |
|---|---|---|
| `sqrt(a)` | square root | =2 (`rsq`, `rcp`); `sqrt(0)` needs a hardware check (S5) |
| `inverse_sqrt(a)` | `1 / sqrt(a)` | ok (1, `rsq`) |
| `exp2(a)` | `2` to the power `a` | ok (1, `ex2`) |
| `log2(a)` | base-2 logarithm | ok (1, `lg2`) |
| `exp(a)` | `e` to the power `a` | =2 |
| `ln(a)` | natural logarithm | =2 |
| `log10(a)` | base-10 logarithm | =2 |
| `pow(a, b)` | `a` to the power `b`, for `a > 0` | =3 (`ex2(b * lg2(a))`) |

`rcp` is not a Matchbox built-in. The 3DS has the instruction, but Cg doesn't, so it would not build for the Vita. Write
`1.0 / a`; mbsc turns that into `rcp` on the 3DS.

### Angles

| Built-in | Meaning | 3DS |
|---|---|---|
| `to_radians(a)`, `to_degrees(a)` | convert | =1 |
| `sin_approx(a)`, `cos_approx(a)` | sine and cosine from a polynomial, with a stated error (section 15) | =11, =12 |

### Vectors

| Built-in | Meaning | 3DS |
|---|---|---|
| `dot(a, b)` | dot product, for 2, 3 or 4 components; returns `f32` | ok (1, `dp3` or `dp4`) |
| `length(a)` | `sqrt(dot(a, a))` | =3 |
| `distance(a, b)` | `length(a - b)` | =4 |
| `normalize(a)` | unit vector | =3 |
| `cross(a, b)` | cross product, `[3]f32` only | =2 |
| `reflect(i, n)` | reflect `i` about the unit normal `n` | =3 |
| `refract(i, n, eta)` | refraction, `[3]f32` only | =16 |
| `dot3_signed(a, b)` | `4 * dot(a.rgb - 0.5, b.rgb - 0.5)`, returns `f32` | fragment only: DOT3_RGB or DOT3_RGBA (part 3) |
| `normal_quaternion(n)` | the rotation taking +Z to the unit normal `n`, `[3]f32` to `[4]f32` (vector part, scalar): `normalize((-n.y, n.x, 0, max(1 + n.z, 0.00001)))`. What an `out:"normalquat"` holds (2026-11-24, G2 L1) | =9, the sequence the lighting plan's L0 ran on hardware |
| `light_diffuse(quat, view)` | the lit colour: ambient plus each light's diffuse, `[4]f32`. `quat` is the `normalquat` varying, `view` the `view` varying, both unchanged (MBS-E20). Fragment only (2026-11-24, G2 L2). Reads the engine's lights (8 slots on the 3DS and the Vita, 64 on PC, whose loop stops at `lights_count`: directions towards each light in eye space, diffuse and specular colours, and the ambient), which a call brings in without a declaration (2026-11-25, L3) | the fragment lighting unit, the TexEnv source `FRAGMENT_PRIMARY`; PC and Vita: a function following the unit (mbsc's `lighting.odin`) |
| `light_specular(quat, view)` | the highlight, `[4]f32`, same arguments. Fragment only. Only where the light is in front of the surface; `(N.H)^render.shininess * render.specular_strength`. Its alpha is 0, so adding it to a textured colour keeps the texture's alpha | the unit's `FRAGMENT_SECONDARY`; PC and Vita: the same function |
| `light_finish(color, view)` | **PC only**, under `when TARGET == .PC { ... }`. The scene's exposure, then tonemap, then fog applied to a lit colour, `[4]f32`; `view` is the pixel's `out:"view"` varying, whose length is the distance the fog reads. Alpha is kept. Settings come from `Lighting_Settings` (`exposure`, `tonemap`, `fog`); with none set it only clamps to 0..1. While a tonemap is on, `light_diffuse` and `light_specular` are no longer clamped to 1 (the curve does that). `light_diffuse` also reads `hemisphere` (sky `ambient`, `ambient_ground`) on PC | not on the 3DS or the Vita: calling it there is an error, so wrap it in `when TARGET == .PC`; `mesh_lit.mbs` and `mesh_skinned_lit.mbs` are the model |

### Matrices

| Built-in | Meaning | PC | Vita | 3DS |
|---|---|---|---|---|
| `m * v` | matrix times vector | ok | ok | =4 (one `dp4` per row) |
| `v * m` | vector times matrix | ok | ok | =4 |
| `m * n` | matrix times matrix | ok | ok | **x**: do it on the CPU and pass the result as a uniform |
| `transpose(m)` | transpose | ok | ok | **x**: upload the transposed matrix instead |
| `determinant(m)` | determinant | ok | ok | **x**: CPU |

### Textures and the fragment stage

| Built-in | Stage | PC | Vita | 3DS |
|---|---|---|---|---|
| `sample(tex, uv)` | fragment | ok | ok | a combiner input (part 3) |
| `sample(tex, uv)` | vertex | ok | ok | **x** (`MBS-E8`) |
| `sample_lod(tex, uv, lod)` | fragment or vertex | ok | ok | **x** |
| `sample_bias(tex, uv, bias)` | fragment | ok | ok | **x** |
| `sample_grad(tex, uv, dx, dy)` | fragment | ok | ok | **x** |
| `ddx(a)`, `ddy(a)`, `fwidth(a)` | fragment | ok | ok | **x** |
| `discard()` | fragment | ok | ok | the alpha test, in one form (part 3, `MBS-E12`) |

### Extended: PC and Vita only

These exist on PC and Vita and give an error on the 3DS, with a fix (section 14).

`sin`, `cos`, `tan`, `asin`, `acos`, `atan`, `atan2`, `sinh`, `cosh`, `tanh`, `ldexp`, `is_nan`, `is_inf`.

### Not built-ins

| Name | Why |
|---|---|
| `frexp` | the Vita compiler rejects it (`profile 'sce_vp_psp2' does not support 'frexp()'`) |
| `noise` | rejected on PC and Vita |
| `inverse` | no target has it; compute on the CPU |
| `rcp` | Cg has no `rcp`; write `1.0 / a` |
| `sincos` | use `sin_approx` and `cos_approx`, or `sin` and `cos` where allowed |
| `isfinite`, `lit`, `clip` | not in Odin's math, rare, and each has a short replacement |
| `face_forward` | in Odin's `linalg`, and its 3DS lowering assembles (the probe checked it), but nothing in a 2D game or the first 3D shaders needs it. Added when a shader does |
| bit operations, atomics, compute, tessellation, `printf` | not shader-stage features here |

### Checks still to make on hardware

These are results the probe can't give, because it only asks a compiler whether it accepts the code:

- **3DS:** `sqrt(0)` (the lowering is `rcp(rsq(x))`), the real error of `sin_approx` and `cos_approx` on 24-bit floats, and
  `round` and `fmod` at the half and negative cases (S5, on the New 3DS LL).
- **Vita:** `round` at exact halves and `fmod` for negative numbers, to confirm Cg gives the same answers as HLSL, plus vertex
  texture sampling and derivatives (S4, Vita3K first, then hardware).

If a check shows a target differing, mbsc emits an explicit sequence for that target so the answer matches. It does not change the rule.

## 14. What an error tells you to do instead

This table is the source for the `help:` lines of `MBS-E1`, so a message always offers something that works:

| Built-in on the 3DS | Do this |
|---|---|
| `sin`, `cos` | `sin_approx(x)`, `cos_approx(x)` |
| `tan` | `sin_approx(x) / cos_approx(x)`, keeping `cos` away from zero |
| `sincos` | call `sin_approx` and `cos_approx` |
| `asin`, `acos`, `atan`, `atan2`, `sinh`, `cosh`, `tanh` | work it out on the CPU and pass the result as a uniform, or give the 3DS its own version with `when TARGET == .PICA200` |
| `ldexp(x, e)` | `x * exp2(e)` |
| `modf(x)` | `trunc(x)` for the whole part and `x - trunc(x)` for the rest |
| `is_nan`, `is_inf` | no 3DS equivalent; remove the check on the 3DS with `when` |
| `m * n`, `transpose`, `determinant` | do it on the CPU and pass the result as a uniform |
| `sample` in the vertex stage | sample in the fragment stage, or pass the data in a uniform |
| `sample_lod`, `sample_bias`, `sample_grad`, `ddx`, `ddy`, `fwidth` | no 3DS equivalent; use `sample` |

In a 3DS **fragment** shader nothing in this table applies: `sin_approx` and every other built-in except `sample`, `lerp`,
`saturate`, `dot3_signed`, `discard` and the lighting calls is `MBS-E2`, and the `help:` says so rather than sending you to
`sin_approx`. What to do there:

| Built-in in a 3DS fragment shader | Do this |
|---|---|
| `sin`, `cos`, `sin_approx`, `cos_approx`, the other trigonometry | compute it in `vertex_main` and pass a varying (interpolated linearly), or sample a ramp texture through a `texcoord` varying |
| `dot`, `length`, `distance`, `normalize`, `cross`, `reflect`, `refract` | compute it in `vertex_main` and pass a varying (interpolated, not renormalised per pixel); for lighting use `light_diffuse` / `light_specular` |
| `floor`, `fract`, `abs`, `min`, `max`, `clamp`, `step`, `smoothstep`, `mod` and the like | a ramp texture holding the curve (a `step` or `smoothstep` is a few texels), its coordinate a `texcoord` varying; or the vertex stage |
| `sqrt`, `pow`, `exp`, `ln` and the like | the vertex stage, a baked texture, or `when TARGET == .PICA200` |

**A `sin` hash does not move to the 3DS vertex stage by swapping in `sin_approx`.** The usual `fract(sin(dot(p, k)) * 43758.5453)`
feeds `sin` an angle of hundreds and multiplies the result by 43758: the 3DS's error of 1e-4 to 3e-3 (section 15) becomes a
whole different number, and `sin_approx` itself is accurate only for small angles. Use a hash with no sine, for example
`q := fract(p * 0.1031); q += dot(q, q.yx + 33.33); fract((q.x + q.y) * q.x)`, on every target.

## 15. `sin_approx` and `cos_approx`

`sin` and `cos` don't exist on the 3DS, and mbsc never quietly swaps in something close. `sin_approx` and `cos_approx`
are built-ins that **are** the approximation, so there is nothing to be surprised by:

- They compile to the **same polynomial on all three targets**. A shader using them gives the same picture on PC, Vita and 3DS.
  (PC and Vita do not use their native `sin` and `cos` here.)
- Argument in radians. The angle is first brought into -pi..pi by subtracting a whole number of turns, then a polynomial
  in `r * r` is evaluated by Horner's rule: degree 9 (odd) for sine, degree 10 (even) for cosine.
- The coefficients were fitted to minimise the largest error on -pi..pi:

```
sin_approx(x):  k = floor(x * 0.15915494309189535 + 0.5)
                r = x - 6.283185307179586 * k
                t = r * r
                p = 2.1478728533851322e-06
                p = p * t - 0.0001926499619928568
                p = p * t + 0.008308984952537351
                p = p * t - 0.16662438501484986
                p = p * t + 0.9999793879828708
                result = r * p

cos_approx(x):  same k, r, t
                p = -2.1978878103077777e-07
                p = p * t + 2.4204400324072683e-05
                p = p * t - 0.001385891587244809
                p = p * t + 0.041659822182074986
                p = p * t - 0.4999942680922626
                p = p * t + 0.9999992215743202
                result = p
```

**Stated error** (largest absolute difference from the true sine or cosine, measured over the whole range):

| `\|x\|` up to | `sin_approx` PC, Vita (32-bit) | `cos_approx` PC, Vita (32-bit) | either, 3DS (24-bit, emulated) |
|---|---|---|---|
| pi | 6.2e-06 | 1.2e-06 | 7e-05 |
| 10 pi (about 31) | 7.3e-06 | 2.3e-06 | 1.3e-04 |
| 100 pi (about 314) | 2.7e-05 | 2.2e-05 | 2.8e-03 |

- **The promise:** within **1e-5** on PC and Vita and within **2e-4** on the 3DS for any angle up to 10 pi. For comparison, one step
  of an 8-bit colour channel is about 4e-3, so the difference between targets is far below what can be seen in a colour.
- **The limit:** the error grows with the size of the angle, because subtracting whole turns loses precision. Past about 100 pi on the
  3DS it reaches 3e-3. Keep the angle small: pass a time that wraps, not one that counts up forever.
- **The 3DS numbers are emulated.** They were computed by rounding every step to the 16-bit mantissa the PICA200's 24-bit floats are
  documented to have. They are an estimate until S5 measures the real thing on the New 3DS LL.
- **Cost:** about 11 and 12 instructions on the PICA200 (all four lanes at once), and about 15 operations on PC and Vita.

## 16. Errors from this part

| Code | When |
|---|---|
| `MBS-E1` | a built-in the target doesn't have (section 14 lists the fix) |
| `MBS-E8` | `sample` in a vertex stage on the 3DS |
| `MBS-E12` | `discard()` that isn't an alpha comparison on the 3DS |
| `MBS-W1` (planned) | a constant argument outside a built-in's domain |

---

# Part 3: the 3DS fragment stage

PC and Vita have a real pixel shader, so a fragment shader there can be any code part 1 and part 2 allow. The 3DS
does not. Its fragment stage is **six fixed combiner stages** (TexEnv) plus an alpha test. This part says exactly
which fragment code fits, how mbsc turns it into stages, and what mbsc says when it doesn't fit.

Everything here applies only when building for the 3DS. A fragment shader that doesn't fit still builds for PC and
Vita; only the 3DS build fails (`MBS-E2`), and the error says what to change. `when TARGET == .PICA200` gives the
3DS its own version.

## 17. How the 3DS draws a pixel

For every pixel the hardware does this, in this order, and nothing else:

1. Reads the interpolated **vertex colour** and up to three **texture samples** (one per texture unit).
2. Runs the combiner stages 0 to 5 in order. Each stage computes a colour and an alpha, from up to **three
   inputs**, with one fixed function.
3. Runs the **alpha test** on the final alpha.
4. Applies fog, the depth test and blending. These are render state the game sets, not part of the shader.

A stage has two halves that run side by side: an RGB half and an alpha half. They have their own function and their
own three inputs, so one stage can work on colour and alpha with different operations.

### What a stage can read

Each of a stage's three inputs is one of these, and may be flipped (`1 - x`) or reduced to one channel:

| Source in Matchbox | What it is | Stage input |
|---|---|---|
| `v.color` (the field tagged `color`) | the interpolated vertex colour | `PRIMARY_COLOR` |
| `sample(tex, v.uv)` for texture slot 0, 1 or 2 | a texture sample | `TEXTURE0`, `TEXTURE1`, `TEXTURE2` |
| a literal or a fragment uniform | one constant colour, **one per stage** | `CONSTANT` |
| the stage before it | the previous stage's result | `PREVIOUS` |

Per input, the operand can be the colour `x`, `1 - x`, the alpha `x.a`, `1 - x.a`, or one channel `x.r`, `x.g`,
`x.b` (or its `1 -`) copied across red, green and blue. Anything else about an input (shifting it, scaling it,
swizzling it into a different order) has no hardware form.

### What a stage can do

| Function | Matchbox expression | Notes |
|---|---|---|
| REPLACE | `a` | the input unchanged |
| MODULATE | `a * b` | |
| ADD | `a + b` | |
| ADD_SIGNED | `a + b - 0.5` | the `- 0.5` is part of the form |
| INTERPOLATE | `lerp(a, b, t)` | `t` is the third input |
| SUBTRACT | `a - b` | |
| MULTIPLY_ADD | `a * b + c` | |
| ADD_MULTIPLY | `(a + b) * c` | |
| DOT3_RGB | `dot3_signed(a, b)` into red, green and blue | alpha comes from the alpha half |
| DOT3_RGBA | `dot3_signed(a, b)` into red, green, blue **and** alpha | alpha half is used up |

Each result may also be multiplied by a literal `2.0` or `4.0` in the same stage (the stage's scale: 1, 2 or 4).

`dot3_signed(a, b)` is `4 * dot(a.rgb - 0.5, b.rgb - 0.5)`, the normal-map style dot product, and returns an `f32`.
It is a built-in on every target, so a shader that uses it means the same thing everywhere. (It is added to the
part 2 tables when this part is approved.)

## 18. How mbsc builds the stages

mbsc reads the fragment expression as a tree and packs it into stages, **fewest first**, using these rules:

1. **One node, one function.** Each `*`, `+`, `-`, `lerp`, `dot3_signed` is one function. Three shapes fuse into
   one stage: `a * b + c`, `(a + b) * c` and `a + b - 0.5`. A `* 2.0` or `* 4.0` on a result folds into the
   scale of the stage that made it.
2. **Chains only.** A stage can read the stage right before it (`PREVIOUS`) and the sources in the table above.
   It can't reach back two stages. A named intermediate that is used more than once is therefore allowed only
   when it is a plain source (a texture sample, `v.color`, a constant); using a computed value twice has no
   hardware form in this version (`MBS-E2`).
3. **Colour and alpha pack together.** `[4]f32{rgb_expression, alpha_expression}` runs both halves in the same
   stages, so it costs the longer of the two, not the sum.
4. **Stage count is checked last.** More than 6 stages is `MBS-E3`, and the error numbers the stage where it ran out.

### Examples

| Fragment code | Stages | How |
|---|---|---|
| `sample(tex, v.uv)` | 1 | REPLACE `TEXTURE0` |
| `sample(tex, v.uv) * v.color` | 1 | MODULATE `TEXTURE0`, `PRIMARY_COLOR` |
| `sample(tex, v.uv) * v.color + tint` | 1 | MULTIPLY_ADD `TEXTURE0`, `PRIMARY_COLOR`, `CONSTANT` |
| `lerp(sample(a, v.uv), sample(b, v.uv2), v.color.a)` | 1 | INTERPOLATE `TEXTURE1`, `TEXTURE0`, alpha of `PRIMARY_COLOR` |
| `sample(tex, v.uv) * v.color * tint` | 2 | MODULATE, then MODULATE `PREVIOUS`, `CONSTANT` |
| `[4]f32{sample(tex, v.uv).rgb * v.color.rgb, sample(tex, v.uv).a}` | 1 | RGB: MODULATE. Alpha: REPLACE |
| `pow(sample(tex, v.uv), gamma)` | none | no function for it, `MBS-E2` |

Texture sampling is not a stage. It is one of the inputs, so it costs nothing on its own.

### Texture units and coordinates

- Slots 0, 1 and 2 are the three texture units. A fourth texture is `MBS-E19`.
- `sample(tex, uv)` needs `uv` to be a texture coordinate coming straight from the vertex stage: a `Varying` field
  tagged `texcoord0`, `texcoord1` or `texcoord2`, used as it is. A computed coordinate (`v.uv * 2.0`, `v.uv + offset`)
  isn't possible per pixel on the 3DS, so it is `MBS-E20`. Do the arithmetic in the vertex stage.
- Texture unit N reads `texcoord N`. When two textures use the same coordinate, mbsc writes the vertex output to
  both `texcoord` registers, which costs one output register and changes nothing about the result.
- `texcoord0` is two components. A cube texture's third component is `texcoord0w`.

### Constants

A stage holds **one** constant colour. A fragment uniform that is a `f32`, `[3]f32` or `[4]f32` can be that
constant, as can a literal. The game sets it per draw like any other uniform. Two different constants needed by the
same stage is `MBS-E21`; the fix is to use a second stage or to merge them into one uniform.

A constant is stored as 8 bits per channel (see below).

## 19. The alpha test

```odin
if color.a < render.alpha_cutoff do discard()
```

This one form becomes the hardware alpha test: compare the final alpha with one reference value. The pixel
is kept when the comparison, flipped, is true.

| Condition that discards | Test the hardware runs (keeps the pixel when) |
|---|---|
| `a < ref` | `GEQUAL` |
| `a <= ref` | `GREATER` |
| `a > ref` | `LEQUAL` |
| `a >= ref` | `LESS` |
| `a == ref` | `NOTEQUAL` |
| `a != ref` | `EQUAL` |

Rules:

- The tested value is the **alpha of the colour the shader returns**, and the `if` is the last thing before the
  `return`. A `discard()` anywhere else, or on another condition (`color.r`, two comparisons, a texture value) is
  `MBS-E12`.
- `ref` is a literal or a fragment uniform of type `f32`. It becomes the alpha test's 8-bit reference. mbsc
  records where it came from, and the engine sets it with the draw (the way it sets any uniform).
- The alpha test is render state, not a stage, so it costs no stages.

## 20. The fragment plan mbsc writes for the 3DS

For each 3DS fragment shader, mbsc writes a table, not code: for each stage the sources, operands, functions,
scale and constant, plus the alpha test (function, and where the reference comes from), plus which texture units
and `texcoord` outputs are used. The 3DS renderer reads the table and issues the citro3d calls
(`C3D_TexEnvSrc`, `C3D_TexEnvOpRgb`, `C3D_TexEnvOpAlpha`, `C3D_TexEnvFunc`, `C3D_TexEnvScale`, `C3D_TexEnvColor`,
`C3D_AlphaTest`). Its exact layout is settled with the 3DS backend (phase S4).

## 21. What the 3DS does differently, said plainly

The language promises the same result on every target. These are the places the hardware makes that impossible to
promise exactly. They are listed so nothing is a surprise.

1. **Every stage clamps to 0..1.** On the 3DS a result above 1 or below 0 is cut after each stage. A float pixel shader doesn't.
2. **Colour is 8 bits.** The 3DS works in steps of 1/255 at every stage, and constants and the alpha reference are
   stored at 8 bits. PC and Vita work in floats.
3. **Fragment lighting is not in the language yet.** The hardware lighting unit feeds two extra sources
   (`FRAGMENT_PRIMARY` and `FRAGMENT_SECONDARY`), and the vertex outputs `normalquat` and `view` exist to drive it.
   Mbsc accepts those two tags on the 3DS, but nothing reads them in a fragment shader in this version. Using the
   lighting sources is `MBS-E2`, with a note that it's reserved.
4. **No fog, depth, blend or stencil in the shader.** On every target these are the game's render state.

### How the first two are handled (decision needed)

Differences 1 and 2 are about **PC and Vita doing too much**, not the 3DS doing too little. Left alone, a shader that
passes the 3DS check can still look slightly different on PC where a value passes 1.0 between two operations.

- **Option A, report it.** mbsc leaves PC and Vita alone and prints a warning `MBS-W2` at each place the 3DS clamps
  and the shader could have gone past 1.0. Nothing changes on PC or Vita.
- **Option B, match it. (Recommended.)** When a fragment shader passes the 3DS check, mbsc adds `saturate` after
  each combiner result in the PC and Vita output too. Every target then clamps at the same points, so the result
  matches, to within the 3DS's 1/255 steps. A shader that doesn't pass the 3DS check isn't touched, because it
  isn't pretending to be portable. This is the same rule as `round` and `fmod`: one well-defined behaviour on every
  target, so mbsc doesn't have to make anything silent.

The 8-bit difference stays a documented limit in both options.

## 22. Errors from this part

| Code | When |
|---|---|
| `MBS-E2` | fragment code that no stage can do (`pow`, a computed value used twice, the lighting sources, ...) |
| `MBS-E3` | the shader needs more than 6 stages |
| `MBS-E12` | a `discard()` that isn't an alpha test |
| `MBS-E19` | more than 3 textures |
| `MBS-E20` | a texture coordinate that isn't a plain `texcoord` varying, or a light built-in's argument that isn't the plain `normalquat` / `view` varying |
| `MBS-E21` | two different constants needed in one stage |

The entries, including the revised `MBS-E2` and `MBS-E3`, are drafted in the scratchpad `shader_errors.md` and go
into `docs/shader_errors.md` when this part is approved.

## Decided for this part

- The fragment stage's only 3DS form is the chain of combiner stages in section 17, plus one alpha test.
- A computed value is used by the next stage only. Reaching further back (`PREVIOUS_BUFFER`) is not in this version.
- `dot3_signed(a, b)` is the way to reach `DOT3_RGB` and `DOT3_RGBA`.
- Lighting is reserved, not available.

## Open for you

1. **Clamping: option A or B** in section 21.
2. **`dot3_signed` as a built-in** with that name. If you prefer another name, it only changes the docs.
3. **Texture units read `texcoord N`.** This is what citro3d sets up. It is on the hardware check list (below).

## Checks still to make on hardware

- Texture unit 2 reading `texcoord2` and unit 1 reading `texcoord1` with citro3d's default setup.
- That the stage clamp happens after the scale, so `x * 2.0` saturates at 1.0 and not at 2.0.
- That `DOT3_RGBA` writes alpha as described (the binding is new).
- That the alpha test's reference rounding (`round(ref * 255)`) matches the PC `a < ref` for references that aren't exact eighths.
