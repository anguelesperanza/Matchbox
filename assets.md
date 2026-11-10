# How Assets Work

This document exmplains how assets work for Matchbox.
It's important to remember that since Matchbox targets multiple systems
the asset system was designed to make sharing assets among targets easy, but also flexible


# The Structure

The project's asset folder should be structed like this (example uses PC and 3DS as an example):

assets
  images
  audio
  pc
    images
    audio
  3ds
    images
    audio


`assets` holds all of the assets

`assets/images` holds all of the images for every target. Any image placed in here will render on the backend being built

`assets/images` holds all of the audio for every target. Any audio placed in here will play on the backend being built

`assets/pc/...` The pc folder will only load assets for the pc target

`assets/3ds/...` The 3ds folder will only load assets for the 3ds target

The `assets/pc/...` and `aasets/3ds/...` folders are useful if you need to have two varietions of the same file but for
different targets. For example: a higher resolution image on PC but a lower resolution image on 3DS.

You can either place the higher resolution on in the shared `assets/images` folder, or place it in the pc specific
`assets/pc/images/` and the lower resolution image in the `assets/3ds/images` folder and the build pipeline will pick
those up

The assset pipeline is structured this way to help prevent duplicate files, while also allowing for target specific files.


# How the asset pipeline finds files

Whether using `farlite` or the `build.bat [target]` file, both approaches work the same way.

The build pipeline will forst check the shared assets folders `assets/images/` and `assets/audio/` and build the assets
based on what's in there.

The pipeline will then check the target specific folder. If a file is present in there, it will run the build step
for that file the same as it would for the 3DS.

Files that should be replaced between targets should be named the same

For example:

Let's say we have an image `meme.png` that is 500x500. On PC that should be fine, but on 3DS that will be too much.
So we shring `meme.png` down to 32x32 so it works better on the 3DS.

The asset setup for this would look like either of two (both are correct approaches):

Approach 1
````
assets
  images
    meme.png => 500x500
  pc
    images
  3ds
    images
      meme.png => 32x32
````

Approach 2

````
assets
  images
  pc
    images
      meme.png => 500x500
  3ds
    images
      meme.png => 32x32
  
````

Notice how approach one puts `meme.png` in `aasets/images/` and approach two puts `meme.png` in `assets/pc/images/`
Both work as the build pipeline will start with the shared assets folder, then work it's way through the target specific folders


# How to load assets

Given the above approach to loading assets, to load an asset you just need to provide the filename for the asset you want to load,
and the call the correct procedure to load it.

Using sprites as an example

`mb.create_sprite("meme.png")` => Matchbox will take care of finding `meme.png` inside of the asset folders and grab the proper asset
