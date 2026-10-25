# Matchbox (Full Rewrite)

Matchbox is a graphics framework making games for PC and 3DS using a custom unified API and the Odin programing language.

PC Backend: `DirectX 11 (D3D11)`

3DS Backend: `O3DX`

## Unified API

In order to develop for both targets the way I want to, I need to create a unified API. This is a a series of procedures,
structs, enums, etc, that will compile to both PC and the 3DS.

For example `matchbox.draw_sprite(...)` -> should call 3D311 on PC to handle it, but should call `Citro2D....` when compiling to the 3DS

As this is still in very early stages of development the implementation details are still being worked out.




## Milestones

There are goals that need to be hit before the 2D can be completed; and these milesstones will be to track those

|Milestone|Hit|Status|
|---------|---|------|
|Triangle | ~ | WIP - Can render one triangle, but need to render multiple to properly test proc|
|Textured Quad | - | Not started yet|

As 2D is easier than 3D the first milestone will be for Matchbox to be able to compile 2D games PC

## Second Milestone: 3DS Backend Working (2D)

After PC is working the next milstone will be to connect it to the 03DX for 3DS support

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

## Why 3DS

I spent good money on my `New 3DS LL`

I spent a lot of my Claude tokens writting bindings for `Cirtro2D`, `Citro3D`, `Citru` to show that Odin can run on a 3DS.

I spent a good amount of my personal time modding my 3DS to run homebrew.

I will be using it somewhere, somehow.

But also - I want to be able to make games and have them run on the 3DS.

## How and Why Linux Support Works the way it does

TLDR: Wine/Proton

I do develop a lot on linux and the experience is great compared to windows, but on windows things just tend to work.
On Linux, I have to install a bunch of dependencies, and getting those dependencies can change based on the DE, the package manager, etc.
There's a thousand different Compositors/Display Protocols (Wayland/X11/Xlibre/etc).
Things break all the time on DEs between upgrades and such.

I don't want to worry about those things. Since I mainly game on windows, Matchbox's PC target is windows.
As such, I am taking the `Win32 is the only stable ABI for linux` approach: (https://blog.hiler.eu/win32-the-only-stable-abi/)

Compatability layers like Wine and Proton should be able to handle the exectuables produced by Matchbox.

## History

Matchbox was previously written fully by AI (Claude) guided by my direction. While development went smoothly,
due to it being a fully AI coded project; there were issues that kept developing I could not solve or random gaps I wasn't expecting
  - Window resizing not working correctly
  - Lighting Issues
  - Etc

In addition; the original goal for Matchbox was to make games and build the framework as that goes on; adding features as needed.
This goal was lost and I kept adding things I might need, but never did. This caused the framework to blow way past the scope I intended for it.

It was very easy to add things with AI; but I learned that it wasn't smart to just do that. Proper thought and care was needed into this API that
it wasn't getting anymore

This rewrite aims to correct the mistakes I made with the previously by having no AI generated code.
Claude will be used to help research information as needed; as graphics programming is a broad topic with limited resources that are good, but won't be generating any code in this rewrite.
This will help keep the coding style stay consistent; and allow me to learn and understand what is happening underneath the hood;
The only exception, is refactoring code. Should my coding style or conventions change throughout development; Claude will be used to due large scale refactoring.

Matchbox has had two different graphics api backends in the past, with D3D11 being the third one it will use.

The first was no_gfx_api: https://github.com/leotmp/no_gfx_api
  - This is a very easy graphics api to use when compared to things like Vulakn, D3D12, Metal, OpenGL, WGPU, etc
  - However; there is a driver support problem on Intel ARC graphics cards not supporting one of the vulkan extensions it uses
  - As such I moved away from this as this created a problem when sharing my games with friends who have that GPU

The second and the one it currenlty uses is SDL3_GPU: https://github.com/libsdl-org/SDL
  - Another great graphics api; albiet more complicated than no_gfx_api
  - This is what Claude built Matchbox on
  - While fantastic; especially for porting to Android; it wasn't my cup of tea.
    - SDL3 requires shipping a .dll or a .so file with the executable; and while that may seem like an easy thing; I want as little dependencies as possible.
      And carrying around a library the executable needs wasn't my style. Having to juggle two made it worse. I want to run the application executable and have it work.

It's for these reasons I am rewriting Matchbox's PC graphics api to D3D11
