# Improvements

This file lists improvents I can make to Matchbox that I discovered while trying to create things.
These things might not have been finished and that's fine, what matters is that I discovered these
areas of improvement while trying to create them.

---

# Not Started

# Frame Rate Independent
Matchbox is currenlty framerate depended; need to look into making it frame rate independed if possible
as game slows down at lower framerates -- not ideal if as affects gameplay is framerate is locked at lower
fps for perfamnce reasons

# create_first_person_camera argument change
facing should be an enum `Facing_Direction` that has either `FORWARD`, `BACKWARD`.
The match should be calcuated inside the function based on whether `.FORWARD` or `.BACKWARD` is called


# the escape to regain mouse control + escape to leave
Make that it's own proc to prevent typing it over and over

## Light Range Values
Add a way to teak the range of the light

## Model Forward Procedure(s)
Add procedure to get the forward facing direction of a model

## A Hit Test That Knows About The Clip

Found converting the card game's deck builder from paging to Scroll_View, which
is the first thing to use a clip for what it was added for.

`is_mouse_over_rect` asks whether the pointer is inside a rectangle and nothing
else. Inside a scrolling panel that is the wrong question: a row scrolled past
the bottom edge is cut out of the picture by the scissor and still answers the
mouse, because the scissor is a drawing state and the hit test never looks at
it.

What that cost the game: the deck panel's Empty button sits in the panel's foot,
below the scroll area. With the list scrolled, a content row lands underneath
that button -- invisible, and still hit-testable -- so pressing Empty also
pressed the `-` of whatever row happened to be there. Same shape as clicking
through an open dropdown, which `is_mouse_captured` already solves, and the same
answer is wanted here.

The game works around it by testing the panel as well as the row:

	inside := matchbox.is_mouse_over_rect(area) && !matchbox.is_mouse_captured()
	...
	over := inside && matchbox.is_mouse_over_rect(spot)

That is correct and it is a rule every caller has to know, which is what makes
it worth moving. Two shapes suggest themselves:

  - `is_mouse_over_rect` intersects against the current clip stack, so it is
    right by default and nobody has to be told. Anything wanting the old
    behaviour can still call `is_point_in_rect` with `get_mouse_position()`.
  - or `scroll_contains(view, rect)` for the narrower case, which leaves
    `is_mouse_over_rect` alone.

The first is the one that stops this being discovered again. `apply_clip`
already keeps the current rectangle, so the test has something to ask.

Worth checking `hover_dwell` at the same time -- it has the same problem for the
same reason, and the game resets the dwell state by hand for exactly that.


## Batching Quads Into One Draw

**Not a requirement at this time.** Written down with its numbers so the case can
be re-read rather than re-argued, and so the next person to notice "there is no
batching" finds out what it is worth before spending a week on it.

Every quad is its own draw call with its own vertex uniform push. Redundant binds
were removed separately -- the renderer's bind cache means a run of identical
draws describes its pipeline and buffers once -- and what is left is one
PushGPUVertexUniformData and one DrawGPUIndexedPrimitives per quad, at about
0.16 us each.

### What it would take

Per-quad data has to stop being a uniform block and become a per-instance vertex
buffer: a second buffer on slot 1 at `input_rate = .INSTANCE` carrying position,
size, uv bounds, rotation and colour, plus whatever each fragment shader needs on
top -- the outline's per-axis border, the shape's three corners and kind and
thickness, the sprite's desaturate. That is one instance format wide enough for
all of them, around eighty bytes, and **all five fragment shaders rewritten** to
read interpolators instead of a cbuffer.

Then a flush discipline: accumulate while the pipeline and texture are unchanged,
flush when either changes or the frame ends. Draw order survives that, because a
flush happens exactly when the state that would have differed changes.

### The trap in it

`begin_clip` and `end_clip` change the scissor part-way through a frame, and the
scissor is pass state, not per-draw state. A batch spanning a clip change would
draw every quad in it under whichever scissor happened to be set when the batch
was flushed. So `apply_clip` has to flush first, and so does anything else that
ends a pass -- `pixel_buffer_update` does. Get that wrong and it does not fail
loudly: it looks like "the scroll panel sometimes does not clip", found weeks
later.

### Why it is not needed yet

