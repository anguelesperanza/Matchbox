#+build freestanding arm32

package matchbox

/*
	Clipping on the handhelds: there is none, so the procedures do nothing and a game written for the PC builds. What is
	drawn between clip_start and clip_end shows in full
*/

/*Does nothing on the handhelds*/
clip_start :: proc(min, max: [2]f32) {
}

/*Does nothing on the handhelds*/
clip_end :: proc() {
}

/*Never clipped on the handhelds*/
get_clip_rectangle :: proc() -> (min, max: [2]f32, active: bool) {
	return {}, {}, false
}
