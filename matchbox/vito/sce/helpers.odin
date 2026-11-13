package sce

// Hand-written conveniences that are not part of the SDK headers.

// The handheld's screen.
DISPLAY_WIDTH  :: 960
DISPLAY_HEIGHT :: 544

// Color32 packs a pixel for DisplayPixelFormat.A8B8G8R8 (0xAABBGGRR).
Color32 :: #force_inline proc "contextless" (r, g, b, a: u8) -> u32 {
    return u32(a) << 24 | u32(b) << 16 | u32(g) << 8 | u32(r)
}

// CDRAM memory blocks must be a multiple of 256 KiB.
CDRAM_ALIGNMENT :: 256 * 1024

// Mode for files and folders created from homebrew. The SDK notes that the
// system bits have to be set by the caller.
IO_DEFAULT_MODE :: S_IRWXU | S_IRWXS

// Thread defaults. The header's own example creates threads with priority
// 0x10000100 and a 0x10000 byte stack. A lower number is a higher priority.
THREAD_DEFAULT_PRIORITY_USER     :: 0x10000100
THREAD_DEFAULT_STACK_SIZE        :: 0x10000
THREAD_CPU_AFFINITY_MASK_DEFAULT :: 0 // inherit the process's affinity

// Seconds between two sceKernelGetProcessTimeWide() readings (microseconds).
process_time_delta_seconds :: #force_inline proc "contextless" (from, to: u64) -> f32 {
    return f32(f64(to - from) / 1000000.0)
}

// True when an SCE call's return value is an error (they are all negative).
failed :: #force_inline proc "contextless" (ret: i32) -> bool {
    return ret < 0
}
