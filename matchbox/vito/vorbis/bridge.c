// Ogg Vorbis decoding for lib/vorbis, built by build.bat like the other
// bridge.c files (add "vorbis" to BRIDGES).
//
// The decoder is stb_vorbis by Sean Barrett (public domain / MIT, see the end
// of stb_vorbis.c), included whole. It does its maths in floating point, which
// is why it lives on the C side: this file is compiled hard-float like the
// rest of VitaSDK, and only integers and pointers cross to Odin.

#define STB_VORBIS_NO_STDIO          // files are read by the caller
#define STB_VORBIS_NO_PUSHDATA_API   // only the "whole file in memory" API
#include "stb_vorbis.c"

// Returns the decoder, or NULL with *error set to an stb_vorbis error number.
void *vito_vorbis_open(const unsigned char *data, int length, int *error) {
    return stb_vorbis_open_memory(data, length, error, NULL);
}

void vito_vorbis_close(void *decoder) {
    stb_vorbis_close((stb_vorbis *)decoder);
}

int vito_vorbis_channels(void *decoder) {
    return stb_vorbis_get_info((stb_vorbis *)decoder).channels;
}

int vito_vorbis_sample_rate(void *decoder) {
    return (int)stb_vorbis_get_info((stb_vorbis *)decoder).sample_rate;
}

// Length of the whole file in frames (samples per channel).
unsigned int vito_vorbis_length(void *decoder) {
    return stb_vorbis_stream_length_in_samples((stb_vorbis *)decoder);
}

// Frames decoded so far.
unsigned int vito_vorbis_position(void *decoder) {
    return (unsigned int)stb_vorbis_get_sample_offset((stb_vorbis *)decoder);
}

// Decodes up to `frames` stereo frames into `out` (2 shorts per frame; a mono
// file is copied to both channels). Returns the frames written; 0 at the end.
int vito_vorbis_read_stereo(void *decoder, short *out, int frames) {
    return stb_vorbis_get_samples_short_interleaved((stb_vorbis *)decoder, 2, out, frames * 2);
}

void vito_vorbis_rewind(void *decoder) {
    stb_vorbis_seek_start((stb_vorbis *)decoder);
}

// Jumps to a frame. Returns 1 on success.
int vito_vorbis_seek(void *decoder, unsigned int frame) {
    return stb_vorbis_seek((stb_vorbis *)decoder, frame);
}
