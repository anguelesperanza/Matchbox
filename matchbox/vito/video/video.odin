// Package video plays MP4 files (H.264 video, AAC sound) with the console's
// own player, SceAvPlayer, which decodes in hardware. The picture arrives as
// a texture that lib/gfx's 2D calls can draw; the sound is played on its own
// audio port by a small thread.
//
//   gfx.init(); gfx.draw2d_init()
//   movie, ok := video.open("app0:/assets/intro.mp4")
//   for {
//       video.update(movie)                      // every frame
//       gfx.begin_frame(); gfx.clear({0, 0, 0, 1}); gfx.begin_2d(.None)
//       if movie.has_frame {
//           gfx.draw_texture_ex(&movie.texture, {0, 0, f32(movie.width), f32(movie.height)}, {0, 0, 960, 544})
//       }
//       gfx.end_2d(); gfx.end_frame(); gfx.swap()
//       if video.finished(movie) do break
//   }
//   gfx.finish()                                 // the GPU may still be using the last frame
//   video.close(movie)
//
// The picture is a YUV texture that the GPU converts to RGB as it samples
// it; it has no alpha, so draw it with gfx.begin_2d(.None) or as the first
// thing in the frame.
//
// What the player accepts: MP4 with H.264 video and AAC sound. Encode on the
// PC, for example:
//     ffmpeg -i in.mov -c:v libx264 -profile:v baseline -level 3.1 -pix_fmt yuv420p
//            -vf scale=960:544 -r 30 -c:a aac -ar 48000 -ac 2 -movflags +faststart out.mp4
//
// Link: -lSceAvPlayer_stub -lSceAudio_stub -lSceSysmodule_stub -lSceGxm_stub
package video

import "base:intrinsics"
import gfx "../gfx"
import sce "../sce"

foreign import libc "system:c"

@(default_calling_convention = "c")
foreign libc {
    @(link_name = "memalign") c_memalign :: proc(alignment, size: uint) -> rawptr ---
    @(link_name = "free")     c_free     :: proc(ptr: rawptr) ---
}

Video :: struct {
    handle:      sce.AvPlayerHandle,
    // The current picture. Valid while has_frame is true, until the next update.
    texture:     gfx.Texture,
    has_frame:   bool,
    width:       int,
    height:      int,
    frames:      int,  // pictures shown so far
    // Sound.
    audio_port:   i32,
    audio_thread: sce.UID,
    audio_run:    i32,
    audio_frames: int, // sound buffers played so far
    sample_rate:  int,
    paused:       bool,
    started:      bool, // the player has been active at least once
    // What the player has done so far, for finding out why a file will not play.
    file:         sce.UID,
    file_opens:   int,
    file_reads:   int,
    file_bytes:   u64,
    file_error:   i32,       // the last negative result of an open or read
    events:       [8]i32,    // the most recent event numbers, oldest first
    event_count:  int,
    file_length:  u64,       // what the size callback last answered
    read_log:     [6]Read,   // the first reads the player made
    allocs:       Alloc_Stats, // general memory
    frame_allocs: Alloc_Stats, // memory for pictures
    frame_misaligned: int,   // picture blocks that did not come back aligned as asked
}

Read :: struct {
    position: u64,
    length:   u32,
    result:   i32,
}

Alloc_Stats :: struct {
    calls:     int,
    failures:  int,
    bytes:     u64,
    largest:   u32, // the biggest single request
    alignment: u32, // the biggest alignment asked for
}

// Event numbers the player reports, as far as they are known (from Sony's
// documentation as remembered, not from the VitaSDK headers, which do not
// list them): 1 stopped, 2 ready, 3 playing, 4 paused, 5 buffering,
// 0x10 subtitle, 0x20 warning.
EVENT_STOP      :: 0x01
EVENT_READY     :: 0x02
EVENT_PLAY      :: 0x03
EVENT_PAUSE     :: 0x04
EVENT_BUFFERING :: 0x05
EVENT_WARNING   :: 0x20

