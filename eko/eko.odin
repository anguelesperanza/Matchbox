package eko

/*
	Eko -- audio
	------------
	miniaudio (`vendor:miniaudio`), with one engine mixing every source so that
	a game makes one system call rather than one per sound.

	**A Matchbox package**, `matchbox/eko`, beside `matchbox` and `tether`
	rather than inside `package matchbox`: it imports nothing from Matchbox, and
	folding it in would link miniaudio into every silent game. It was a
	repository of its own until 2026-09-17; `CLAUDE.md` at the repository root
	has why it moved, and nothing about the API changed when it did.

	`mac` is this package's one global, for the same reason Matchbox has `mbi`
	and Tether has `tpi`: there is one audio engine, and threading it through
	every call would be an argument everywhere and a choice nowhere.
*/

import "base:runtime"
import "core:log"
import "core:strings"
import ma "vendor:miniaudio"

Master_Audio_Control :: struct {
	logger: log.Logger,
	engine: ma.engine,
}
mac: Master_Audio_Control

Audio_Player :: struct {
	sound:   ma.sound,
	playing: bool, // convenience mirror, see is_playing below
}

/*Procedure groups*/



set_audio_listener :: proc {
	set_audio_listener_3d,
	set_audio_listener_2d,
}

set_audio_position :: proc {
	set_audio_position_3d,
	set_audio_position_2d,
}

/*
	Initializes Eko base systems:
	Sets logger to use either its own, or whatever logger is currenlty in place
	(must call eko.init() after logger is setup to use an alreay in use one)

	initializes the audio engine that will handle mixing audio sources
	into one sound to reduce system calls
*/
init :: proc() {
	if context.logger.procedure == nil || context.logger.procedure == log.nil_logger_proc {
		mac.logger     = log.create_console_logger()
		context.logger = mac.logger
		log.info("Eko Logger set as default logger")
	} else {
		mac.logger = context.logger
		log.info("Eko Logger set to already in use logger")
	}

	result := ma.engine_init(nil, &mac.engine)
	if result != .SUCCESS {
		log.errorf("Error: %v, could not init audio engine.\n", result)
	}
}


/*Uninitizizes the audio engine*/
shutdown :: proc() {
	ma.engine_uninit(&mac.engine)
}

/*Creates an audio player. Take a `^Audio_Player` as an argument to prevent crashes*/
create_audio_player :: proc(audio_player: ^Audio_Player, audio_file: string, loop:bool = false) -> bool {

	result := ma.sound_init_from_file(&mac.engine, strings.clone_to_cstring(audio_file), {}, nil, nil, &audio_player.sound)
	if result != .SUCCESS {
		log.errorf("Error: %v, could not load sound %s.\n", result, audio_file)
		return false
	}


	if loop {
		set_looping(audio_player, loop)
	}
	
	return true
}

/*Plays the provided audio*/
play_audio :: proc(audio_player: ^Audio_Player) {
	ma.sound_seek_to_pcm_frame(&audio_player.sound, 0) // restart from beginning
	result := ma.sound_start(&audio_player.sound)
	if result != .SUCCESS {
		log.errorf("Error: %v, could not start sound.\n", result)
		return
	}
	audio_player.playing = true
}

/*Stops the current audio from playing*/
stop_audio :: proc(audio_player: ^Audio_Player) {
	result := ma.sound_stop(&audio_player.sound)
	if result != .SUCCESS {
		log.errorf("Error: %v, could not start sound.\n", result)
		return
	}
	audio_player.playing = false
}

/*Checks if the audio file is playing or not*/
is_playing :: proc(audio_player: ^Audio_Player) -> bool {
	return cast(bool)!ma.sound_at_end(&audio_player.sound) && ma.sound_is_playing(&audio_player.sound)
}

/*Sets the provided audio player to loop*/
set_looping :: proc(audio_player: ^Audio_Player, loop: bool) {
	ma.sound_set_looping(&audio_player.sound, b32(loop))
}

/*Gets the provided audios volume*/
get_audio_volume :: proc(audio_player: ^Audio_Player) -> f32 {
	return ma.sound_get_volume(&audio_player.sound)
}

/*Sets the provided audios volume*/
set_audio_volume :: proc(audio_player: ^Audio_Player, volume_level:f32) {
	ma.sound_set_volume(&audio_player.sound,volume_level )
}

/*unitializes the sound engine*/
destroy_audio_player :: proc(audio_player: ^Audio_Player) {
	stop_audio(audio_player)
	ma.sound_uninit(&audio_player.sound)
}


// Audio Fading -- MiniAudio will compute the math for audio fading so long as it has
// the position of the listener and the position of the source of sound

/*
	The audio listener is a point in space that listens to audio -- a position
	In games, this would typically be the player camera or player position

	This takes a [3]f32 position value
	listener_index is the ID tied to this specific listener
		the ID is arbitruary, it can be the player, an enemey, anything, but the value is a u32
		The default is 0
*/
set_audio_listener_3d:: proc(position:[3]f32, listener_index:u32 = 0) {

	ma.engine_listener_set_position(&mac.engine,listener_index,position.x, position.y, position.z)
}
/*
	The audio listener is a point in space that listens to audio -- a position
	In games, this would typically be the player camera or player position

	This takes a [2]f32 position value
	listener_index is the ID tied to this specific listener
		the ID is arbitruary, it can be the player, an enemey, anything, but the value is a u32
		The default is 0
*/
set_audio_listener_2d:: proc(position:[2]f32, listener_index:u32 = 0) {

	ma.engine_listener_set_position(&mac.engine,listener_index,position.x, position.y, 0)
}


/*Sets the positoin of an audio_player in 3D space*/
set_audio_position_3d:: proc(audio_player:^Audio_Player, position:[3]f32) {
	ma.sound_set_position(&audio_player.sound, position.x, position.y, position.z)
}

/*Sets the positoin of an audio_player in 2D space*/
set_audio_position_2d:: proc(audio_player:^Audio_Player, position:[2]f32) {
	ma.sound_set_position(&audio_player.sound, position.x, position.y, 0)
}



/*
	So long as an audio's position and a listener is set, Eko (through MiniAudio)
	will automatically handle attenuation (fading the sound) regardless of distance

	`fade_clamp` sets a clamp value so the attenuation stops dropping below a
	certain point -- max distance

	`hard_stop` is a flag that will pause the audio after the distance provided.
		Calls eko.set_audio_attentuation(...., linear) internally
	Setting `hard_stop` to false will allow the audio to be heard regardless of distance
*/
fade_clamp :: proc(audio_player: ^Audio_Player, distance:f32, hard_stop:bool = true){
	set_audio_attenuation(audio_player, .linear)
	ma.sound_set_max_distance(&audio_player.sound, distance)
}

/*
	Sets the audio attenuation equation (fade math)
	`attenuation_model` takes a MiniAudio enum value
		(taken from the MiniAudio Odin Bindings)
		none,           No distance attenuation and no spatialization.
		inverse,        Equivalent to OpenAL's AL_INVERSE_DISTANCE_CLAMPED.
		linear,         Linear attenuation. Equivalent to OpenAL's AL_LINEAR_DISTANCE_CLAMPED.
		exponential,    Exponential attenuation. Equivalent to OpenAL's AL_EXPONENT_DISTANCE_CLAMPED.
*/
set_audio_attenuation :: proc(audio_player: ^Audio_Player, attenuation_model:ma.attenuation_model) {
	ma.sound_set_attenuation_model(&audio_player.sound,attenuation_model)
	
	
}
