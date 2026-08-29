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

// A WAV from bytes, so `#load` works and the sound ships inside the executable.
// WAV only -- there is no decoder here for anything compressed.
load_sound :: proc(bytes: []byte) -> Sound {
	sound: Sound
	io := sdl.IOFromMem(raw_data(bytes), len(bytes))
	sdl.LoadWAV_IO(io, true, &sound.spec, &sound.buf, &sound.len)
	return sound
}

// Frees the decoded samples.
destroy_sound :: proc(sound: ^Sound) {
	sdl.free(sound.buf)
}

/*
	Plays the sound once, immediately.

	Opens an audio stream per call, which is what lets the same sound overlap
	with itself, and is also why this is not the procedure to call every frame
	for a looping ambience.
*/
play_sound :: proc(sound: ^Sound) {
	stream := sdl.OpenAudioDeviceStream(sdl.AUDIO_DEVICE_DEFAULT_PLAYBACK, &sound.spec, nil, nil)
	sdl.PutAudioStreamData(stream, sound.buf, cast(i32)sound.len)
	sdl.ResumeAudioStreamDevice(stream)
}