// The SCE error of the last call here that failed, and which step it was.
last_error: i32
Step :: enum {
    None,
    Module,
    Init,
    Source,
}
last_step: Step

@(private) module_loaded: bool

// Opens a video file and starts playing it.
open :: proc(path: cstring, loop := false) -> (video: ^Video, ok: bool) {
    if !module_loaded {
        r := sce.sceSysmoduleLoadModule(.AVPLAYER)
        if r < 0 {
            last_step, last_error = .Module, r
            return nil, false
        }
        module_loaded = true
    }
    video = new(Video)
    video.audio_port, video.audio_thread, video.file = -1, -1, -1

    init: sce.AvPlayerInitData
    init.memoryReplacement.objectPointer     = video
    init.memoryReplacement.allocate          = player_alloc
    init.memoryReplacement.deallocate        = player_free
    init.memoryReplacement.allocateTexture   = player_alloc_frame
    init.memoryReplacement.deallocateTexture = player_free_frame
    // The file is read through sceIo here, so any path sceIoOpen takes works
    // (app0:, ux0:, ...), and what the player asks for can be counted.
    init.fileReplacement.objectPointer = video
    init.fileReplacement.open          = file_open
    init.fileReplacement.close         = file_close
    init.fileReplacement.readOffset    = file_read
    init.fileReplacement.size          = file_size
    init.eventReplacement.objectPointer = video
    init.eventReplacement.eventCallback = on_event
    init.basePriority               = 0xA0
    init.numOutputVideoFrameBuffers = 2
    init.autoStart                  = 1
    init.debugLevel                 = 3
    video.handle = sce.sceAvPlayerInit(&init)
    // The handle is an address, so as an i32 a good one is usually negative:
    // only 0 means failure.
    if video.handle == 0 {
        last_step, last_error = .Init, video.handle
        free(video)
        return nil, false
    }
    if r := sce.sceAvPlayerAddSource(video.handle, path); r < 0 {
        last_step, last_error = .Source, r
        sce.sceAvPlayerClose(video.handle)
        free(video)
        return nil, false
    }
    sce.sceAvPlayerSetLooping(video.handle, 1 if loop else 0)

    // Sound goes out on the BGM port, which takes any sample rate and leaves
    // the MAIN port to lib/vito's mixer.
    intrinsics.atomic_store(&video.audio_run, 1)
    video.audio_thread = sce.sceKernelCreateThread("vito_video_audio", audio_thread, sce.THREAD_DEFAULT_PRIORITY_USER,
                                                   0x10000, 0, 0, nil)
    if video.audio_thread >= 0 {
        argument := video
        sce.sceKernelStartThread(video.audio_thread, size_of(argument), &argument)
    }
    last_step = .None
    return video, true
}

// Fetches the next picture if it is time for one. Call once per frame.
// Returns true when video.texture changed.
update :: proc "contextless" (video: ^Video) -> bool {
    if sce.sceAvPlayerIsActive(video.handle) == 0 do return false
    video.started = true
    frame: sce.AvPlayerFrameInfo
    if sce.sceAvPlayerGetVideoData(video.handle, &frame) == 0 do return false

    video.width  = int(frame.details.video.width)
    video.height = int(frame.details.video.height)
    // Two planes: brightness, then the two colour channels interleaved at
    // half size. The GPU turns them into RGB.
    sce.sceGxmTextureInitLinear(&video.texture.texture, frame.pData, .YVU420P2_CSC1,
                                u32(video.width), u32(video.height), 0)
    sce.sceGxmTextureSetMinFilter(&video.texture.texture, .LINEAR)
    sce.sceGxmTextureSetMagFilter(&video.texture.texture, .LINEAR)
    video.texture.pixels = ([^]u32)(frame.pData)
    video.texture.width  = video.width
    video.texture.height = video.height
    video.texture.stride = video.width
    video.texture.uid    = -1
    video.has_frame = true
    video.frames += 1
    return true
}

