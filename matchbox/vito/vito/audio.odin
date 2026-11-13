package vito

// A small software mixer on top of SceAudioOut, and a WAV loader.
//
//   vito.audio_init()
//   jump, _  := vito.load_wav("app0:/assets/jump.wav")
//   music, _ := vito.load_wav("app0:/assets/music.wav")
//   vito.play_sound(music, loop = true, volume = 0.6)
//   ...
//   if vito.pressed(input, vito.BUTTON_CROSS) do vito.play_sound(jump, pan = -0.5)
//   ...
//   vito.audio_shutdown()
//
// How it works: audio_init opens one stereo 48 kHz output port and starts a
// thread. The thread mixes every playing voice into a buffer and hands it to
// sceAudioOutOutput, which blocks until the hardware wants more. That is why
// it needs its own thread (see docs/getting-started.md, "Audio output").
//
// Sounds can be mono or stereo at any sample rate; the mixer resamples them to
// 48 kHz while it mixes. Only 8-bit and 16-bit PCM WAV files are read.
// Compressed formats (MP3, Ogg) have to be converted on the PC first.
//
// Everything here can be called from the main thread at any time. The mixing
// itself uses integer maths only.
//
// Link: -lSceAudio_stub -lSceLibKernel_stub -lSceKernelThreadMgr_stub
//       -lSceIofilemgr_stub.

import "base:intrinsics"
import "base:runtime"
import sce "../sce"

// The output format. The Vita's MAIN port only accepts 48000 Hz.
MIX_SAMPLE_RATE :: 48000
// Stereo frames per buffer. 1024 frames is about 21 ms: that is the delay
// between play_sound and hearing it, at worst twice that.
MIX_GRAIN       :: 1024
// How many sounds can play at the same time.
MAX_VOICES      :: 16

// PCM audio in memory. `samples` holds interleaved 16-bit samples: one per
// frame for mono, left then right for stereo.
Sound :: struct {
    samples:     []i16,
    channels:    int, // 1 or 2
    sample_rate: int,
    frames:      int, // len(samples) / channels
}

// A playing instance of a sound, returned by play_sound. 0 is "no voice".
// A handle stops matching once its sound has finished, so using a stale one
// is harmless.
Voice :: distinct u32

@(private = "file")
Mix_Voice :: struct {
    active:     bool,
    paused:     bool,
    loop:       bool,
    generation: u32,
    data:       [^]i16,
    channels:   int,
    frames:     u64,
    pos:        u64, // position in source frames, 32.32 fixed point
    step:       u64, // source frames per output frame, 32.32 fixed point
    rate:       int, // source sample rate, kept for set_pitch
    volume:     f32,
    pan:        f32,
    gain_l:     i32, // 1.0 == 1 << 12
    gain_r:     i32,
}

@(private = "file") GAIN_SHIFT :: 12
@(private = "file") GAIN_ONE   :: 1 << GAIN_SHIFT

@(private = "file") mix_voices:   [MAX_VOICES]Mix_Voice
@(private = "file") mix_lock:     sce.KernelLwMutexWork
@(private = "file") mix_port:     i32 = -1
@(private = "file") mix_thread:   sce.UID = -1
@(private = "file") mix_running:  i32 // read by the audio thread with volatile_load
@(private = "file") mix_master:   i32 = GAIN_ONE
@(private = "file") mix_peak:     i32 // loudest sample of the last buffer, 0..32767
@(private = "file") mix_accum:    [MIX_GRAIN * 2]i32
// Two buffers, used in turn: sceAudioOutOutput returns before the hardware has
// finished reading the one it was given (getting-started, gotcha 13).
@(private = "file") mix_buffers:  [2][MIX_GRAIN * 2]i16

// ---- streams: audio produced a piece at a time (decoded music) ------------

// Called by the mixer thread when a stream needs more audio. It writes up to
// `frames` stereo frames (left, right, left, right...) into `out` and returns
// how many it wrote. Fewer than asked means the stream has ended. It runs on
// the audio thread: it must not block for long, and must only touch data
// that nothing else is using at the same time.
Stream_Fill :: #type proc "c" (user: rawptr, out: [^]i16, frames: i32) -> i32

// A playing stream, returned by play_stream. 0 is "no stream".
Stream :: distinct u32

// How many streams can play at once (music, and a second for a crossfade).
MAX_STREAMS :: 2
// Stereo frames asked of a stream at a time.
@(private = "file") STREAM_CHUNK :: 2048

