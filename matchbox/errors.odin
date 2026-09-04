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
	Decode_Failed,
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
	Wrong_Pixel_Count, // an update that does not match the buffer it is for
	No_Geometry,       // a mesh with no vertices, or no indices
}

Error :: union #shared_nil {
	Gpu_Error,
	Image_Error,
	Argument_Error,
}