// True once a video that does not loop has played to its end. It is false
// while the player is still opening the file (see starting).
finished :: proc "contextless" (video: ^Video) -> bool {
    return video.started && sce.sceAvPlayerIsActive(video.handle) == 0
}

// True from open until the player has become active: it reads the start of
// the file and sets its decoders up first, which takes a moment.
starting :: proc "contextless" (video: ^Video) -> bool {
    return !video.started
}

// Milliseconds played.
time_ms :: proc "contextless" (video: ^Video) -> u64 {
    return sce.sceAvPlayerCurrentTime(video.handle)
}

set_paused :: proc "contextless" (video: ^Video, paused: bool) {
    if paused == video.paused do return
    video.paused = paused
    if paused {
        sce.sceAvPlayerPause(video.handle)
    } else {
        sce.sceAvPlayerResume(video.handle)
    }
}

// Jumps to a time in milliseconds.
seek_ms :: proc "contextless" (video: ^Video, time: u64) -> i32 {
    return sce.sceAvPlayerJumpToTime(video.handle, time)
}

// Stops playback and frees everything. The GPU must be done with the last
// picture (gfx.finish) before this is called.
close :: proc(video: ^Video) {
    if video == nil do return
    intrinsics.atomic_store(&video.audio_run, 0)
    sce.sceAvPlayerStop(video.handle)
    if video.audio_thread >= 0 {
        sce.sceKernelWaitThreadEnd(video.audio_thread, nil, nil)
        sce.sceKernelDeleteThread(video.audio_thread)
    }
    sce.sceAvPlayerClose(video.handle)
    free(video)
}

// ---- sound ----------------------------------------------------------------

@(private)
audio_thread :: proc "c" (args: sce.Size, argp: rawptr) -> i32 {
    video := (^^Video)(argp)^
    rate, channels: int
    for intrinsics.atomic_load(&video.audio_run) != 0 {
        frame: sce.AvPlayerFrameInfo
        if sce.sceAvPlayerIsActive(video.handle) == 0 {
            sce.sceKernelDelayThread(4000)
            continue
        }
        video.started = true
        if sce.sceAvPlayerGetAudioData(video.handle, &frame) == 0 {
            sce.sceKernelDelayThread(4000)
            continue
        }
        new_rate, new_channels := int(frame.details.audio.sampleRate), int(frame.details.audio.channelCount)
        if new_channels < 1 || new_channels > 2 || new_rate <= 0 do continue
        samples := int(frame.details.audio.size) / (2 * new_channels) // per channel, in this buffer
        mode := sce.AudioOutMode.MONO if new_channels == 1 else sce.AudioOutMode.STEREO
        if video.audio_port < 0 {
            video.audio_port = sce.sceAudioOutOpenPort(.BGM, i32(samples), i32(new_rate), mode)
            rate, channels = new_rate, new_channels
        } else if new_rate != rate || new_channels != channels {
            sce.sceAudioOutSetConfig(video.audio_port, sce.Size(samples), i32(new_rate), mode)
            rate, channels = new_rate, new_channels
        }
        video.sample_rate = rate
        if video.audio_port >= 0 {
            sce.sceAudioOutOutput(video.audio_port, frame.pData) // waits until the port wants more
            video.audio_frames += 1
        } else {
            sce.sceKernelDelayThread(10_000)
        }
    }
    if video.audio_port >= 0 {
        sce.sceAudioOutReleasePort(video.audio_port)
        video.audio_port = -1
    }
    return 0
}

// ---- events and file reading ------------------------------------------------

@(private)
on_event :: proc "c" (p: rawptr, event_id: i32, source_id: i32, data: rawptr) {
    video := (^Video)(p)
    if video.event_count >= len(video.events) {
        copy(video.events[:], video.events[1:])
        video.events[len(video.events) - 1] = event_id
    } else {
        video.events[video.event_count] = event_id
    }
    video.event_count += 1
}

