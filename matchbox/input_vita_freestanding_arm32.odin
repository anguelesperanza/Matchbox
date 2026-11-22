#+build freestanding arm32

package matchbox

/*
	Input -- Vita
	=============
	Button -> the Vita's buttons, mapped onto the same names the PC and the 3DS use. The
	values are SceCtrl's bits, so a query is one mask against vito's Input.

	Key and Mouse are in input_handheld_freestanding_arm32.odin, with the key procs; the mouse
	procs are here and in the 3DS's file, because the 3DS answers them from its stylus.

	Inside `when VITA` for the reason in backend_vita_freestanding_arm32.odin
*/

import "vito/sce"
import "vito/vito"

when VITA {

	Button :: enum u32 {
		// Face buttons, by position: Cross is the bottom one, as B is on the 3DS
		FACE_UP = sce.CTRL_TRIANGLE,
		FACE_DOWN = sce.CTRL_CROSS,
		FACE_LEFT = sce.CTRL_SQUARE,
		FACE_RIGHT = sce.CTRL_CIRCLE,

		// DPAD
		DPAD_UP = sce.CTRL_UP,
		DPAD_DOWN = sce.CTRL_DOWN,
		DPAD_LEFT = sce.CTRL_LEFT,
		DPAD_RIGHT = sce.CTRL_RIGHT,

		// Shoulder buttons. The handheld reports L / R as LTRIGGER / RTRIGGER, and a DualShock
		// on a PS TV as L1 / R1, so each name matches both (vito's BUTTON_L / BUTTON_R)
		LEFT_SHOULDER = vito.BUTTON_L,
		RIGHT_SHOULDER = vito.BUTTON_R,

		// Fake -- the handheld has no triggers. On a PS TV a DualShock's L2 / R2 arrive as
		// LTRIGGER / RTRIGGER, which the shoulders above already read
		LEFT_TRIGGER = 1 << 28,
		RIGHT_TRIGGER = 1 << 29,

		// Misc.
		START = sce.CTRL_START,
		SELECT = sce.CTRL_SELECT,

		// Pressing the sticks in: only a DualShock on a PS TV has these
		LEFT_THUMBSTICK = sce.CTRL_L3,
		RIGHT_THUMBSTICK = sce.CTRL_R3,
	}

	/*
		True on the frame `button` went down
		id -> Unused: the Vita has one controller, so it defaults to 0
	*/
	is_gamepad_pressed :: proc(button:Button, id:i32 = 0) -> bool {
		return mbi.input.pressed & u32(button) != 0
	}

	/*True while `button` is down*/
	is_gamepad_held :: proc(button:Button, id:i32 = 0) -> bool {
		return mbi.input.held & u32(button) != 0
	}

	/*True on the frame `button` was let go*/
	is_gamepad_released :: proc(button:Button, id:i32 = 0) -> bool {
		return mbi.input.released & u32(button) != 0
	}

	/*
		The stick's x and y, -1..1, with a dead zone. vito gives +y down, like the screen;
		Matchbox's world is +y up, as the PC's and the 3DS's sticks are, so y is flipped here
	*/
	get_thumbstick_value :: proc(thumbstick:Button) -> (axis:[2]f32) {
		#partial switch thumbstick {
		case .LEFT_THUMBSTICK:
			return {mbi.input.left_stick.x, -mbi.input.left_stick.y}
		case .RIGHT_THUMBSTICK:
			return {mbi.input.right_stick.x, -mbi.input.right_stick.y}
		}
		return {}
	}

	/*Always 0: the Vita has no triggers (see the fake LEFT_TRIGGER / RIGHT_TRIGGER above)*/
	get_trigger_value :: proc(trigger:Button) -> f32 {
		return 0
	}

	// The mouse, until the front touch panel stands in for it (render_plan.md, F3)

	/*Always {0, 0} for now*/
	get_mouse_position :: proc() -> [2]i32 {
		return {}
	}

	/*Always false for now*/
	is_mouse_pressed :: proc(mouse:Mouse) -> bool {
		return false
	}

	/*Always false for now*/
	is_mouse_held :: proc(mouse:Mouse) -> bool {
		return false
	}

	/*Always false for now*/
	is_mouse_released :: proc(mouse:Mouse) -> bool {
		return false
	}
}
