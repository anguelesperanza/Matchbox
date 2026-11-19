package mbsc

import "core:fmt"
import "core:testing"
import "vendor:directx/d3d11"
import "vendor:directx/d3d_compiler"

// Compiles HLSL with the same compiler the engine uses at startup (d3dcompiler, Shader Model 5). On Windows only,
// because that is the only place the compiler exists.

// compile_hlsl returns "" when the source compiles, otherwise the compiler's own message.
compile_hlsl :: proc(source: string, entry: cstring, profile: cstring) -> string {
	code: ^d3d11.IBlob
	errors: ^d3d11.IBlob

	result := d3d_compiler.Compile(
		pSrcData = raw_data(source),
		SrcDataSize = uint(len(source)),
		pSourceName = "generated.hlsl",
		pDefines = nil,
		pInclude = nil,
		pEntrypoint = entry,
		pTarget = profile,
		Flags1 = 0,
		Flags2 = 0,
		ppCode = &code,
		ppErrorMsgs = &errors,
	)

	message := ""
	if errors != nil {
		message = fmt.aprintf("%s", cstring(errors->GetBufferPointer()), allocator = context.temp_allocator)
		errors->Release()
	}
	if code != nil {
		code->Release()
	}
	if result < 0 && message == "" {
		message = fmt.aprintf("the compiler failed with code %x", u32(result), allocator = context.temp_allocator)
	}
	if result < 0 {
		return message
	}
	return ""
}

// compile_both compiles the vertex and fragment entry points of generated HLSL and returns what went wrong.
compile_both :: proc(source: string) -> string {
	if message := compile_hlsl(source, "vertex_main", "vs_5_0"); message != "" {
		return fmt.aprintf("vertex_main: %s", message, allocator = context.temp_allocator)
	}
	if message := compile_hlsl(source, "fragment_main", "ps_5_0"); message != "" {
		return fmt.aprintf("fragment_main: %s", message, allocator = context.temp_allocator)
	}
	return ""
}

// expect_compiles makes the test fail when d3dcompiler rejects generated HLSL.
expect_compiles :: proc(t: ^testing.T, text: string, loc := #caller_location) {
	message := compile_both(text)
	if message != "" {
		fmt.eprintfln("--- hlsl ---\n%s------------", text)
		testing.expectf(t, false, "d3dcompiler rejected the HLSL: %s", message, loc = loc)
	}
}
