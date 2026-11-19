#+build !windows
package mbsc

import "core:testing"

// d3dcompiler exists only on Windows, so elsewhere the generated HLSL is not compiled.
expect_compiles :: proc(t: ^testing.T, text: string, loc := #caller_location) {}
