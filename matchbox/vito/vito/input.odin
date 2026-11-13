package vito

// An input layer over SceCtrl, SceTouch and SceMotion: one call per frame
// fills an Input with what a game usually wants instead of raw samples.
//
//   - buttons: which are held, and which went down or up THIS frame
//   - sticks: -1..1 on each axis with a dead zone
//   - touches: positions in screen pixels (960 x 544), with a stable id per
//     finger and a flag for the frame the finger went down
//   - motion: acceleration, angular velocity and orientation
//
//   vito.input_init({.Front_Touch, .Back_Touch, .Motion})
//   input: vito.Input
//   for {
//       vito.input_update(&input)
//       if vito.pressed(input, vito.BUTTON_CROSS) do jump()
//       move := input.left_stick
//       for t in vito.touches(&input.front) do ...
//   }
//
// Link: -lSceCtrl_stub -lSceTouch_stub -lSceMotion_stub. Nothing here passes a
// float to C, so no bridge is needed.

import "core:math"
import sce "../sce"

SCREEN_WIDTH  :: 960
SCREEN_HEIGHT :: 544

// ---------------------------------------------------------------
// Buttons. These are the SceCtrl bits; combine them with |.
// ---------------------------------------------------------------
BUTTON_SELECT   :: sce.CTRL_SELECT
BUTTON_START    :: sce.CTRL_START
BUTTON_UP       :: sce.CTRL_UP
BUTTON_RIGHT    :: sce.CTRL_RIGHT
BUTTON_DOWN     :: sce.CTRL_DOWN
BUTTON_LEFT     :: sce.CTRL_LEFT
BUTTON_TRIANGLE :: sce.CTRL_TRIANGLE
BUTTON_CIRCLE   :: sce.CTRL_CIRCLE
BUTTON_CROSS    :: sce.CTRL_CROSS
BUTTON_SQUARE   :: sce.CTRL_SQUARE
// The handheld reports its shoulder buttons as LTRIGGER / RTRIGGER. L1 / R1
// are what a DualShock on a PS TV reports. BUTTON_L / BUTTON_R match either,
// so the same code works on both.
BUTTON_L        :: sce.CTRL_LTRIGGER | sce.CTRL_L1
BUTTON_R        :: sce.CTRL_RTRIGGER | sce.CTRL_R1
// Only a DualShock has these.
BUTTON_L3       :: sce.CTRL_L3
BUTTON_R3       :: sce.CTRL_R3

Input_Feature :: enum {
    Front_Touch,
    Back_Touch,
    Motion,
}
Input_Features :: bit_set[Input_Feature]

MAX_TOUCHES :: sce.TOUCH_MAX_REPORT

Touch :: struct {
    id:      u8,     // stays the same while the finger is down
    pos:     [2]f32, // screen pixels; (0, 0) is the top left
    force:   u8,     // 0 unless touch force is enabled and the panel supports it
    pressed: bool,   // true only on the frame the finger went down
}

Touch_Panel :: struct {
    enabled:   bool,
    count:     int,                // fingers down now
    list:      [MAX_TOUCHES]Touch,
    // ids of fingers lifted since the last update
    released_count: int,
    released_ids:   [MAX_TOUCHES]u8,

    // Active area of the panel in its own coordinates, from the system.
    min, size: [2]f32,
}

Motion :: struct {
    valid:        bool,   // false if sampling is off or the read failed
    acceleration: [3]f32, // in g; at rest the vector's length is about 1
    gyro:         [3]f32, // angular velocity, radians per second
    orientation:  [4]f32, // quaternion x, y, z, w
    // Which way the device faces relative to gravity, each axis -1, 0 or 1.
    basic_orientation: [3]f32,
}

Input :: struct {
    // Buttons, as BUTTON_* bits.
    held:     u32, // down now
    pressed:  u32, // went down this frame
    released: u32, // went up this frame

    // Sticks: x is -1 (left) .. 1 (right), y is -1 (up) .. 1 (down), which
    // matches screen coordinates. Values inside the dead zone are 0.
    left_stick:  [2]f32,
    right_stick: [2]f32,

    front:  Touch_Panel,
    back:   Touch_Panel,
    motion: Motion,

    // The untouched controller sample, for anything not covered above.
    raw: sce.CtrlData,
}

// Stick movement below this fraction of full travel reads as zero. The Vita's
// sticks rest a little off centre, so 0 makes things drift.
stick_dead_zone: f32 = 0.15

@(private = "file") features:     Input_Features
@(private = "file") input_ready:  bool

// Call once before input_update. Starts analog stick sampling and whichever
// optional devices are asked for. Returns false if one of them failed to
// start (the others still work).
input_init :: proc "contextless" (want: Input_Features = {.Front_Touch}) -> bool {
    ok := true
    // ANALOG_WIDE also reports the sticks when a DualShock is used on a PS TV.
    if sce.sceCtrlSetSamplingMode(.ANALOG_WIDE) < 0 do ok = false

    features = {}
    if .Front_Touch in want {
        if sce.sceTouchSetSamplingState(sce.TOUCH_PORT_FRONT, .START) >= 0 do features += {.Front_Touch}
        else do ok = false
    }
    if .Back_Touch in want {
        if sce.sceTouchSetSamplingState(sce.TOUCH_PORT_BACK, .START) >= 0 do features += {.Back_Touch}
        else do ok = false
    }
    if .Motion in want {
        if sce.sceMotionStartSampling() >= 0 do features += {.Motion}
        else do ok = false
    }
    input_ready = true
    return ok
}

