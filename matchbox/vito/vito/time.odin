package vito

// Time helpers on top of the process clock (sceKernelGetProcessTimeWide):
// microseconds since the program started, 64-bit, so it does not wrap.
//
//   timer: vito.Frame_Timer
//   for {
//       dt := vito.frame_tick(&timer)   // seconds since the previous frame
//       player.x += speed * dt
//       ...
//   }
//
// Link: -lSceLibKernel_stub.

import sce "../sce"

// Microseconds since the program started.
time_us :: #force_inline proc "contextless" () -> u64 {
    return sce.sceKernelGetProcessTimeWide()
}

// Seconds since the program started.
time_seconds :: #force_inline proc "contextless" () -> f64 {
    return f64(time_us()) / 1_000_000
}

// Blocks the calling thread. Other threads keep running.
sleep_ms :: #force_inline proc "contextless" (milliseconds: u32) {
    sce.sceKernelDelayThread(milliseconds * 1000)
}

Frame_Timer :: struct {
    // Seconds between the last two frame_tick calls, limited to max_delta.
    delta:     f32,
    // Frames per second, averaged over the last half second.
    fps:       f32,
    // Number of frame_tick calls so far.
    frame:     u64,
    // Seconds from the first frame_tick to the latest one.
    elapsed:   f64,

    // A frame longer than this (a load, a suspend, a breakpoint) reports this
    // instead, so game logic does not jump. 0 means the default, 0.1 s.
    max_delta: f32,

    last_us:      u64,
    start_us:     u64,
    window_us:    u64,
    window_count: u32,
}

// Call once per frame. Returns the time since the previous call in seconds
// (0 on the very first call), which is also stored in timer.delta.
frame_tick :: proc "contextless" (timer: ^Frame_Timer) -> f32 {
    now := time_us()
    if timer.frame == 0 {
        timer.start_us  = now
        timer.last_us   = now
        timer.window_us = now
    }
    limit := timer.max_delta if timer.max_delta > 0 else 0.1
    timer.delta   = min(f32(now - timer.last_us) / 1_000_000, limit)
    timer.elapsed = f64(now - timer.start_us) / 1_000_000
    timer.last_us = now
    timer.frame  += 1

    timer.window_count += 1
    window := now - timer.window_us
    if window >= 500_000 {
        timer.fps          = f32(timer.window_count) * 1_000_000 / f32(window)
        timer.window_us    = now
        timer.window_count = 0
    }
    return timer.delta
}