Measured on this machine, 120 frames a point, drawing nothing but rects:

	  rects   submit ms   frame ms   us/rect
	    256       0.030      8.333     0.118
	   1024       0.148      8.332     0.144
	   2048       0.266      8.335     0.130
	   8192       1.107      8.545     0.135
	  32768       4.251      9.953     0.130
	 131072      18.460     18.683     0.141

Two things to read off that. The cost is **linear** -- there is no knee, it is
pure per-call overhead, so nothing pathological is waiting further up. And frame
time sits at 8.333 ms, which is this display's vsync, all the way to eight
thousand quads: the GPU is not the bottleneck at any count that matters, and
submission only *becomes* the frame past about thirty thousand quads at 120 Hz,
or seventy thousand at 60 Hz.

Against that, the worst real case in hand -- a full Chip-8 screen, 2048 rects --
is 0.27 ms, which is **four percent of a frame**. Five thousand glyphs of text is
0.32 ms. Neither is close.

So the honest position is that this is an architecture improvement rather than a
performance fix, and it is worth doing when something actually asks for tens of
thousands of quads a frame -- a particle system, a tile map drawn per-tile
without a spritesheet, a text editor rendering a whole file. None of those exist
yet.

## Android -- It Runs

examples\ui runs on a phone, and so does a real game outside this repository:
SDL_GPU on Vulkan, stb_truetype text, a sprite read out of the apk, and buttons
that answer a finger. All fifteen examples build, TankMovement included.

	matchbox\android.bat                  cross-compile stb, once per copy
	matchbox\android_sdl.bat              fetch libSDL3.so + Java, once ditto
	matchbox\android_apk.bat              build the project matchbox sits in
	matchbox\android_apk.bat examples\ui  build something else, by path

Three layers were supposed to be in the way. One was a compiler bug and is
worked around, one was a download, and the third -- the one this file said to
settle first -- turned out not to exist. Then four things that were not on the
list at all had to be fixed, and every one of them built cleanly first.

### Layer 3 dissolved, and it was the important one

The question was whether SDL3 could run under Odin's NativeActivity subtarget.
Nothing has to be reconciled: stock SDLActivity, unsubclassed, straight out of
the release's classes.jar, does this:

	getLibraries()         {"SDL3", "main"}   loads libSDL3.so, then libmain.so
	getMainSharedObject()  "libmain.so"       the last of those
	getMainFunction()      "SDL_main"         dlsym'd out of it and called

So all that is needed is a symbol named `SDL_main`. No Java of ours is compiled,
there is no Gradle project, and no example knows it is being built for Android.
The reason `odin bundle android` is not used, incidentally, is that it runs aapt
over a manifest, `res`, `assets` and `lib` and never produces a `classes.dex` --
it is a packager for exactly the NativeActivity app Odin assumes, and cannot
express an app whose entry point is Java. android_apk.bat drives the same
build-tools by hand and adds the dex.

### Layer 1 is still a compiler bug, and still patched outside this repo

`linker.cpp:651`: a foreign import whose name ends in `.a`, `.o` or `.so` becomes
`-l:"<absolute path>"`, and lld's `-l:name` searches the `-L` directories for
that literal *filename*, which an absolute path can never match. Two branches
above, Darwin gets it right -- there a `.a` is passed as an ordinary input file.
That is the fix worth sending upstream.