@(private = "file")
Mix_Stream :: struct {
    active:     bool,
    paused:     bool,
    ended:      bool, // the fill callback returned short; play out what is left
    generation: u32,
    fill:       Stream_Fill,
    user:       rawptr,
    frames:     u64, // valid frames in buffer
    pos:        u64, // position in buffer frames, 32.32 fixed point
    step:       u64,
    gain:       i32,
    buffer:     [STREAM_CHUNK * 2]i16,
}
@(private = "file") mix_streams: [MAX_STREAMS]Mix_Stream

// Opens the output port and starts the mixer thread. Returns false if either
// fails; the other audio calls are then harmless no-ops.
audio_init :: proc "contextless" () -> bool {
    if mix_port >= 0 do return true
    if sce.sceKernelCreateLwMutex(&mix_lock, "vito_audio", 0, 0, nil) < 0 do return false

    mix_port = sce.sceAudioOutOpenPort(.MAIN, MIX_GRAIN, MIX_SAMPLE_RATE, .STEREO)
    if mix_port < 0 {
        sce.sceKernelDeleteLwMutex(&mix_lock)
        return false
    }
    intrinsics.volatile_store(&mix_running, 1)
    mix_thread = sce.sceKernelCreateThread("vito_audio", mixer_thread, sce.THREAD_DEFAULT_PRIORITY_USER,
                                           sce.THREAD_DEFAULT_STACK_SIZE, 0, 0, nil)
    if mix_thread < 0 || sce.sceKernelStartThread(mix_thread, 0, nil) < 0 {
        intrinsics.volatile_store(&mix_running, 0)
        if mix_thread >= 0 do sce.sceKernelDeleteThread(mix_thread)
        sce.sceAudioOutReleasePort(mix_port)
        sce.sceKernelDeleteLwMutex(&mix_lock)
        mix_port, mix_thread = -1, -1
        return false
    }
    return true
}

// Stops the mixer thread, lets the last buffer play out and closes the port.
// Call it before freeing any Sound that might still be playing, and at exit.
audio_shutdown :: proc "contextless" () {
    if mix_port < 0 do return
    intrinsics.volatile_store(&mix_running, 0)
    sce.sceKernelWaitThreadEnd(mix_thread, nil, nil)
    sce.sceKernelDeleteThread(mix_thread)
    sce.sceAudioOutOutput(mix_port, nil) // waits for the last buffer
    sce.sceAudioOutReleasePort(mix_port)
    sce.sceKernelDeleteLwMutex(&mix_lock)
    mix_voices = {}
    for &st in mix_streams do st.active = false
    mix_port, mix_thread = -1, -1
}

// Starts playing a sound and returns a handle to that instance.
//   volume  0 is silent, 1 is the sound as recorded, above 1 amplifies
//   pan     -1 is left only, 0 is centre, 1 is right only
//   loop    start again at the end until stopped
//   pitch   playback speed: 2 is an octave up and half as long
// Returns 0 if audio is not running or all MAX_VOICES voices are in use.
play_sound :: proc "contextless" (sound: Sound, volume: f32 = 1, pan: f32 = 0, loop := false, pitch: f32 = 1) -> Voice {
    if mix_port < 0 || sound.frames <= 0 || len(sound.samples) == 0 do return 0
    lock()
    defer unlock()
    for &v, i in mix_voices {
        if v.active do continue
        generation := v.generation + 1
        v = Mix_Voice{
            active     = true,
            loop       = loop,
            generation = generation,
            data       = raw_data(sound.samples),
            channels   = sound.channels,
            frames     = u64(sound.frames),
            rate       = sound.sample_rate,
            volume     = volume,
            pan        = pan,
        }
        set_step(&v, pitch)
        set_gains(&v)
        return make_handle(i, generation)
    }
    return 0
}

// Stops one voice. Its handle becomes invalid.
stop_voice :: proc "contextless" (voice: Voice) {
    lock()
    defer unlock()
    if v := find(voice); v != nil do v.active = false
}

// Stops everything that is playing.
stop_all_voices :: proc "contextless" () {
    if mix_port < 0 do return
    lock()
    defer unlock()
    for &v in mix_voices do v.active = false
    for &st in mix_streams do st.active = false
}

