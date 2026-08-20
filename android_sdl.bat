@echo off
setlocal enabledelayedexpansion

REM Puts the Android arm64 libSDL3.so and SDL's Java classes into libs\android,
REM taken from the official SDL release rather than from a copy kept here.
REM
REM Same argument as copy_sdl.bat, for the same reason: a checked-in binary goes
REM stale silently. So the version is not written down here either -- it is read
REM out of vendor:sdl3's own sdl3_version.odin, which means the .so and the
REM bindings cannot disagree no matter which Odin you upgrade to.
REM
REM Two things come out of the release, and both are needed:
REM
REM   libSDL3.so      the arm64-v8a build, already compiled -- a download, not a
REM                   cross-compile. Gitignored, like the desktop SDL3.dll.
REM
REM   classes.jar     org.libsdl.app.*, SDL's own Java activity. Android will not
REM                   start a process for a native library on its own; something
REM                   Java has to be the entry point, and this is SDL's.

for /f "delims=" %%i in ('odin root 2^>nul') do set "ODIN_ROOT=%%i"

if not defined ODIN_ROOT (
    echo [ERROR] Could not run 'odin root'. Is odin on PATH?
    exit /b 1
)

set "VER_FILE=%ODIN_ROOT%vendor\sdl3\sdl3_version.odin"

if not exist "%VER_FILE%" (
    echo [ERROR] Could not find "%VER_FILE%"
    exit /b 1
)

for /f "tokens=3" %%v in ('findstr /b /c:"MAJOR_VERSION :: " "%VER_FILE%"') do set "MAJ=%%v"
for /f "tokens=3" %%v in ('findstr /b /c:"MINOR_VERSION :: " "%VER_FILE%"') do set "MIN=%%v"
for /f "tokens=3" %%v in ('findstr /b /c:"MICRO_VERSION :: " "%VER_FILE%"') do set "MIC=%%v"

if not defined MIC (
    echo [ERROR] Could not read a version out of "%VER_FILE%"
    exit /b 1
)

set "SDLVER=%MAJ%.%MIN%.%MIC%"
set "URL=https://github.com/libsdl-org/SDL/releases/download/release-%SDLVER%/SDL3-devel-%SDLVER%-android.zip"
set "DEST=%~dp0libs\android"
set "WORK=%TEMP%\matchbox_sdl_android"

echo === Fetching SDL %SDLVER% for Android ===
echo     to match vendor:sdl3's bindings

if not exist "%DEST%" mkdir "%DEST%"
if exist "%WORK%" rmdir /s /q "%WORK%"
mkdir "%WORK%"

echo -- downloading SDL3-devel-%SDLVER%-android.zip
powershell -NoProfile -Command "$ProgressPreference='SilentlyContinue'; try { Invoke-WebRequest -Uri '%URL%' -OutFile '%WORK%\sdl.zip' } catch { Write-Host $_.Exception.Message; exit 1 }" || (
    echo [ERROR] Download failed. Is there a release-%SDLVER% tag on libsdl-org/SDL?
    exit /b 1
)

echo -- unpacking
powershell -NoProfile -Command "Expand-Archive -Force '%WORK%\sdl.zip' '%WORK%\zip'" || exit /b 1

REM The .aar is itself a zip, but Expand-Archive insists on the extension.
copy /y "%WORK%\zip\SDL3-%SDLVER%.aar" "%WORK%\sdl_aar.zip" >nul || (
    echo [ERROR] No SDL3-%SDLVER%.aar inside the release zip
    exit /b 1
)
powershell -NoProfile -Command "Expand-Archive -Force '%WORK%\sdl_aar.zip' '%WORK%\aar'" || exit /b 1

set "SO=%WORK%\aar\prefab\modules\SDL3-shared\libs\android.arm64-v8a\libSDL3.so"

if not exist "%SO%" (
    echo [ERROR] No arm64-v8a libSDL3.so in the aar
    exit /b 1
)

copy /y "%SO%" "%DEST%\libSDL3.so" >nul || exit /b 1
echo -- libs\android\libSDL3.so

copy /y "%WORK%\aar\classes.jar" "%DEST%\SDL3-classes.jar" >nul || exit /b 1
echo -- libs\android\SDL3-classes.jar

rmdir /s /q "%WORK%"

echo === Done ===
endlocal