@(private)
file_open :: proc "c" (p: rawptr, filename: cstring) -> i32 {
    video := (^Video)(p)
    video.file_opens += 1
    video.file = sce.sceIoOpen(filename, sce.O_RDONLY, 0)
    if video.file < 0 {
        video.file_error = video.file
        return -1
    }
    return 0
}

@(private)
file_close :: proc "c" (p: rawptr) -> i32 {
    video := (^Video)(p)
    if video.file >= 0 do sce.sceIoClose(video.file)
    video.file = -1
    return 0
}

@(private)
file_read :: proc "c" (p: rawptr, buffer: [^]u8, position: u64, length: u32) -> i32 {
    video := (^Video)(p)
    r := sce.sceIoPread(video.file, buffer, sce.Size(length), sce.Off(position))
    if video.file_reads < len(video.read_log) do video.read_log[video.file_reads] = {position, length, r}
    video.file_reads += 1
    if r < 0 {
        video.file_error = r
    } else {
        video.file_bytes += u64(r)
    }
    return r
}

@(private)
file_size :: proc "c" (p: rawptr) -> u64 {
    video := (^Video)(p)
    end := sce.sceIoLseek(video.file, 0, sce.SEEK_END)
    video.file_length = u64(end) if end > 0 else 0
    return video.file_length
}

// ---- memory the player asks for -------------------------------------------

@(private)
note_alloc :: proc "contextless" (stats: ^Alloc_Stats, alignment, size: u32, result: rawptr) {
    stats.calls += 1
    stats.bytes += u64(size)
    stats.largest   = max(stats.largest, size)
    stats.alignment = max(stats.alignment, alignment)
    if result == nil do stats.failures += 1
}

@(private)
player_alloc :: proc "c" (arg: rawptr, alignment: u32, size: u32) -> rawptr {
    result := c_memalign(uint(max(alignment, 8)), uint(size))
    note_alloc(&(^Video)(arg).allocs, alignment, size, result)
    return result
}

@(private)
player_free :: proc "c" (arg: rawptr, ptr: rawptr) {
    c_free(ptr)
}

// Pictures are decoded straight into memory the GPU can read. The hardware
// decoder needs that memory aligned as it asks (1 MiB on a real console):
// with a smaller alignment the player starts, then stops without a picture.
@(private)
player_alloc_frame :: proc "c" (arg: rawptr, alignment: u32, size: u32) -> rawptr {
    align := max(alignment, sce.CDRAM_ALIGNMENT) // video memory comes in 256 KiB steps at least
    rounded := (size + align - 1) &~ (align - 1)
    options: sce.KernelAllocMemBlockOpt
    options.size      = size_of(sce.KernelAllocMemBlockOpt)
    options.attr      = sce.KERNEL_ALLOC_MEMBLOCK_ATTR_HAS_ALIGNMENT
    options.alignment = sce.Size(align)

    base: rawptr
    uid := sce.sceKernelAllocMemBlock("vito_video_frame", sce.KERNEL_MEMBLOCK_TYPE_USER_CDRAM_RW, sce.Size(rounded), &options)
    if uid >= 0 {
        if sce.sceKernelGetMemBlockBase(uid, &base) < 0 ||
           sce.sceGxmMapMemory(base, sce.Size(rounded), sce.GXM_MEMORY_ATTRIB_READ | sce.GXM_MEMORY_ATTRIB_WRITE) < 0 {
            sce.sceKernelFreeMemBlock(uid)
            base = nil
        }
    } else {
        last_error = uid
    }
    video := (^Video)(arg)
    note_alloc(&video.frame_allocs, alignment, size, base)
    if base != nil && uintptr(base) & uintptr(align - 1) != 0 do video.frame_misaligned += 1
    return base
}

@(private)
player_free_frame :: proc "c" (arg: rawptr, ptr: rawptr) {
    uid := sce.sceKernelFindMemBlockByAddr(ptr, 0)
    if uid >= 0 do gfx.free(uid)
}
