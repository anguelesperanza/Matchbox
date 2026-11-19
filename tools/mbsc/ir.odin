package mbsc

// The intermediate form (S1, step 5): what the backends read. It is a typed tree, built from a shader that the
// checker accepted, for one target. Compared with the source:
//
//   - every expression carries its type;
//   - `when` is settled: only the branch for the target is left;
//   - constants (`NAME :: value`) are replaced by their value;
//   - `a += b` is written out as `a = a + b`;
//   - parentheses and unary plus are gone, and struct literals list every field in order;
//   - every variable has a number that is unique within its procedure, so shadowing can't confuse a backend;
//   - only the procedures the entry points can reach are kept, callees before callers.

IR_Var_Kind :: enum {
	LOCAL, // a variable or a local constant
	PARAM,
	LOOP, // the counter of a `for`
}

IR_Var :: struct {
	id:      int, // unique within the procedure
	name:    string,
	type:    ^Type,
	kind:    IR_Var_Kind,
	mutable: bool,
}

Unary_Op :: enum {
	NEGATE,
	NOT,
}

Binary_Op :: enum {
	ADD,
	SUB,
	MUL,
	DIV,
	LESS,
	GREATER,
	LESS_EQUAL,
	GREATER_EQUAL,
	EQUAL,
	NOT_EQUAL,
	AND,
	OR,
}

IR_Expr :: struct {
	type:    ^Type,
	variant: union {
		IR_Float,
		IR_Int,
		IR_Bool,
		IR_Zero,
		IR_Var_Ref,
		IR_Uniform_Ref,
		IR_Texture_Ref,
		IR_Unary,
		IR_Binary,
		IR_Swizzle,
		IR_Field,
		IR_Index,
		IR_Convert,
		IR_Construct,
		IR_Builtin_Call,
		IR_Proc_Call,
	},
}

IR_Float :: struct {
	value: f32,
}

// IR_Int is an `i32` or a `u32` (the expression's type says which).
IR_Int :: struct {
	value: i64,
}

IR_Bool :: struct {
	value: bool,
}

// IR_Zero is the all-zero value of its type: what `x: T` and `T{}` mean.
IR_Zero :: struct {}

IR_Var_Ref :: struct {
	var: ^IR_Var,
}

IR_Uniform_Ref :: struct {
	name: string,
	kind: Uniform_Kind,
}

IR_Texture_Ref :: struct {
	name: string,
	slot: int,
}

IR_Unary :: struct {
	op:      Unary_Op,
	operand: ^IR_Expr,
}

IR_Binary :: struct {
	op:    Binary_Op,
	left:  ^IR_Expr,
	right: ^IR_Expr,
}

// IR_Swizzle reads components of a vector: `v.zyx` is indices {2, 1, 0}. One index gives a scalar.
IR_Swizzle :: struct {
	base:    ^IR_Expr,
	indices: [4]u8,
	count:   int,
}

IR_Field :: struct {
	base:  ^IR_Expr,
	index: int, // position in the struct
	name:  string,
}

IR_Index :: struct {
	base:  ^IR_Expr,
	index: ^IR_Expr,
}

// IR_Convert is `f32(x)`, `i32(x)` or `u32(x)`; the expression's type is the target.
IR_Convert :: struct {
	operand: ^IR_Expr,
}

// IR_Construct builds a vector, array, struct or matrix from all of its parts: a vector's or array's elements in
// order, a struct's fields in declaration order, and a matrix's numbers in the order they were written.
IR_Construct :: struct {
	args: []^IR_Expr,
}

IR_Builtin_Call :: struct {
	name: string,
	args: []^IR_Expr,
}

IR_Proc_Call :: struct {
	callee: ^IR_Proc,
	args:   []^IR_Expr,
}

IR_Stmt :: struct {
	variant: union {
		IR_Declare,
		IR_Assign,
		IR_If,
		IR_For,
		IR_Return,
		IR_Eval,
		IR_Block,
	},
}

// IR_Declare introduces a variable. With no `init` it starts as zero.
IR_Declare :: struct {
	var:  ^IR_Var,
	init: ^IR_Expr,
}

// IR_Assign writes a variable, or a field, element or swizzle of one.
IR_Assign :: struct {
	target: ^IR_Expr,
	value:  ^IR_Expr,
}

IR_If :: struct {
	condition: ^IR_Expr,
	then:      []^IR_Stmt,
	otherwise: []^IR_Stmt, // empty when there is no `else`
}

// IR_For counts `var` from `from` up to `to`, which is included only when `inclusive` is set.
IR_For :: struct {
	var:       ^IR_Var,
	from:      ^IR_Expr,
	to:        ^IR_Expr,
	inclusive: bool,
	body:      []^IR_Stmt,
}

IR_Return :: struct {
	value: ^IR_Expr, // nil in a procedure with no result
}

// IR_Eval is a call whose value isn't used: `discard()`, or a procedure that returns nothing.
IR_Eval :: struct {
	call: ^IR_Expr,
}

IR_Block :: struct {
	body: []^IR_Stmt,
}

IR_Stage :: enum {
	HELPER,
	VERTEX,
	FRAGMENT,
}

IR_Proc :: struct {
	name:   string,
	stage:  IR_Stage,
	params: []^IR_Var,
	result: ^Type, // TYPE_VOID when the procedure returns nothing
	body:   []^IR_Stmt,
}

IR_Field_Info :: struct {
	name: string,
	type: ^Type,
	attr: string, // the `attr:"..."` tag, "" when there is none
	out:  string, // the `out:"..."` tag, "" when there is none
}

IR_Struct :: struct {
	name:   string, // "" for the inline struct of an engine block
	fields: []IR_Field_Info,
}

IR_Uniform :: struct {
	name:   string,
	kind:   Uniform_Kind,
	type:   ^Type,
	fields: []IR_Field_Info, // when the uniform is a struct: its fields
}

IR_Texture :: struct {
	name: string,
	slot: int,
}

IR_Module :: struct {
	target:        Target,
	structs:       []IR_Struct, // the structs the shader declares, in order
	uniforms:      []IR_Uniform,
	textures:      []IR_Texture,
	procs:         []^IR_Proc, // reachable procedures; a procedure comes after the ones it calls
	vertex_main:   ^IR_Proc,
	fragment_main: ^IR_Proc,
}