// Stops every voice that is playing this sound. Call it before freeing the
// sound's samples.
stop_sound :: proc "contextless" (sound: Sound) {
    if mix_port < 0 do return
    lock()
    defer unlock()
    for &v in mix_voices {
        if v.active && v.data == raw_data(sound.samples) do v.active = false
    }
}

// True until the voice reaches the end of a non-looping sound or is stopped.
voice_is_playing :: proc "contextless" (voice: Voice) -> bool {
    lock()
    defer unlock()
    return find(voice) != nil
}

voice_set_volume :: proc "contextless" (voice: Voice, volume: f32) {
    lock()
    defer unlock()
    if v := find(voice); v != nil {
        v.volume = volume
        set_gains(v)
    }
}

voice_set_pan :: proc "contextless" (voice: Voice, pan: f32) {
    lock()
    defer unlock()
    if v := find(voice); v != nil {
        v.pan = pan
        set_gains(v)
    }
}

voice_set_pitch :: proc "contextless" (voice: Voice, pitch: f32) {
    lock()
    defer unlock()
    if v := find(voice); v != nil do set_step(v, pitch)
}

// A paused voice keeps its place and its slot.
voice_set_paused :: proc "contextless" (voice: Voice, paused: bool) {
    lock()
    defer unlock()
    if v := find(voice); v != nil do v.paused = paused
}

// Volume applied to the whole mix. 1 is unchanged.
set_master_volume :: proc "contextless" (volume: f32) {
    intrinsics.volatile_store(&mix_master, i32(clamp(volume, 0, 8) * GAIN_ONE))
}

// Loudest sample in the most recent buffer, 0..1. For a level meter.
audio_peak :: proc "contextless" () -> f32 {
    return f32(intrinsics.volatile_load(&mix_peak)) / 32767
}

// How many voices are playing right now.
active_voice_count :: proc "contextless" () -> int {
    if mix_port < 0 do return 0
    lock()
    defer unlock()
    n := 0
    for v in mix_voices do n += int(v.active)
    return n
}

// ---------------------------------------------------------------
// WAV files
// ---------------------------------------------------------------

// Loads a WAV file. The samples are allocated from `allocator`; free them with
// unload_sound. Accepts uncompressed PCM, 8 or 16 bit, mono or stereo, any
// sample rate.
load_wav :: proc(path: cstring, allocator := context.allocator) -> (sound: Sound, ok: bool) {
    file := read_entire_file(path, context.temp_allocator) or_return
    return load_wav_from_memory(file, allocator)
}

// Same as load_wav for a file that is already in memory, for example one
// embedded with #load.
load_wav_from_memory :: proc(file: []u8, allocator := context.allocator) -> (sound: Sound, ok: bool) {
    read_u16 :: proc "contextless" (b: []u8, at: int) -> int { return int(b[at]) | int(b[at + 1]) << 8 }
    read_u32 :: proc "contextless" (b: []u8, at: int) -> int {
        return int(b[at]) | int(b[at + 1]) << 8 | int(b[at + 2]) << 16 | int(b[at + 3]) << 24
    }

    if len(file) < 12 || string(file[0:4]) != "RIFF" || string(file[8:12]) != "WAVE" do return {}, false

    format, channels, rate, bits: int
    have_format := false
    data: []u8

    // A WAV file is a list of chunks: 4 letters, a 32-bit size, the contents,
    // padded to an even length.
    at := 12
    for at + 8 <= len(file) {
        id   := string(file[at:at + 4])
        size := read_u32(file, at + 4)
        body := at + 8
        if size < 0 || body + size > len(file) do size = len(file) - body
        switch id {
        case "fmt ":
            if size < 16 do return {}, false
            format   = read_u16(file, body)
            channels = read_u16(file, body + 2)
            rate     = read_u32(file, body + 4)
            bits     = read_u16(file, body + 14)
            // "Extensible" files keep the real format code further in.
            if format == 0xFFFE && size >= 26 do format = read_u16(file, body + 24)
            have_format = true
        case "data":
            data = file[body:body + size]
        }
        at = body + size + (size & 1)
    }

    if !have_format || data == nil do return {}, false
    if format != 1 || (channels != 1 && channels != 2) || (bits != 8 && bits != 16) || rate <= 0 do return {}, false

    count := len(data) / (bits / 8)
    count -= count % channels
    samples, err := make([]i16, count, allocator)
    if err != nil do return {}, false

    if bits == 16 {
        for i in 0 ..< count do samples[i] = i16(u16(data[i * 2]) | u16(data[i * 2 + 1]) << 8)
    } else {
        // 8-bit WAV is unsigned with 128 as silence.
        for i in 0 ..< count do samples[i] = i16(int(data[i]) - 128) << 8
    }
    return Sound{samples = samples, channels = channels, sample_rate = rate, frames = count / channels}, true
}

