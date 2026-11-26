# tritex

**tritex** is a drop-in replacement for the `tex3ds` tool from devkitPro.
It converts PNG / JPEG images to `.t3x` texture files compatible with libcitro3d and citro2d.

Build it once with Odin, then drop `tritex.exe` wherever your project expects it.

This was built due to a bug I encounted while using ImageMagik on Windows that prevented me from using `tex3ds`

This tool was auto generated using AI during an experment to see how AI can be used in larger projects.
Not all `tex3ds` features are available at this time, but the main loading single images and spritesheet features are.
Other features are planned as tool is stress tested and bugs are hammered out.

---

## Building

```bat
odin build tools/tritex.odin -file -out:tritex.exe
```

Or from inside the `tools/` directory:

```bat
odin build tritex.odin -file -out:tritex.exe
```

Copy the resulting `tritex.exe` to any directory on your `PATH` (e.g. `C:\Users\<you>\odin-projects\3dsLib\tools\`).

---

## Usage

### Single image → .t3x

```bat
tritex input.png output.t3x
tritex -o output.t3x input.png
tritex -o output.t3x -f rgba8 -z none input.png
```

### Texture atlas (multiple sprites → one .t3x)

```bat
tritex -a -o atlas.t3x sprite1.png sprite2.png sprite3.png
```

Sub-texture indices match input order: `sprite1` = index 0, `sprite2` = index 1, etc.
Use `C2D_SpriteSheetGetImage(sheet, N)` to retrieve them at runtime.

### Using a .t3s options file (same format as tex3ds)

```bat
tritex -a -o atlas.t3x -i sprites.t3s
```

**sprites.t3s**
```
# tritex options file
-f rgba8
-z none
sprites/player.png
sprites/enemy.png
sprites/bullet.png
```

- Lines starting with `#` are comments.
- Flags (`-f`, `-z`, etc.) are accepted and forwarded; currently only RGBA8 / no-compression output is produced regardless of format/compression flags (full format support is planned).
- Filenames are resolved relative to the `.t3s` file's directory.
- Quoted paths (`"path with spaces/foo.png"`) are supported.

The `-i` flag can be combined with additional positional arguments:

```bat
tritex -a -o atlas.t3x -i base.t3s extra1.png extra2.png
```

---

## Flags reference

| Flag | Long form | Description |
|------|-----------|-------------|
| `-a` | `--atlas` | Pack all inputs into one texture atlas |
| `-o` | `--output` | Output `.t3x` filename |
| `-i` | `--include` | Read options/inputs from a `.t3s` file |
| `-f` | `--format` | Texture format (accepted; RGBA8 always output) |
| `-z` | `--compress` | Compression (accepted; uncompressed always output) |
| `-m` | `--mipmap` | Mipmap filter (accepted, ignored) |
| `-d` | `--depends` | Dependency file output (accepted, ignored) |
| `-H` | `--header` | C header output (accepted, ignored) |
| `-p` | `--preview` | Preview PNG output (accepted, ignored) |
| `-q` | `--quality` | ETC1 quality (accepted, ignored) |
| `-r` | `--raw` | Raw output (accepted, ignored) |
| `-t` | `--trim` | Trim whitespace (accepted, ignored) |
| `-h` | `--help` | Show help |
| `-v` | `--version` | Show version |

---

## .t3x format notes

- **No magic bytes** — the file begins directly with the 5-byte header.
- **Header**: `u16 numSubTextures`, `u8 textureParams`, `u8 format`, `u8 mipmapLevels`.
- **Sub-texture entries**: 12 bytes each — `u16 width`, `u16 height`, then four `u16` UV coords × 1024.
- **Pixel data**: 1-byte compression type (`0x00` = none), 3-byte uncompressed size (LE), then RGBA8 pixels Morton-swizzled in 8×8 tiles with a Y-flip.
- Canvas dimensions are always powers of two (min 8), max 1024 × 1024.

---

## Using tritex in build.bat

Set `TRITEX` to the path of your compiled executable:

```bat
set TRITEX=C:\Users\<you>\odin-projects\3dsLib\tools\tritex.exe
```

Single images:

```bat
for %%f in (png_images\*.png) do (
    "%TRITEX%" "%%f" "romfs\%%~nf.t3x"
    if errorlevel 1 goto :fail
)
```

Atlas from a .t3s file:

```bat
"%TRITEX%" -a -o "romfs\gfx\sprites.t3x" -i "gfx\sprites.t3s"
if errorlevel 1 goto :fail
```

---

## Differences from tex3ds

| Feature | tex3ds | tritex |
|---------|--------|--------|
| RGBA8 output | ✅ | ✅ |
| Other formats (RGB8, RGB565, etc.) | ✅ | Accepted, RGBA8 produced |
| Compression (LZ11, RLE, etc.) | ✅ | Accepted, uncompressed produced |
| Texture atlas (`-a`) | ✅ | ✅ |
| `.t3s` include files (`-i`) | ✅ | ✅ |
| Multiple input files | ✅ | ✅ |
| C header output (`-H`) | ✅ | Flag accepted, no file written |
| Dependency file (`-d`) | ✅ | Flag accepted, no file written |
| Mipmaps | ✅ | Not supported |
| ETC1 / ETC1A4 | ✅ | Not supported |
| Cubemaps / skyboxes | ✅ | Not supported |
| Windows / Linux / macOS | ✅ | Build with Odin for your host |


---

# sheetpack

**sheetpack** packs a folder of same-sized frame images into one sprite sheet and writes the `.meta` file
that Matchbox reads (pixels per unit, columns, rows). It can also write smaller sheets for the 3DS and the Vita
with the same grid, so a frame number means the same frame on every target.

## Building

```bat
odin build tools/sheetpack.odin -file -out:tools/sheetpack.exe -o:speed
```

## Usage

```bat
sheetpack -o assets/images/shia.png -ppu 256 -3ds assets/3ds/images/shia.png -3ds-frame 64 -list path\to\frames
```

| Option | Description |
|--------|-------------|
| `-o file.png` | PC sheet to write (required). `file.meta` is written next to it |
| `-ppu N` | Image pixels per world unit, written to the `.meta` (default 1) |
| `-columns N` | Frames per row (default: `ceil(sqrt(frames))`) |
| `-3ds file.png` | Also write a 3DS sheet. Needs `-3ds-frame` |
| `-3ds-frame N` | Height in pixels of one frame on the 3DS. The 3DS `.meta` gets `ppu` scaled by the same ratio |
| `-vita file.png` | Also write a Vita sheet. Needs `-vita-frame` |
| `-vita-frame N` | Height in pixels of one frame on the Vita. Its `.meta` gets `ppu` scaled the same way |
| `-list` | Print each frame's number and file name |
| `-h` | Show help |

- The Vita can also use the full-size PC sheet (up to 4096 pixels). `-vita` is for when its GPU memory gets tight.
- Frames are the `.png` files in the folder, in natural order (`walk2` before `walk10`).
- Every frame must be the same size and an 8-bit PNG.
- The PC sheet can be at most 16384 pixels on a side, and the 3DS sheet at most 1024, and the Vita sheet at most 4096.
- Do not write the output sheet into the frames folder, or the next run will pack it as a frame.
- With the `LINEAR` filter, the edge of a frame can pick up a sliver of its neighbour. `POINT` does not.

---

# console_deploy

**console_deploy** uploads a `.3dsx` (New 3DS LL) or `.vpk` (PS Vita) to the console over FTP. Switch the console's FTP server on first.
Settings are in `tools/console_deploy.ini` (a password goes in the gitignored `tools/console_deploy.local.ini`).

```bat
odin build tools/console_deploy.odin -file -out:tools/console_deploy.exe -o:speed
tools\console_deploy build\hardware\some_build.vpk
```

Options: `-target:3ds|vita` (instead of choosing by extension), `-ini:<path>`. Exit code 0 only if every file uploaded.
Tests (against a fake server on 127.0.0.1): `odin test tools/console_deploy.odin -file`.