The workaround is three one-line edits in the Odin installation, gating
vendor:stb's `LIB` so Android falls through to the `system:` form already written
underneath it:

	LIB :: (
	         ""                          when ODIN_PLATFORM_SUBTARGET == .Android
	    else "../lib/stb_image.lib"      when ODIN_OS == .Windows
	    ...

in `vendor/stb/image`, `vendor/stb/truetype` and `vendor/stb/rect_pack` --
truetype imports rect_pack, so it comes along. That emits a plain `-lstb_image`,
which resolves against `matchbox\android\libs\libstb_image.a`, which is why
android.bat writes the `lib` prefix. Desktop builds cannot be affected: the gate
is on the subtarget, not the OS.

**This is the one thing a fresh machine still needs done by hand**, and an Odin
upgrade undoes it.

### Layer 2 was a download, as expected

android_sdl.bat reads MAJOR/MINOR/MICRO out of vendor:sdl3's own
`sdl3_version.odin` and fetches that release's android zip, so the arm64
libSDL3.so cannot drift from the bindings the way the desktop SDL3.dll quietly
did for months. Same argument as copy_sdl.bat, same reason.

### The four that built cleanly and failed anyway

This is the part worth keeping, because not one of them produced a compiler
error, a linker error, or a failed install.

**1. `main` is a stub in a shared library, and aliasing to it looks like it
works.** The first entry point was one linker flag, `--defsym=SDL_main=main`, on
the reasoning that Odin already emits a `main(argc, argv)` which starts the
runtime and calls yours. It does -- for executables. In `-build-mode:shared`
that same `main` is:

	main:  mov w0, wzr    ; return 0
	       ret

and the alias is real, exported, and points at nothing. The app installed,
launched, and left two lines in the log one millisecond apart:

	V SDL: Running main function SDL_main from library .../libmain.so
	V SDL: Finished main function

What actually starts an Odin shared library is `_odin_entry_point`, which Odin
generates for `ODIN_BUILD_MODE == .Dynamic` and which does the context setup,
`__$startup_runtime`, and the call to your `main`; teardown is
`_odin_exit_point`, already in `.fini_array`. `matchbox/android.odin` now defines
a real `SDL_main` that defers to it, so the build script has no magic flag left
and the knowledge sits next to an explanation of itself.

**2. An unused glue is still a linked glue.** `-subtarget:android` always
compiles `android_native_app_glue.c` in and forces `ANativeActivity_onCreate`,
and the glue references `android_main`. Nothing provided it. A shared library may
link with undefined symbols, so the build said nothing -- and Android resolves
every symbol when a library is *loaded* rather than on first call:

	dlopen failed: cannot locate symbol "android_main"

in a dialog at launch. `matchbox/android.odin` defines an empty one.

**3. Odin builds for API 34 by default, and nothing says so.** That put a
reference to `__register_atfork` in the binary -- present in API 24 and up,
absent in 21 -- while the manifest advertised `minSdkVersion 21`. An apk claiming
devices it could not load on, which survived only because the test phone is
modern. android_apk.bat now sets one `APILEVEL` and spends it four times, on
`-minimum-os-version`, `d8 --min-api`, `apksigner --min-sdk-version` and the
manifest.

**4. aapt writes the zip entry name exactly as given.** Passing
`lib\arm64-v8a\libmain.so` on Windows puts a backslash in the entry, Android does
not recognise that as a native library directory, and the apk installs and then
dies in `System.loadLibrary`. Forward slashes, always.

The general lesson, and the reason the last three were each caught in seconds
once it was applied: **on Android, "it linked" says nothing about whether it will
load.** `llvm-nm -D -u` over the .so, diffed against what libSDL3.so and the
API-level sysroot's libc/libm/libandroid/liblog actually export, answers that on
the desktop before the phone is involved at all. An empty diff is the goal.

### And one that ran, and still looked wrong

Worth its own note because nothing anywhere reported a problem. With no `theme`
on the activity, Android gives it the default one -- which has an ActionBar, and
puts the SDL window title in it. So every game started with a couple of hundred
pixels of system chrome across the top, in a colour it did not choose, and the
surface simply began underneath. It reads as "the game is drawing a title bar"
until you notice the colour survives `clear_background`.

`@android:style/Theme.NoTitleBar.Fullscreen` on the activity, which is a built-in
theme and so costs no `res` directory of our own.

### Where the build lives, and why it moved

All of this started at the repository root, which was wrong the moment a game
outside the repository wanted it: matchbox is meant to be a folder you drop into
a project, and half its Android support was sitting somewhere you could not drop.

It is all inside `matchbox\` now -- the three scripts, the manifest, the debug
key, and `android\libs` for the stb archives and libSDL3.so. Copy the folder,
get Android with it.

The argument that follows is what the default target should be, and the answer
is the directory matchbox was dropped into:

	some_game\matchbox\android_apk.bat      builds some_game

which reads correctly at the call site and needs no configuration file to say
where the project is. This repository is the awkward case rather than the normal
one -- its examples sit *beside* matchbox instead of above it -- so a path
argument overrides the default, and `matchbox\android_apk.bat examples\ui` is how
the examples are built. Output goes to the game's own `build\android`, since it
belongs to the game and not to the framework.

Two details that only show up once the framework is inside the project it builds:
matchbox has to be excluded when staging assets, or every game ships a second
copy of the fonts and shaders that are already `#load`-ed into its binary; and
the package name has to come from somewhere, which is `org.matchbox.<folder>`
unless `MATCHBOX_ANDROID_PACKAGE` says otherwise. That default is fine for a
debug build and wrong for anything published, which is worth remembering before
the first store upload rather than after.

### Getting anything out of the phone

Worth writing down separately, because it cost more time than any of the bugs.
This ZTE/nubia ROM ships with

	[log.tag]: [S]

set globally, which silences logcat completely -- not filtered, *empty*, from
`adb logcat` and from a shell on the device alike, with logd running normally.
Every diagnostic above was invisible until

	adb shell setprop log.tag V

which is not persistent and has to be redone after a reboot. Before that the only
signals available were `pidof` and a screenshot, which is how the first failure
got narrowed down at all: the process existed, held 137MB, and had accumulated
0.17 seconds of CPU, which is not what a running game looks like.

### What is known to work, and what is next

Verified on the device, by screenshot and by tapping it:

	SDL_GPU on Vulkan     the whole UI example renders
	stb_truetype          text, from the embedded default font
	stb_image + assets    art\ember.png read back as "art/ember.png" out of the
	                      apk, through read_entire_file and SDL's IOStream
	touch                 a tap on a button incremented its counter, so SDL's
	                      finger-to-mouse synthesis reaches the hit testing
	a real game           ClickCoin, which lives outside this repository and
	                      knows nothing about Android: tapping the coin moved it
	                      and took the counter from 0 to 1

Not yet looked at: audio, gamepads, and what happens on pause and resume when the
surface is destroyed and recreated -- which is the one that tends to matter,
since a GPU device outliving its window is exactly what Android does to a game
when a call arrives.

The other thing a screenshot makes obvious: `init` asks for 1080x720 and Android
gives the whole screen, 1116x2480 here, so the UI example lays out for a wide
window and gets a tall one. Nothing is broken; it simply has no idea what shape
it is on. That is a display-model question rather than an Android one, and it has
its own entry below.

## Vendor Our Own Copy Of stb, Instead Of Patching Odin's Install

The layer-1 workaround documented above, under "Android -- It Runs," is three
one-line edits inside the *Odin installation itself* --
`vendor/stb/{image,truetype,rect_pack}`'s `LIB` constant, gated so Android falls
through to the `system:` form instead of emitting an unresolvable `-l:<absolute
path>`. That fix lives outside this repository, in a tree matchbox does not
control and does not version. A fresh machine has to be told to go make those
edits by hand, and an Odin upgrade overwrites the vendor tree wholesale and
silently undoes them -- the build goes back to `unable to find library
-l:C:/...` with nothing in this repo's history explaining why, until someone
remembers to redo the patch.

The real fix is upstream -- pass `.a` files as ordinary input files on Linux,
the way the Darwin branch of `linker.cpp` already does -- but matchbox does not
have to keep depending on a hand-patched toolchain until that lands.
`vendor:stb`'s three packages are plain Odin source; copying them into
matchbox's own tree and carrying the `LIB` gate there instead makes it an
ordinary vendored dependency, checked into this repository the way everything
else matchbox needs is, rather than a step a fresh machine has to be walked
through separately. A game that drops in the matchbox folder would build for
Android without anyone touching their own Odin install, and an Odin upgrade
would stop being able to regress it.

## The Window Is Either A Shape The Game Chose Or One It Was Handed

Undecided, and worth deciding once rather than per platform. Android forced the
question but did not create it: a maximised desktop window and a DeX window ask
exactly the same thing.

### What already exists

More than it looks like. `fixed_res` off means the logical size follows the
window; on means the logical size is pinned and letterboxed into it, and
`draw_scale` / `draw_offset` are already applied by `screen_pos`, `screen_size`,
the mouse conversion in `poll_events`, `get_touch_pos`, the sprite culling and
the shape path. The machinery is done and tested -- Pong uses it. What is
undecided is only which side of that switch a platform starts on, and how a game
says otherwise.

Worth noticing before inventing anything: **if the answer is "the same switch
desktop games already use", then desktop mode needs no Android branch at all.**
In DeX the window is desktop-shaped and resizable, so a fluid game behaves as it
does on a desktop and a pinned game letterboxes into it exactly as it letterboxes
into a resized desktop window. A toggle that turns out to be the existing one is
a good sign; an Android-only mode flag would be a bad one.

### Orientation is the bigger lever, and it is nearly free

The UI example looks cramped mostly because a landscape design is running in
portrait, not because letterboxing is wrong. Same math, same game, on the test
phone's 1116x2480 with `init(..., 1080, 720)`:

	portrait      scale 1.03    drawn 1116x744    30% of the height, bars above
	                                             and below
	landscape     scale 1.55    drawn 1674x1116   full height, bars at the sides

The number needed to choose is already in the `init` call -- width greater than
height means landscape. `HINT_ORIENTATIONS` ("SDL_ORIENTATIONS") is in the
bindings and would avoid editing the manifest template per game.

**To check:** whether that hint has to be set before video init or can be changed
later; whether SDL delivers an orientation change as an ordinary window resize
(if so, nothing else has to know about it); and what a foldable does across a
fold, which is the same event or a completely different one depending on the
answer.

### The four candidates

	A  follow the window    logical = physical. What happens today.
	                        No waste, native resolution, DeX free.
	                        Every fixed-layout game breaks, and init(1080, 720)
	                        becomes a pair of numbers that mean nothing there.

	B  letterbox            pin the requested size, scale and centre it.
	                        Every existing game runs unchanged and looks like the
	                        desktop; init(w,h) keeps one meaning everywhere.
	                        Costs bars, and without orientation costs that 30%.

	C  fit one axis         keep the requested width, let height fall out of the
	                        screen aspect. Fills the screen, no bars, stable unit
	                        scale. But the game gets a *variable* vertical
	                        extent, so anything bottom-anchored or vertically
	                        centred has to be written for it. A third layout
	                        contract, which no example currently speaks.

	D  density scaling      one logical pixel = a fixed physical size. Right for
	                        a text app, wrong here: the logical extent then
	                        varies per device, which is the problem being
	                        avoided.

### Leaning

**B as the Android default, with orientation taken from the same numbers.** C
opt-in later, A the explicit opt-in for responsive and desktop-mode games.

The argument is not that B looks best -- often it will not. It is about which
default can be **wrong silently**. B cannot: a game keeps the contract it already
had, and where the fit is poor there are visible bars and a decision to make. A
and C both change the size of the layout region under code that never agreed to
it, and C in particular invents a contract, which is a thing to adopt per game on
purpose rather than have imposed by a platform.

The direction of travel is also easier. B to C later is a game asking for more
screen. A to B later means finding out which games quietly broke.

### The actual gap

`set_logical_size` turns letterboxing **on** and nothing turns it **off**. So
under a letterboxing default an Android game that wants the whole screen has no
call to make. That is the real addition, and there are two shapes for it:

	follow_window()                       a second procedure, minimal
	set_presentation(.Follow/.Letterbox)  one named knob

Leaning towards the enum: it names the contracts, makes C arriving later a value
rather than a fourth procedure, and gives `fixed_res` -- currently a bool that
has to be explained every time -- a name that says what it means. The letterbox
maths underneath would not change.

### Still open

	safe areas        GetWindowSafeArea is in the bindings. Barely matters for B,
	                  since centring already keeps content off the edges. Matters
	                  a lot for C, and for anything drawn hard against a corner.
	pause / resume    the surface is destroyed and recreated when a call arrives.
	                  A correctness problem rather than a layout one, and
	                  probably the more urgent of the two.
	what DeX reports  whether it looks like an ordinary resizable window from
	                  SDL's side, which is what the "no Android branch" claim
	                  above depends on. Untested -- there is no DeX device here.
	the examples      most were written at a fixed size against a desktop window.
	                  Whichever default is chosen, it is worth knowing how many
	                  of them actually care.

## [do not do] Volumes, Which Means NanoVDB And Not OpenVDB

Parked deliberately. Asked as a theory question, answered as one, and written
down so the answer does not have to be re-derived -- not because anything here
is planned. **Do not start this.**

### OpenVDB itself is out, and that is the useful half of the answer

OpenVDB is C++: templates, TBB, Blosc, zlib, Half. Odin has no C++ ABI, so using
it means hand-writing a C shim and then cross-compiling that whole dependency
stack for every target. stb is one archive and it already costs a compiler patch
and a per-machine setup step; this would be several libraries, and arm64 builds
of all of them. That is the end of that road.

### NanoVDB is a different proposition

The ASWF's own GPU-oriented subset. A `.nvdb` grid is one flat, pointer-free,
self-contained buffer, built to be copied to a GPU and read there. Two things
follow, and they are what make this worth writing down at all:

**Nothing parses it.** `read_entire_file`, upload, done. No foreign import, no
new archive, nothing to cross-compile -- so Android would be exactly as easy as
the desktop, which is not true of any other way of getting volumes in.

**The conversion is offline.** `nanovdb_convert`, or a Houdini or Blender export,
turns `.vdb` into `.nvdb` on a workstation. The heavy C++ never ships.

### SDL3 already has the pieces

Checked in the bindings rather than assumed:

	CreateGPUComputePipeline        compute pipelines exist
	BeginGPUComputePass             and passes for them
	DispatchGPUCompute
	BindGPUFragmentStorageBuffers   read-only storage buffers, bindable to
	BindGPUComputeStorageBuffers    either stage
	GRAPHICS_STORAGE_READ           the buffer usage flags to match
	COMPUTE_STORAGE_READ

So the grid binds as a read-only storage buffer and is read from a fragment or a
compute shader. Nothing is missing at the SDL level.

### The part that fits unusually well

NanoVDB ships **PNanoVDB**, a reader header that compiles *as HLSL*. Shaders here
are already HLSL through dxc to SPIR-V and DXIL, and `lighting.hlsli` proves
includes work, so it would be `#include` and a ray-march loop. Most engines have
to port PNanoVDB to whatever dialect they use; this one would not.

### What would actually have to be built

	storage buffers      create, upload, bind. Matchbox has none -- no
	                     StorageBuffer, no ComputePipeline, nothing. This is the
	                     real new surface, and it is worth more than volumes are:
	                     it is what anything data-driven on the GPU needs.

	a compute stage      build_shaders.bat globs *.vert.hlsl and *.frag.hlsl and
	                     nothing else. A *.comp.hlsl arm with -T cs_6_0 is a few
	                     lines. Skippable at first by ray-marching in a fragment
	                     shader over a proxy box.

	depth                begin_drawing_3d owns a depth buffer already, so a proxy
	                     box depth-tests against meshes for free. Volume and
	                     geometry actually intersecting needs the depth buffer
	                     read inside the shader, which is a step past that.

### Why it is parked

Two reasons, and the second is the one that decides it.

**Size.** Production clouds run to hundreds of megabytes. That is a GPU
allocation and an apk that cannot ship. Volumes for a phone would have to be
authored small on purpose, which makes this an art-pipeline commitment and not
just a rendering one.

**Cost.** Ray-marching a sparse volume is many samples per pixel with dependent
memory reads -- the shape of effect that is fine at 1080p on a desktop GPU and
brutal on a phone. Having just made Android real, adding the one feature least
likely to run there is the wrong order.

If any of this gets picked up, **the storage buffer work is the part to do
first**, on its own merits, with volumes as a thing it might later allow.

## Remove / Reduce AI Code

While I wrote a chunk of this, so did Claude. I'd like to
reduce the AI code as I make breaking api changes,
optimazations, etc

## What URP-PSX Gets That Our PSX Shaders Do Not

Backburner, not a task -- a comparison against a Unity URP project
(`URP-PSX`, MIT-licensed) I was asked to look at for its PSX shaders,
written down so the answer does not have to be re-derived if the itch
comes back. Three of its four techniques are already beaten by what is
here, ported from an actual PSX game rather than a generic asset:

	Dithering.shader    1-bit threshold dither (full colour or black
	                    against a pattern matrix). psx.frag.hlsl already
	                    does real ordered dithering *before* 5-bit-per-
	                    channel quantization, which is the PS1's own
	                    order of operations and a strictly finer effect.
	Pixelation.shader   grid-snap plus colour-precision floor, nothing
	                    else. psx.frag.hlsl already does both of those
	                    and adds cell-centred sampling and scanlines.
	DitheringPatterns
	  .cginc            the same threshold matrices as the shader above,
	                    factored out. Artistic patterns, not the
	                    hardware-accurate Bayer matrix already in use.

**Fog.shader is the one real gap.** It is a depth-buffer post-process
(exponential falloff) with Perlin/Voronoi noise perturbing the fog's
edge, so the transition breaks into noise instead of a clean gradient.
`lighting.hlsli`'s fog (`apply_lighting`, the `flags.y` branch) is a
plain linear lerp by distance, computed inline during shading rather
than as a separate pass -- no noise, no breakup.

Adopting *their* approach is not the move: it needs a depth texture
bound to a post-process pass, which is new plumbing Matchbox does not
have (`post.frag.hlsl` samples colour only). The cheaper route is to
perturb the existing fog factor in place -- world position is already
in hand in `apply_lighting`, so a small noise term added to `factor`
before the `lerp` would get the same visual break-up with no new
resource bindings, no depth texture, and no second fog system living
alongside the first.

Not started because nothing has asked for it yet. If a game's fog reads
as too clean, this is where to start, and the noise function does not
need porting from `voronoi.cginc` either -- it is a generic Perlin/
Voronoi implementation with no PSX-specific content, the same category
`CustomLighting.hlsl` turned out to be (a thin wrapper over Unity URP's
own `GetMainLight`/`LightingLambert`/`LightingSpecular`, nothing
PS1-specific in it at all, and already matched, constant for constant,
by `lighting.hlsli`'s own lighting model).

## Reduce System Usage

Basic Init Window example uses about 53mb of ram.
Need to compare to other frameworks to see if that's a lot?

Not started, but one thing did turn up while testing the font cache with a
tracking allocator: a whole start-and-stop leaked exactly one allocation, the
five bytes of the window title, which `init` cloned to a cstring and handed to
SDL_CreateWindow without ever giving back. SDL copies the title, so it was ours
to free. Fixed, and worth writing down mostly for the method -- a tracking
allocator around `init` / `cleanup` is a two minute test and it now comes back
clean, which makes the next leak easy to see. 53mb is not made of that sort of
thing, though; the atlases and textures are where to look.

## Lighting And Shadows Need A Ground-Up Rework

Found in the horror game: a scene with a ceiling light (directional,
`casts_shadow = true`, always on) and a flashlight (spot, `casts_shadow =
true`, toggled by a key). Take the ceiling light out -- no windows, no need
for a sun -- and leave just the flashlight, and two things that are supposed
to be independent switches turn out not to be.

`set_lights` with zero lights is what puts the fixed fallback shading back
(`Light.odin`'s own `flags.x` doc comment), not a dark scene -- that is
deliberate, and correct on its own. But with no always-on light to fall back
to, whether the *real* lighting model runs at all now depends entirely on
whether the flashlight happens to be on this frame: off, the light list is
empty and the scene is flat-lit; on, it is not. And separately, whether
`begin_shadow_pass` opens a real pass depends on `recompute_shadow_casters`
finding *something* marked `casts_shadow` in whatever the current light list
is -- so with the flashlight as the only candidate, turning it off does not
just remove its own light, it also happens to be the thing that turns the
whole shadow system's practical effect off, even though `enable_shadows` was
never touched and thinks it is still on.

Neither of these is a bug in the sense of doing the wrong thing -- every
piece is behaving exactly as documented in isolation. What is missing is a
scene-level story for what "the lighting is on" and "shadows are on" mean
when the only light around is one a player can toggle, rather than always
being true of some fixed light the game can rely on.

That is one symptom of a bigger shape problem, not the whole of it. Lighting
and shadows grew the way most things here start -- one light, then a second
kind, then shadows for one caster, then two -- and each step was the right
size change for what it was solving at the time. What is missing is a design
that was ever asked to hold all of it at once: what "on" means when the light
list can be empty, how a caster is chosen, how many can cast real shadows
together, are all answers a `Lighting_Data` cbuffer and a couple of Odin procs
ended up giving by accident rather than ones a scene actually gets to state.
And none of it exists for 2D at all right now -- `draw_sprite` has no opinion
on any of this, so a 2D game that wants a lit scene, or even just a shadow
under a sprite, has nothing here to reach for. Worth rebuilding lighting and
shadows from the ground up rather than continuing to patch the 3D-only,
grown-by-accretion version: one cohesive model that states plainly what "lit"
and "shadowed" mean regardless of which lights happen to be in the list this
frame, and that 2D can opt into the same way 3D does now.

---