// Stops any voice playing the sound and frees its samples.
unload_sound :: proc(sound: ^Sound, allocator := context.allocator) {
    stop_sound(sound^)
    // The audio thread may be in the middle of a buffer that still reads the
    // samples: taking the lock once more waits for it to finish that buffer.
    if mix_port >= 0 {
        lock()
        unlock()
    }
    delete(sound.samples, allocator)
    sound^ = {}
}

// ---------------------------------------------------------------
// Internals
// ---------------------------------------------------------------
@(private = "file")
lock :: #force_inline proc "contextless" () {
    if mix_port >= 0 do sce.sceKernelLockLwMutex(&mix_lock, 1, nil)
}

@(private = "file")
unlock :: #force_inline proc "contextless" () {
    if mix_port >= 0 do sce.sceKernelUnlockLwMutex(&mix_lock, 1)
}

@(private = "file")
make_handle :: #force_inline proc "contextless" (index: int, generation: u32) -> Voice {
    return Voice(generation << 8 | u32(index + 1))
}

// Call with the lock held. nil if the handle is stale or zero.
@(private = "file")
find :: proc "contextless" (voice: Voice) -> ^Mix_Voice {
    index := int(u32(voice) & 0xFF) - 1
    if mix_port < 0 || index < 0 || index >= MAX_VOICES do return nil
    v := &mix_voices[index]
    if !v.active || v.generation != u32(voice) >> 8 do return nil
    return v
}

@(private = "file")
set_gains :: proc "contextless" (v: ^Mix_Voice) {
    volume := clamp(v.volume, 0, 8)
    pan    := clamp(v.pan, -1, 1)
    v.gain_l = i32(volume * min(1, 1 - pan) * GAIN_ONE)
    v.gain_r = i32(volume * min(1, 1 + pan) * GAIN_ONE)
}

@(private = "file")
set_step :: proc "contextless" (v: ^Mix_Voice, pitch: f32) {
    p := clamp(pitch, 0.01, 16)
    // source frames advanced per output frame, as 32.32 fixed point
    v.step = u64(f64(v.rate) * f64(p) / MIX_SAMPLE_RATE * 4294967296.0)
    if v.step == 0 do v.step = 1
}

@(private = "file")
mixer_thread :: proc "c" (args: sce.Size, argp: rawptr) -> i32 {
    current := 0
    for intrinsics.volatile_load(&mix_running) != 0 {
        out := &mix_buffers[current]
        sce.sceKernelLockLwMutex(&mix_lock, 1, nil)
        mix(out)
        sce.sceKernelUnlockLwMutex(&mix_lock, 1)
        sce.sceAudioOutOutput(mix_port, out) // blocks until the port wants more
        current ~= 1
    }
    return 0
}

