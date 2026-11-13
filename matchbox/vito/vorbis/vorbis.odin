// Package vorbis plays Ogg Vorbis music through lib/vito's mixer, decoding
// it a little at a time while it plays. A minute of music is about 1 MB as
// Ogg, against 11 MB as WAV, and only the compressed file is kept in memory.
//
//   vito.audio_init()
//   data, _ := vito.read_entire_file("app0:/assets/music.ogg")
//   music, ok := vorbis.open(data)        // keeps using `data`; do not free it yet
//   vorbis.play(music, volume = 0.8, loop = true)
//   ...
//   vorbis.close(music)                   // stops it; now `data` may be freed
//
// The decoder is stb_vorbis (bridge.c in this folder), which build.bat
// compiles when "vorbis" is in BRIDGES. Sound effects played with
// vito.play_sound mix with the music as usual.
//
// Convert music to Ogg on the PC, for example:
//     ffmpeg -i song.wav -c:a libvorbis -q:a 4 song.ogg
package vorbis

import vito "../vito"

// The functions are in bridge.c, linked into the program directly.
foreign import bridge "system:c"

@(default_calling_convention = "c")
foreign bridge {
    @(private) vito_vorbis_open        :: proc(data: [^]u8, length: i32, error: ^i32) -> rawptr ---
    @(private) vito_vorbis_close       :: proc(decoder: rawptr) ---
    @(private) vito_vorbis_channels    :: proc(decoder: rawptr) -> i32 ---
    @(private) vito_vorbis_sample_rate :: proc(decoder: rawptr) -> i32 ---
    @(private) vito_vorbis_length      :: proc(decoder: rawptr) -> u32 ---
    @(private) vito_vorbis_position    :: proc(decoder: rawptr) -> u32 ---
    @(private) vito_vorbis_read_stereo :: proc(decoder: rawptr, out: [^]i16, frames: i32) -> i32 ---
    @(private) vito_vorbis_rewind      :: proc(decoder: rawptr) ---
    @(private) vito_vorbis_seek        :: proc(decoder: rawptr, frame: u32) -> i32 ---
}

Music :: struct {
    decoder:     rawptr,
    channels:    int,
    sample_rate: int,
    frames:      int, // length of the whole file
    loop:        bool,
    stream:      vito.Stream,
}

// stb_vorbis's error number from the last open that failed (34 is "not an
// Ogg Vorbis file", 3 is "out of memory").
last_error: i32

// Opens an Ogg Vorbis file held in memory. The decoder reads from `data`
// for as long as the music is open, so keep it alive until close.
open :: proc(data: []u8) -> (music: ^Music, ok: bool) {
    decoder := vito_vorbis_open(raw_data(data), i32(len(data)), &last_error)
    if decoder == nil do return nil, false
    music = new(Music)
    music.decoder     = decoder
    music.channels    = int(vito_vorbis_channels(decoder))
    music.sample_rate = int(vito_vorbis_sample_rate(decoder))
    music.frames      = int(vito_vorbis_length(decoder))
    return music, true
}

// Stops the music and releases the decoder.
close :: proc(music: ^Music) {
    if music == nil do return
    stop(music)
    vito_vorbis_close(music.decoder)
    free(music)
}

// Starts the music from the beginning. With loop it starts again at the end
// without a gap. False if it could not start (audio not initialised, or two
// streams already playing).
play :: proc "contextless" (music: ^Music, volume: f32 = 1, loop := false) -> bool {
    stop(music)
    vito_vorbis_rewind(music.decoder)
    music.loop = loop
    music.stream = vito.play_stream(fill, music, music.sample_rate, volume)
    return music.stream != 0
}

// Stops the music. play starts it again from the beginning.
stop :: proc "contextless" (music: ^Music) {
    if music.stream != 0 do vito.stop_stream(music.stream)
    music.stream = 0
}

set_paused :: proc "contextless" (music: ^Music, paused: bool) {
    vito.stream_set_paused(music.stream, paused)
}

set_volume :: proc "contextless" (music: ^Music, volume: f32) {
    vito.stream_set_volume(music.stream, volume)
}

// False once music without loop has reached its end, or after stop.
is_playing :: proc "contextless" (music: ^Music) -> bool {
    return vito.stream_is_playing(music.stream)
}

// Seconds decoded so far. This runs ahead of what is heard by the mixer's
// buffering, a few hundredths of a second.
position :: proc "contextless" (music: ^Music) -> f32 {
    return f32(vito_vorbis_position(music.decoder)) / f32(music.sample_rate)
}

// Length of the whole file in seconds.
duration :: proc "contextless" (music: ^Music) -> f32 {
    return f32(music.frames) / f32(music.sample_rate)
}

// Jumps to a time in seconds.
seek :: proc "contextless" (music: ^Music, seconds: f32) {
    Request :: struct {
        music: ^Music,
        frame: u32,
    }
    request := Request{music, u32(clamp(seconds, 0, duration(music)) * f32(music.sample_rate))}
    // The decoder must not be moved while the audio thread is reading from it.
    vito.with_mixer_locked(proc "contextless" (user: rawptr) {
        r := (^Request)(user)
        vito_vorbis_seek(r.music.decoder, r.frame)
    }, &request)
}

// Runs on the audio thread: decode the next piece.
@(private)
fill :: proc "c" (user: rawptr, out: [^]i16, frames: i32) -> i32 {
    music := (^Music)(user)
    written: i32
    for written < frames {
        got := vito_vorbis_read_stereo(music.decoder, &out[written * 2], frames - written)
        if got > 0 {
            written += got
            continue
        }
        // End of the file: start again, or stop here.
        if !music.loop do break
        vito_vorbis_rewind(music.decoder)
        if vito_vorbis_read_stereo(music.decoder, &out[written * 2], 1) <= 0 do break // an empty file
        written += 1
    }
    return written
}
