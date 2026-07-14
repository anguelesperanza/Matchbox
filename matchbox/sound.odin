package matchbox

import sdl "vendor:sdl3"

// -----------------------------------------------------------------------
// Sound
// -----------------------------------------------------------------------

Sound :: struct {
	buf:  [^]u8,
	len:  u32,
	spec: sdl.AudioSpec,
}

load_sound :: proc(bytes: []byte) -> Sound {
	sound: Sound
	io := sdl.IOFromMem(raw_data(bytes), len(bytes))
	sdl.LoadWAV_IO(io, true, &sound.spec, &sound.buf, &sound.len)
	return sound
}

destroy_sound :: proc(sound: ^Sound) {
	sdl.free(sound.buf)
}

play_sound :: proc(sound: ^Sound) {
	stream := sdl.OpenAudioDeviceStream(sdl.AUDIO_DEVICE_DEFAULT_PLAYBACK, &sound.spec, nil, nil)
	sdl.PutAudioStreamData(stream, sound.buf, cast(i32)sound.len)
	sdl.ResumeAudioStreamDevice(stream)
}
