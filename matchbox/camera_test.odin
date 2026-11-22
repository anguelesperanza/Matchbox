#+build windows

package matchbox

import "core:testing"

/*The three targets' screens against Teddy's 270-tall art, and the guards*/
@(test)
test_calculate_integer_zoom :: proc(t:^testing.T) {
	testing.expect_value(t, calculate_integer_zoom(270, 1080), 4) // PC
	testing.expect_value(t, calculate_integer_zoom(270, 544), 2)  // Vita
	testing.expect_value(t, calculate_integer_zoom(270, 240), 1)  // 3DS: shorter than the art, so 1:1
	testing.expect_value(t, calculate_integer_zoom(240, 1080), 4) // 4.5 rounds down
	testing.expect_value(t, calculate_integer_zoom(0, 1080), 1)   // no design height
}
