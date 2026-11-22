#+build freestanding arm32

package matchbox

/*
	Audio -- handhelds
	==================
	Stubbed on every target until the rendering pipeline is done (render_plan.md, A0b).
	`Audio` is empty and the procs do nothing, so a game keeps its audio calls and compiles.

	One file for the 3DS and the Vita, like input_handheld_freestanding_arm32.odin. It moves
	back into each target's own file when audio is written, since NDSP and SceAudio share nothing
*/

Audio :: struct {
}

load_audio :: proc(filepath:string) -> (audio:Audio) {
	return
}

play_audio :: proc(audio:Audio) {
}

destroy_audio :: proc(audio:Audio) {
}
