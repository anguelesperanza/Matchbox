#+build freestanding arm32

package matchbox

/*
	Input
	=====
	Handles the input mapping

	On 3DS -> Mapes to u32 values

	Button -> This is where the buttons are mapped for the 3DS

	Key and Mouse, and the is_key_* / is_mouse_* procs that always answer false,
	are in input_handheld_freestanding_arm32.odin: the Vita has neither either

*/

import "o3dx/ctru"

when !VITA {

	Button :: enum u32 {

		// Face Buttons
	    FACE_UP = ctru.KEY_X,
	    FACE_DOWN = ctru.KEY_B,
	    FACE_LEFT = ctru.KEY_Y,
	    FACE_RIGHT = ctru.KEY_A,

	    // DPAD
	    DPAD_UP = ctru.KEY_DUP,
	    DPAD_DOWN = ctru.KEY_DDOWN,
	    DPAD_LEFT = ctru.KEY_DLEFT,
	    DPAD_RIGHT = ctru.KEY_DRIGHT,

		// Shoulder Buttons
	    LEFT_SHOULDER = ctru.KEY_L,
	    RIGHT_SHOULDER = ctru.KEY_R,
	    LEFT_TRIGGER = ctru.KEY_ZL,
	    RIGHT_TRIGGER  = ctru.KEY_ZR,

		// Misc.
	    START = ctru.KEY_START,
		SELECT = ctru.KEY_SELECT,

		// Fake -- While these exist (circle pad and cstick), these are for buttons you can press in (R3/L3).
		// On the 3DS, that doesn't exist
		LEFT_THUMBSTICK = 101,
		RIGHT_THUMBSTICK = 102,


		// Circle Pad

		// C-Stick
	}


	/*
		On the 3DS this will check if a gamepad button is pressed
		button -> value from the Gamepad_Button enum
		id -> Useless; used to track the gamepad id however there's only
			  one gamepad on the 3DS, so it's default is 0
	*/
	is_gamepad_pressed :: proc (button:Button, id:i32 = 0) -> bool {

		if button == .LEFT_THUMBSTICK || button == .RIGHT_THUMBSTICK do return false

		return mbi.gamepad_pressed & u32(button) != 0

	}
	is_gamepad_held :: proc (button:Button, id:i32 = 0) -> bool {

		if button == .LEFT_THUMBSTICK || button == .RIGHT_THUMBSTICK do return false

		return mbi.gamepad_held & u32(button) != 0

	}

	is_gamepad_released :: proc (button:Button, id:i32 = 0) -> bool {

		if button == .LEFT_THUMBSTICK || button == .RIGHT_THUMBSTICK do return false

		return mbi.gamepad_released & u32(button) != 0

	}
	/*Returns the x, y values on a range of 0-1 for a joystick*/
	get_thumbstick_value :: proc(thumbstick:Button) -> (axis:[2]f32) {

		#partial switch thumbstick {
			case .LEFT_THUMBSTICK:
				return mbi.left_thumbstick_axis
			case .RIGHT_THUMBSTICK:
				return mbi.right_thumbstick_axis
		}
		return {}
	}
	/*
		Behaves differenlty depending on the Platform
		On Windows: The value is tracked on a range of 0 - 1 (not pressed to full pressed)
		On 3DS: Value is tracked as either 0 or 1 (not pressed or pressed) as the 3DS does not have analoge triggers

		As such, this behavior is slightly different depending on the target platform
	*/
	get_trigger_value :: proc(trigger:Button) -> f32 {

		#partial switch trigger {
			case .LEFT_TRIGGER, .RIGHT_TRIGGER:
				if mbi.gamepad_held & u32(trigger) != 0 do return 1
				if mbi.gamepad_held & u32(trigger) != 0 do return 1
		}
		return 0
	}
}
