package randomwalk

import "core:fmt"
import "../../../matchbox/matchbox"

main :: proc() {
	matchbox.init("Random Walk", 600, 600)

	size:[2]int = {200, 200} // The area the random walk will traverse
	start:[2]f32 = {300, 300} // starting position based on window size
	steps:int = 200 // How many steps will be walked
	stride:f32 = 8 // size of each walk

	level := matchbox.random_walk(size, start, steps, stride)

	cols := size.x / cast(int)stride
	rows := size.y / cast(int)stride

	for matchbox.mbi.running {
		matchbox.poll_events()
		matchbox.begin_drawing()
		matchbox.clear_background(matchbox.BLACK)

		for row in 0 ..< rows {
			for col in 0..< cols {
				index := row * cols + col
				cell := level[index]
				if cell == 1 { 
					matchbox.draw_rect({{f32(col) * stride, f32(row) * stride}, {stride, stride}, matchbox.PUMPKIN_ORANGE, 0})
				}

			}
		}
		matchbox.end_drawing()
	}

	matchbox.wait_idle()
	matchbox.cleanup()
}