// Stops what input_init started. Optional at exit.
input_shutdown :: proc "contextless" () {
    if .Front_Touch in features do sce.sceTouchSetSamplingState(sce.TOUCH_PORT_FRONT, .STOP)
    if .Back_Touch in features  do sce.sceTouchSetSamplingState(sce.TOUCH_PORT_BACK, .STOP)
    if .Motion in features      do sce.sceMotionStopSampling()
    features = {}
    input_ready = false
}

// Reads everything once. Call it once per frame; `pressed` and `released`
// compare against the previous call.
input_update :: proc "contextless" (input: ^Input) {
    if !input_ready do input_init()

    // --- buttons and sticks
    pad: sce.CtrlData
    if sce.sceCtrlPeekBufferPositive(0, &pad, 1) >= 0 {
        previous := input.held
        input.raw      = pad
        input.held     = pad.buttons
        input.pressed  = pad.buttons & ~previous
        input.released = previous & ~pad.buttons
        input.left_stick  = stick(pad.lx, pad.ly)
        input.right_stick = stick(pad.rx, pad.ry)
    } else {
        input.pressed, input.released = 0, 0
    }

    // --- touch
    if .Front_Touch in features do update_panel(&input.front, sce.TOUCH_PORT_FRONT)
    if .Back_Touch in features  do update_panel(&input.back, sce.TOUCH_PORT_BACK)

    // --- motion
    input.motion.valid = false
    if .Motion in features {
        state: sce.MotionState
        if sce.sceMotionGetState(&state) >= 0 {
            m := &input.motion
            m.valid        = true
            m.acceleration = {state.acceleration.x, state.acceleration.y, state.acceleration.z}
            m.gyro         = {state.angularVelocity.x, state.angularVelocity.y, state.angularVelocity.z}
            m.orientation  = {state.deviceQuat.x, state.deviceQuat.y, state.deviceQuat.z, state.deviceQuat.w}
            m.basic_orientation = {state.basicOrientation.x, state.basicOrientation.y, state.basicOrientation.z}
        }
    }
}

// True while ANY of the given buttons is down.
held :: #force_inline proc "contextless" (input: Input, buttons: u32) -> bool {
    return input.held & buttons != 0
}

// True on the frame any of the given buttons went down.
pressed :: #force_inline proc "contextless" (input: Input, buttons: u32) -> bool {
    return input.pressed & buttons != 0
}

// True on the frame any of the given buttons was let go.
released :: #force_inline proc "contextless" (input: Input, buttons: u32) -> bool {
    return input.released & buttons != 0
}

// The fingers currently on a panel, as a slice to loop over.
touches :: #force_inline proc "contextless" (panel: ^Touch_Panel) -> []Touch {
    return panel.list[:panel.count]
}

// The d-pad as a direction: each axis is -1, 0 or 1 (y down, like the sticks).
dpad :: proc "contextless" (input: Input) -> [2]f32 {
    d: [2]f32
    if input.held & BUTTON_LEFT  != 0 do d.x -= 1
    if input.held & BUTTON_RIGHT != 0 do d.x += 1
    if input.held & BUTTON_UP    != 0 do d.y -= 1
    if input.held & BUTTON_DOWN  != 0 do d.y += 1
    return d
}

// Converts a raw stick sample (0..255 per axis, 128 at rest) to -1..1 with a
// round dead zone. Outside the dead zone the value is rescaled so movement
// still starts from 0 instead of jumping.
stick :: proc "contextless" (raw_x, raw_y: u8) -> [2]f32 {
    v := [2]f32{(f32(raw_x) - 128) / 127, (f32(raw_y) - 128) / 127}
    length := math.sqrt(v.x * v.x + v.y * v.y)
    if length <= stick_dead_zone || length == 0 do return {0, 0}
    scaled := min((length - stick_dead_zone) / (1 - stick_dead_zone), 1)
    return v * (scaled / length)
}

@(private = "file")
update_panel :: proc "contextless" (panel: ^Touch_Panel, port: u32) {
    if !panel.enabled {
        // Panel coordinates are not screen pixels (the front panel reports
        // about 1920 x 1088, the back about 1920 x 890). Ask for the real
        // active area once; fall back to those sizes if the call fails.
        panel.enabled = true
        panel.min  = {0, 0}
        panel.size = {1919, 1087} if port == sce.TOUCH_PORT_FRONT else {1919, 889}
        info: sce.TouchPanelInfo
        if sce.sceTouchGetPanelInfo(port, &info) >= 0 && info.maxAaX > info.minAaX && info.maxAaY > info.minAaY {
            panel.min  = {f32(info.minAaX), f32(info.minAaY)}
            panel.size = {f32(i32(info.maxAaX) - i32(info.minAaX)), f32(i32(info.maxAaY) - i32(info.minAaY))}
        }
    }

    data: sce.TouchData
    if sce.sceTouchPeek(port, &data, 1) < 0 do return

    old := panel.list
    old_count := panel.count

    panel.count = min(int(data.reportNum), MAX_TOUCHES)
    for i in 0 ..< panel.count {
        r := data.report[i]
        was_down := false
        for j in 0 ..< old_count {
            if old[j].id == r.id {
                was_down = true
                break
            }
        }
        panel.list[i] = Touch{
            id      = r.id,
            pos     = {
                (f32(r.x) - panel.min.x) / panel.size.x * SCREEN_WIDTH,
                (f32(r.y) - panel.min.y) / panel.size.y * SCREEN_HEIGHT,
            },
            force   = r.force,
            pressed = !was_down,
        }
    }

    panel.released_count = 0
    for j in 0 ..< old_count {
        still_down := false
        for i in 0 ..< panel.count {
            if panel.list[i].id == old[j].id {
                still_down = true
                break
            }
        }
        if !still_down {
            panel.released_ids[panel.released_count] = old[j].id
            panel.released_count += 1
        }
    }
}
