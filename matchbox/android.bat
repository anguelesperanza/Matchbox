@echo off
setlocal enabledelayedexpansion

REM Cross-compiles vendor:stb for Android arm64 into android\libs, beside this
REM script, so the archives travel with the matchbox folder they belong to.
REM
REM stb is the one dependency with no prebuilt Android binary anywhere, so this
REM is a real cross-compile with the NDK's clang -- unlike SDL3, which ships an
REM arm64 .so that android_sdl.bat just downloads.
REM
REM Note the "lib" prefix on the archive names, which is not cosmetic. Odin turns
REM vendor:stb's path-named foreign imports into -l:<absolute path>, and lld
REM cannot use that: -l:name searches the -L directories for that literal
REM *filename*, and an absolute path never matches one. The fix is to patch the
REM vendor stb bindings so LIB is "" on Android, which drops them through to
REM their "system:stb_image" form -- and that emits a plain -lstb_image, which
REM only resolves against a file called libstb_image.a. Hence the prefix. See
REM the Android section of improvements.md.
REM
REM The NDK comes from ODIN_ANDROID_NDK, which -subtarget:android needs set
REM anyway, so there is nothing extra to configure here.

if not defined ODIN_ANDROID_NDK (
    echo [ERROR] ODIN_ANDROID_NDK is not set. It is required for
    echo         -subtarget:android as well, so set it once for both.
    exit /b 1
)

set "NDK=%ODIN_ANDROID_NDK%"
set "BIN=%NDK%\toolchains\llvm\prebuilt\windows-x86_64\bin"
set "CC=%BIN%\aarch64-linux-android21-clang.cmd"
set "AR=%BIN%\llvm-ar.exe"

if not exist "%CC%" (
    echo [ERROR] Android ARM64 compiler not found:
    echo         %CC%
    exit /b 1
)

if not exist "%AR%" (
    echo [ERROR] llvm-ar not found:
    echo         %AR%
    exit /b 1
)

REM stb's C sources come out of the Odin tree, for the same reason copy_sdl.bat
REM takes SDL3.dll from there: the bindings and the code they bind stay together.
for /f "delims=" %%i in ('odin root 2^>nul') do set "ODIN_ROOT=%%i"

if not defined ODIN_ROOT (
    echo [ERROR] Could not run 'odin root'. Is odin on PATH?
    exit /b 1
)

set "SRC=%ODIN_ROOT%vendor\stb\src"

if not exist "%SRC%" (
    echo [ERROR] STB source directory not found:
    echo         %SRC%
    exit /b 1
)

set "OUT=%~dp0android\libs"
set "OBJ=%TEMP%\stb_android_obj"

if not exist "%OUT%" mkdir "%OUT%"
if not exist "%OBJ%" mkdir "%OBJ%"

echo === Cross-compiling stb for Android arm64 ===

for %%m in (
    stb_image
    stb_image_write
    stb_image_resize
    stb_truetype
    stb_rect_pack
    stb_sprintf
    stb_vorbis
) do (
    if not exist "%SRC%\%%m.c" (
        echo [ERROR] Missing source file: %SRC%\%%m.c
        exit /b 1
    )

    echo -- %%m
    call "%CC%" -c -O2 -fPIC "%SRC%\%%m.c" -o "%OBJ%\%%m.o" || exit /b 1
    call "%AR%" rcs "%OUT%\lib%%m.a" "%OBJ%\%%m.o" || exit /b 1
)

echo === Done: android\libs\libstb_*.a ===
endlocal
