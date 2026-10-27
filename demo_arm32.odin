package demo

import "base:runtime"

@(export, link_name = "odin_main")
odin_main :: proc "c" (argc: i32, argv: [^]cstring) -> i32 {
	context = runtime.default_context()
	main()
	return 0
}