// Mixes one buffer. Integer maths only. Called with the lock held.
@(private = "file")
mix :: proc "contextless" (out: ^[MIX_GRAIN * 2]i16) {
    acc := &mix_accum
    acc^ = {}

    for &v in mix_voices {
        if !v.active || v.paused do continue
        end := v.frames << 32
        for i in 0 ..< MIX_GRAIN {
            if v.pos >= end {
                if v.loop {
                    v.pos %= end
                } else {
                    v.active = false
                    break
                }
            }
            index := v.pos >> 32
            frac  := i32((v.pos >> 17) & 0x7FFF) // 15 bits of the fraction
            next  := index + 1
            if next >= v.frames do next = 0 if v.loop else index

            l, r: i32
            if v.channels == 2 {
                a, b := i32(v.data[index * 2]), i32(v.data[next * 2])
                l = a + ((b - a) * frac) >> 15
                a, b = i32(v.data[index * 2 + 1]), i32(v.data[next * 2 + 1])
                r = a + ((b - a) * frac) >> 15
            } else {
                a, b := i32(v.data[index]), i32(v.data[next])
                l = a + ((b - a) * frac) >> 15
                r = l
            }
            acc[i * 2]     += (l * v.gain_l) >> GAIN_SHIFT
            acc[i * 2 + 1] += (r * v.gain_r) >> GAIN_SHIFT
            v.pos += v.step
        }
    }

    for &st in mix_streams {
        if !st.active || st.paused do continue
        for i in 0 ..< MIX_GRAIN {
            if st.pos >= st.frames << 32 {
                if st.ended {
                    st.active = false
                    break
                }
                // Keep the fraction, so resampling stays continuous across pieces.
                st.pos -= st.frames << 32
                got := st.fill(st.user, &st.buffer[0], STREAM_CHUNK)
                st.frames = u64(clamp(got, 0, STREAM_CHUNK))
                if got < STREAM_CHUNK do st.ended = true
                if st.frames == 0 {
                    st.active = false
                    break
                }
                if st.pos >= st.frames << 32 do st.pos = 0
            }
            index := st.pos >> 32
            frac  := i32((st.pos >> 17) & 0x7FFF)
            next  := min(index + 1, st.frames - 1)
            a, b := i32(st.buffer[index * 2]), i32(st.buffer[next * 2])
            l := a + ((b - a) * frac) >> 15
            a, b = i32(st.buffer[index * 2 + 1]), i32(st.buffer[next * 2 + 1])
            r := a + ((b - a) * frac) >> 15
            acc[i * 2]     += (l * st.gain) >> GAIN_SHIFT
            acc[i * 2 + 1] += (r * st.gain) >> GAIN_SHIFT
            st.pos += st.step
        }
    }

    master := intrinsics.volatile_load(&mix_master)
    peak: i32
    for i in 0 ..< MIX_GRAIN * 2 {
        // 64-bit: sixteen loud voices times a master above 1 does not fit in 32.
        s := i32(clamp((i64(acc[i]) * i64(master)) >> GAIN_SHIFT, -32768, 32767))
        out[i] = i16(s)
        peak = max(peak, abs(s))
    }
    intrinsics.volatile_store(&mix_peak, min(peak, 32767))
}

// ---------------------------------------------------------------
// Streams
// ---------------------------------------------------------------

// Starts playing audio that `fill` produces on demand, as stereo at
// `sample_rate`. `user` is handed back to `fill`. Returns 0 if audio is not
// running or MAX_STREAMS streams are already playing.
play_stream :: proc "contextless" (fill: Stream_Fill, user: rawptr, sample_rate: int, volume: f32 = 1) -> Stream {
    if mix_port < 0 || fill == nil || sample_rate <= 0 do return 0
    lock()
    defer unlock()
    for &st, i in mix_streams {
        if st.active do continue
        generation := st.generation + 1
        st.active, st.paused, st.ended = true, false, false
        st.generation = generation
        st.fill, st.user = fill, user
        st.frames, st.pos = 0, 0
        st.step = u64(f64(sample_rate) / MIX_SAMPLE_RATE * 4294967296.0)
        st.gain = i32(clamp(volume, 0, 8) * GAIN_ONE)
        return Stream(generation << 8 | u32(i + 1))
    }
    return 0
}

@(private = "file")
find_stream :: proc "contextless" (stream: Stream) -> ^Mix_Stream {
    index := int(u32(stream) & 0xFF) - 1
    if mix_port < 0 || index < 0 || index >= MAX_STREAMS do return nil
    st := &mix_streams[index]
    if !st.active || st.generation != u32(stream) >> 8 do return nil
    return st
}

// Stops a stream. When this returns, its fill callback is not running and
// will not be called again, so whatever it reads from can be released.
stop_stream :: proc "contextless" (stream: Stream) {
    lock()
    defer unlock()
    if st := find_stream(stream); st != nil do st.active = false
}

// False once the stream has ended or was stopped.
stream_is_playing :: proc "contextless" (stream: Stream) -> bool {
    lock()
    defer unlock()
    return find_stream(stream) != nil
}

stream_set_volume :: proc "contextless" (stream: Stream, volume: f32) {
    lock()
    defer unlock()
    if st := find_stream(stream); st != nil do st.gain = i32(clamp(volume, 0, 8) * GAIN_ONE)
}

stream_set_paused :: proc "contextless" (stream: Stream, paused: bool) {
    lock()
    defer unlock()
    if st := find_stream(stream); st != nil do st.paused = paused
}

// Runs `body` while the mixer is not mixing, so it can safely change data a
// stream's fill callback reads (seek a decoder, for example).
with_mixer_locked :: proc "contextless" (body: proc "contextless" (user: rawptr), user: rawptr) {
    lock()
    defer unlock()
    body(user)
}
