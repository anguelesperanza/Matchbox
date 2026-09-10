package matchbox

/*
	Errors
	------
	What a procedure hands back when the thing it was asked to make could not be
	made.

		sprite, err := mb.create_sprite(#load("player.png"))
		if err != nil {
			// deal with it
		}

	**A union of enums rather than one flat enum**, which is the shape
	`core:os` settled on and the reason `err != nil` reads the way it does. A
	plain enum would need a `.None` member and every test would be
	`err != .None` -- comparing against a named nothing rather than against
	nothing. `#shared_nil` makes the union nil whenever the enum inside it is
	its own zero value, so the two spellings collapse into one and the zero
	value of an `Error` is "no error" without anyone having to say so.

	Splitting by domain rather than listing every failure in one enum is worth
	the extra names: a caller that only cares whether the GPU refused can
	switch on `Gpu_Error` and ignore the rest, and adding a failure to one
	domain does not renumber the others.

	**What is not here is as deliberate as what is.** A broken invariant --
	drawing outside a pass, `end_clip` without `begin_clip`, using Matchbox
	before `init` -- is not an error, it is a bug in the calling code, and it
	stays an `ensure` that stops the program where the mistake is. Handing
	those back as values would mean either every call site ignoring them or the
	bug going quiet, and a quiet bug in a draw call is the expensive kind.

	Two other things keep a `bool` instead, for two different reasons.

	`get_pinch`, `get_primary_touch` and the two `pixel_buffer_pick`
	procedures answer **"is there one?"** rather than **"did it work?"** --
	fewer than two fingers down, nothing being touched, a point outside the
	buffer. None of those is a failure, and an `Error` would fire `err != nil`
	on the entirely ordinary state of nobody touching the screen.

	The glTF readers in `model_load.odin` and `model_skin_load.odin` --
	`accessor_span`, `image_view_bytes`, `read_scalars` and the rest -- keep
	theirs because they are private, because most of what they report is "the
	file does not have this" rather than a fault, and because they are threaded
	together with `or_return` over glTF's optionals. `.? or_return` yields a
	`bool` and cannot propagate into an `Error` return, so converting them
	means rewriting those unwrap chains by hand in the most delicate parsing
	code here, in exchange for nothing a game can see: `load_model` already
	turns the whole outcome into one error at the boundary.
*/

// Anything the graphics driver refused. None of these are things a game did
// wrong: memory ran out, or the device is in a state that will not take
// another allocation.
Gpu_Error :: enum {
	None = 0,
	Buffer_Creation_Failed,
	Texture_Creation_Failed,
	Transfer_Buffer_Creation_Failed,
	Transfer_Buffer_Map_Failed,
	Submit_Failed,
}

// The bytes handed over were not a picture stb could read. A content problem
// -- the wrong file, a truncated download -- rather than a program one, which
// is why it comes back rather than stopping anything.
Image_Error :: enum {
	None = 0,
	Empty_Input,       // nothing to decode
	Decode_Failed,
	Impossible_Size,   // decoded, but to a width or height of zero or less
	Header_Unreadable, // the dimensions could not be read without decoding
}

/*
	A file that could not be read.

	One member, because from the caller's side there is one answer: the bytes
	are not there. Whether the path was wrong, the file was locked or the asset
	is missing from the apk changes nothing a game can do about it, and SDL's
	own message says which -- it goes to the log where somebody diagnosing it
	will look, rather than into a member nobody switches on.
*/
File_Error :: enum {
	None = 0,
	Read_Failed,
}

// A model file that was found but could not be understood. The read succeeded
// and the parse did not, which is a different problem from a missing file and
// worth telling apart -- one is a shipping mistake, the other a bad export.
Model_Error :: enum {
	None = 0,
	Parse_Failed,
}

/*
	An image that loaded but is not laid out the way a sky needs.

	Only the cube map can fail this way. A panorama that is not 2:1 loads
	anyway and warns, because a slightly-off ratio is a legitimate crop --
	whereas a cross that is not four cells by three cannot be sliced into six
	faces at all.
*/
Skybox_Error :: enum {
	None = 0,
	Not_A_Cross,
}

/*
	The arguments did not describe something that could be built.

	These sit at the public boundary, where a size or a pixel count may have
	come out of a file the player chose or a buffer the game filled in, so they
	are answerable rather than fatal.
*/
Argument_Error :: enum {
	None = 0,
	Empty_Size,        // a width or height of zero or less
	Not_Enough_Pixels, // fewer bytes than width * height * 4
	No_Geometry,       // a mesh with no vertices, or no indices
	No_Frames,         // an animation with no frames to pack into a sheet
}

/*
	A source handed to `create_environment_probe` (ambient.odin) that cannot
	be baked. Only one way to fail: the source has to be a `Skybox` already
	loaded as a `.CUBEMAP` (`load_skybox_cubemap`) -- see that procedure's own
	doc comment for why a `.PANORAMA` source is out of scope rather than
	converted on the fly.
*/
Environment_Probe_Error :: enum {
	None = 0,
	Source_Not_Cubemap,
}

Error :: union #shared_nil {
	Gpu_Error,
	Image_Error,
	Argument_Error,
	File_Error,
	Model_Error,
	Skybox_Error,
	Environment_Probe_Error,
}
