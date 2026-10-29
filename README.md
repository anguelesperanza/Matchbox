# Matchbox (Full Rewrite)

Matchbox is a graphics framework for making games for PC and 3DS using a custom unified/shared API and the Odin programing language.

PC Backend: `DirectX 11 (D3D11)`

3DS Backend: `O3DX`

## Unified API

In order to develop for both targets the way I want to, I need to create a unified API. This is a a series of procedures,
structs, enums, etc, that will compile to both PC and the 3DS.

For example `matchbox.draw_sprite(...)` -> should call 3D311 on PC to handle it, but should call `Citro2D....` when compiling to the 3DS

As this is still in very early stages of development the implementation details are still being worked out.

However, the implementation is strongly referencing the existing Matchbox API that exists on main.
Some changes may be made as I see fit; some proc names may stay the same -- the implementations however
will be different due to the different backends and the D3D11 backend this rewrite does over the SDL3/SDL3_GPU
backend main uses

## Milestones

Before Matchbox is considered `complete` there are a series of milestones that need to be hit. These milestones are
constantly changing until a good path is made for it but loosly, there are the milestones

[x] POC -> Proof of concept that the Matchbox API can compile to both PC and the 3DS

[ ] 2D  -> 2D is the first target for this and where the initial large bulk of work will be done

[ ] 3D  -> 3D is the last big milestone
- This is by far the one with the most effort.
- O3DX Bindings for 3D need to be touched up and any gaps in the bindings need to be filled

Current In-Progress Milestone: `2D`

The POC worked and the API does act as intended. However I need to address issues found during the POC
in regards to API design -- as what was used for the POC simply will not do for the 2D milestone. The PC backend also needs
2D implmentation added as well. O3DX has Ctru2D bindings so no heavy implementation there; just procedure calls

I need to hammer out excatly what the 2D implementation will entail in terms of graphics.

Gamepad support needs to be added here; audio support; file system interactions; figure out how to handle the
3DS' second screen, etc. Lots of work to do here in terms of figuring all that out.

## Why DirectX 11 (D3D11)

While D3D11 is an old graphics API; it's not as complicated as D3D12 or Vulkan. As I do not know how to graphics program,
the options I felt comfortable picking where:
  - D3D11
  - OpenGL
  - WGPU

While I do have the most experience with WGPU (see: https://github.com/anguelesperanza/Odin-wgpu-win32-learnings), it breaks with every update. This does not
make it ideal for learning graphics programing.

More than an graphics API with modern features, I care more about a graphics API that's stable. As such, WGPU was out of the question.

OpenGL was a good candiate and it has the most documentation that's easily accessible and readable for beginners.
However, my primary PC target is Windows not Linux and outside of documentation (which is a good reason), I don't see a reason to use OpenGL over D3D11.

D3D11 was picked as it makes the most sense to me.
  - I develop on windows mainly
  - Can target linux through Wine/Proton
  - The API is not as complex as OpenGL (so I've heard)

I have thought of over graphics frameworks but decided against them. `Sokol` was one I chose, but I wasn't a fan of the api.
SDL3_GPU is not on the table -- Matchbox is currenlty written in SDL3_GPU and I want to move away from SDL3_GPU
no_gfx_api is also not on the table -- Matchbox was originally written in no_gfx_api however due to some vuklan extensions it uses,
it doesn't work on certain Intel Arc Cards who don't support those vulkan exentions

## Why 3DS

I spent good money on my `New 3DS LL`

I spent a lot of my Claude tokens writting bindings for `Cirtro2D`, `Citro3D`, `Citru` to show that Odin can run on a 3DS.

I spent a good amount of my personal time modding my 3DS to run homebrew.

I will be using it somewhere, somehow.

But also - I want to be able to make games and have them run on the 3DS.

## How and Why Linux Support Works the way it does

TLDR: Wine/Proton

I do develop a lot on linux and the experience is great compared to windows, but on windows things just tend to work with less headache.
On Linux, I have to install a bunch of dependencies, and getting those dependencies can change based on the DE, the package manager, etc.
There's a thousand different Compositors/Display Protocols (Wayland/X11/Xlibre/etc).
Things break all the time on DEs between upgrades and such.

I don't want to worry about those things. Since I mainly game on windows, Matchbox's PC target is windows.
As such, I am taking the `Win32 is the only stable ABI for linux` approach: (https://blog.hiler.eu/win32-the-only-stable-abi/)

Compatability layers like Wine and Proton should be able to handle the exectuables produced by Matchbox.

## History

Matchbox has gone throug a bunch of itterations, some AI generated, some hand written, some both, none none more complete the the most
recent iteration:

Matchbox was previously written fully by AI (Claude) guided by my direction. While development went smoothly,
due to it being a fully AI coded project; there were issues that kept developing I could not solve or random gaps I wasn't expecting
  - Window resizing not working correctly
  - Lighting Issues
  - Etc

In addition; the original goal for Matchbox was to make games and build the framework as that goes on; adding features as needed.
This goal was lost and I kept adding things I might need, but never did. This caused the framework to blow way past the scope I intended for it.

It was very easy to add things with AI; but I learned that it wasn't smart to just do that. Proper thought and care was needed when developing the API,
but I offloaded all of that to the AI -- this created a maintanence issue that became more effort than it was worth.

I archived it a little bit but decided to unarchive it and give it another shot; this time, with clear goals in mind.

This rewrite aims to correct the mistakes I made with the previously by having no AI generated code.
Claude will be used to help research information as needed and guide me where possible; as graphics programming a complicated topic with limited resources that are good.

The AI won't be generating any code in this rewrite.

This will help keep the coding style stay consistent and allow me to learn and understand what is happening underneath the hood.
This should reduce maintanence issues.

The only exception, is refactoring code. Should my coding style or conventions change throughout development, Claude will be used to due large scale refactoring.

Matchbox has had two different graphics api backends in the past, with D3D11 being the third one it will use.

The first was no_gfx_api: https://github.com/leotmp/no_gfx_api
  - This is a very easy graphics api to use when compared to things like Vulakn, D3D12, Metal, OpenGL, WGPU, etc
  - However, there is a driver support problem on Intel ARC graphics cards not supporting one of the vulkan extensions it uses
  - As such I moved away from it as this created a problem when sharing my games with friends who have that GPU

The second and the one it currenlty uses is SDL3_GPU: https://github.com/libsdl-org/SDL
  - Another great graphics api; albiet more complicated than no_gfx_api
  - This is what Claude built Matchbox on
  - While fantastic; especially for porting to Android; it wasn't my cup of tea.
    - SDL3 requires shipping a .dll or a .so file with the executable; and while that may seem like an easy thing, I want as little dependencies as possible.
    - Compling the SDL3 .so file ended up being a challenge due to having to find the right version, and build it without it crashing.

It's for these reasons I am rewriting Matchbox.


# Inspiration

Matchbox is heavily inspired by Raylib. I really enjoy just how easy it is to get things going in Raylib.
And while I have tried other options, I always end up coming back to raylib because of how simple it is.

XNA was another big inspiration. I have fond memories of playing around in the XNA examples and being astounded
by what others did with it on YouTube.

Another two inspirations are Kha and HaxeFlixel.
I would often bounce around between Kha and HaxeFlixel before discovering Raylib. Both were nice to use and before raylib
where my go to game frameworks for game development.


Raylib: https://www.raylib.com/

XNA: https://github.com/FNA-XNA/FNA (XNA itself is gone and has been for years, but is spritually succeeded b FNA)

Kha: https://github.com/Kode/Kha | https://kha.tech/

HaxeFlixel: https://haxeflixel.com/
