package gamepad_example

/*
	Everything the gamepad layer exposes, on screen at once.

	Plug a controller in and out while this is running -- slots are handed out
	as pads connect and freed as they leave, so pad 0 is whoever arrived first.
*/

import "core:fmt"

import "../../matchbox"
import sdl "vendor:sdl3"

DIM    :: [4]f32{0.20, 0.20, 0.24, 1}
BRIGHT :: [4]f32{0.42, 0.72, 0.42, 1}

// Drawn in the order a person reads a controller, rather than enum order.
BUTTONS :: []sdl.GamepadButton{
	.SOUTH, .EAST, .WEST, .NORTH,
	.DPAD_UP, .DPAD_DOWN, .DPAD_LEFT, .DPAD_RIGHT,
	.LEFT_SHOULDER, .RIGHT_SHOULDER,
	.LEFT_STICK, .RIGHT_STICK,
	.BACK, .GUIDE, .START,
}

LABELS :: []string{
	"A", "B", "X", "Y",
	"Up", "Down", "Left", "Right",
	"LB", "RB",
	"LS", "RS",
	"Back", "Guide", "Start",
}

box :: proc(x, y, w, h: f32, color: [4]f32) {
	matchbox.draw_rect({
		position = {x, y},
		size     = {w, h},
		color    = color,
		pivot    = {0.5, 0.5}, // position is the top-left corner
	})
}

main :: proc() {
	matchbox.init("Gamepad", 900, 640)
	defer matchbox.cleanup()

	font := &matchbox.mbi.font

	for matchbox.is_running() {
		matchbox.poll_events()

		matchbox.begin_drawing()
		matchbox.clear_background({0.09, 0.09, 0.11, 1})

		if matchbox.get_gamepad_count() == 0 {
			matchbox.draw_text(font, "No controller. Plug one in.", 40, 60, matchbox.WHITE)
			matchbox.end_drawing()
			continue
		}

		y: f32 = 50
		for pad in 0 ..< matchbox.MAX_GAMEPADS {
			if !matchbox.is_gamepad_connected(pad) do continue

			header := fmt.tprintf("pad %d -- %s", pad, matchbox.get_gamepad_name(pad))
			matchbox.draw_text(font, header, 40, y, matchbox.WHITE)
			y += 34

			// Sticks, drawn as a dot inside its range of travel. The dot sits
			// dead centre until the stick leaves the deadzone.
			for stick, i in ([]matchbox.Gamepad_Stick{.LEFT, .RIGHT}) {
				v := matchbox.get_gamepad_stick(pad, stick)

				cx := 70 + f32(i) * 130
				cy := y + 50

				box(cx - 45, cy - 45, 90, 90, DIM)
				// +y is downward, same as the screen, so this needs no flip
				box(cx + v.x * 38 - 6, cy + v.y * 38 - 6, 12, 12, BRIGHT)
			}

			// Triggers, as bars that fill from the bottom
			for trigger, i in ([]matchbox.Gamepad_Trigger{.LEFT, .RIGHT}) {
				t := matchbox.get_gamepad_trigger(pad, trigger)

				bx := 270 + f32(i) * 40
				box(bx, y + 5, 24, 90, DIM)
				box(bx, y + 5 + 90 * (1 - t), 24, 90 * t, BRIGHT)
			}

			// Buttons
			buttons := BUTTONS
			labels  := LABELS
			for button, i in buttons {
				col := i % 5
				row := i / 5

				bx := 370 + f32(col) * 100
				by := y + f32(row) * 34

				lit := matchbox.is_gamepad_button_held(pad, button)
				box(bx, by, 92, 28, lit ? BRIGHT : DIM)
				matchbox.draw_text(font, labels[i], bx + 8, by + 21, matchbox.WHITE)
			}

			// A press rather than a hold, or it would rumble every frame
			if matchbox.is_gamepad_button_pressed(pad, .SOUTH) {
				matchbox.set_gamepad_rumble(pad, 0.6, 0.6, 200)
			}

			y += 150
		}

		matchbox.draw_text(font, "A / South rumbles", 40, 600, matchbox.WHITE)

		matchbox.end_drawing()
	}
}
