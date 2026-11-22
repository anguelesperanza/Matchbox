package matchbox

/*
	target
	======
	Determines what target backend is built
*/


VITA :: #config(MATCHBOX_VITA, false)

#assert(!(VITA && ODIN_MICROARCH_STRING == "mpcore"), "Vita build with the 3DS microarch")
#assert(!(!VITA && ODIN_MICROARCH_STRING == "cortex-a9"), "3DS build with the Vita microarch: pass -define:MATCHBOX_VITA=true")
