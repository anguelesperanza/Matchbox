package vito

// What the system does to the game from outside: the PS button, suspend and
// resume, power and battery events.
//
// A Vita game is never asked whether it wants to be suspended. Pressing the
// PS button shows the LiveArea and the game is frozen shortly after; coming
// back resumes it in the middle of whatever it was doing. What the game can
// do is find out afterwards, to pause itself or to reset its frame timer.
//
//   vito.power_events_start()                // once
//   ...
//   events := vito.power_events_take()       // every frame
//   if events & sce.POWER_CB_APP_RESUME != 0 { ... back from the LiveArea ... }
//
// Link: -lScePower_stub -lSceAppMgr_stub -lSceKernelThreadMgr_stub

import "base:intrinsics"
import sce "../sce"

@(private = "file") power_thread_id: sce.UID = -1
@(private = "file") power_running:   i32
@(private = "file") power_flags:     u32
@(private = "file") power_register:  i32

// Starts collecting power events (sce.POWER_CB_*). The system only delivers
// them to a thread that is waiting for callbacks, so this starts a small
// thread that does nothing else.
power_events_start :: proc "contextless" () -> bool {
    if power_thread_id >= 0 do return true
    intrinsics.volatile_store(&power_running, 1)
    power_thread_id = sce.sceKernelCreateThread("vito_power", power_thread, sce.THREAD_DEFAULT_PRIORITY_USER,
                                                0x4000, 0, 0, nil)
    if power_thread_id < 0 || sce.sceKernelStartThread(power_thread_id, 0, nil) < 0 {
        intrinsics.volatile_store(&power_running, 0)
        if power_thread_id >= 0 do sce.sceKernelDeleteThread(power_thread_id)
        power_thread_id = -1
        return false
    }
    return true
}

power_events_stop :: proc "contextless" () {
    if power_thread_id < 0 do return
    intrinsics.volatile_store(&power_running, 0)
    sce.sceKernelWaitThreadEnd(power_thread_id, nil, nil)
    sce.sceKernelDeleteThread(power_thread_id)
    power_thread_id = -1
}

// Returns every event flag that arrived since the last call (sce.POWER_CB_*
// bits or'd together), and forgets them. 0 if nothing happened.
power_events_take :: proc "contextless" () -> u32 {
    return intrinsics.atomic_exchange(&power_flags, 0)
}

// The result of scePowerRegisterCallback in the event thread; negative if
// the system refused it. Valid a moment after power_events_start.
power_events_register_result :: proc "contextless" () -> i32 {
    return intrinsics.volatile_load(&power_register)
}

// The other way to notice a resume: asks SceAppMgr for the next system event
// (sce.APPMGR_SYSTEMEVENT_*). Call every frame; ok is false when there is none.
system_event_poll :: proc "contextless" () -> (event: u32, ok: bool) {
    e: sce.AppMgrSystemEvent
    if sce.sceAppMgrReceiveSystemEvent(&e) < 0 || e.systemEvent == 0 do return 0, false
    return u32(e.systemEvent), true
}

// True while the system is drawing over the game: the quick menu (PS button
// held), a notification being read, and similar. A game would pause.
system_ui_overlaid :: proc "contextless" () -> bool {
    state: sce.AppMgrAppState
    if sce._sceAppMgrGetAppState(&state, size_of(state), sce.PSP2_SDK_VERSION) < 0 do return false
    return state.isSystemUiOverlaid != 0
}

@(private = "file")
power_callback :: proc "c" (notify_id: i32, notify_count: i32, power_info: i32, user_data: rawptr) -> i32 {
    intrinsics.atomic_or(&power_flags, u32(power_info))
    return 0
}

@(private = "file")
power_thread :: proc "c" (args: sce.Size, argp: rawptr) -> i32 {
    callback := sce.sceKernelCreateCallback("vito_power", 0, power_callback, nil)
    if callback < 0 {
        intrinsics.volatile_store(&power_register, callback)
        return 0
    }
    intrinsics.volatile_store(&power_register, sce.scePowerRegisterCallback(callback))
    for intrinsics.volatile_load(&power_running) != 0 {
        sce.sceKernelDelayThreadCB(50_000) // callbacks run inside this wait
    }
    sce.scePowerUnregisterCallback(callback)
    sce.sceKernelDeleteCallback(callback)
    return 0
}
