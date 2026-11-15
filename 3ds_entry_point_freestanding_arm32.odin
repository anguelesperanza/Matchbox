package demo

import "base:runtime"

import "matchbox/o3dx/o3dx"

@(export, link_name = "odin_main")
odin_main :: proc "c" (argc: i32, argv: [^]cstring) -> i32 {
	context = o3dx.init()
	main()
	o3dx.shutdown()
	return 0
}
