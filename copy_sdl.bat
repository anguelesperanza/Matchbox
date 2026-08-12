@echo off
setlocal enabledelayedexpansion

REM Puts SDL3.dll beside a program that needs it, taken from the Odin
REM installation rather than from a copy kept in this repository.
REM
REM Why not just commit the dll: a checked-in copy goes stale silently. This
REM repository shipped SDL 3.3.0 for months while vendor:sdl3's bindings were
REM generated against 3.4.2, so every build was calling a two-minor-versions-old
REM runtime through newer headers and nothing said so. Taking it from the Odin
REM tree means the library and the bindings cannot disagree.
REM
REM   copy_sdl.bat              populate every example
REM   copy_sdl.bat <directory>  put it in one place, e.g. your own game's build

for /f "delims=" %%i in ('odin root 2^>nul') do set "ODIN_ROOT=%%i"

if not defined ODIN_ROOT (
    echo [ERROR] Could not run 'odin root'. Is odin on PATH?
    exit /b 1
)

REM 'odin root' already ends in a backslash
set "SRC=%ODIN_ROOT%vendor\sdl3\SDL3.dll"

if not exist "%SRC%" (
    echo [ERROR] SDL3.dll not found at "%SRC%"
    exit /b 1
)

if not "%~1"=="" (
    if not exist "%~1" (
        echo [ERROR] No such directory: %~1
        exit /b 1
    )
    copy /y "%SRC%" "%~1\" >nul || exit /b 1
    echo Copied SDL3.dll to %~1
    exit /b 0
)

echo === Copying SDL3.dll from the Odin vendor tree ===

for /d %%d in ("%~dp0examples\*") do (
    copy /y "%SRC%" "%%d\" >nul
    echo -- %%~nxd
)

REM TankMovement builds into a subdirectory, so the exe there needs its own copy
if exist "%~dp0examples\TankMovement\build" (
    copy /y "%SRC%" "%~dp0examples\TankMovement\build\" >nul
    echo -- TankMovement\build
)

echo === Done ===
endlocal
