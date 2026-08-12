@echo off
setlocal enabledelayedexpansion

set PROJECT_NAME=game
set PROJECT_SRC=src

REM The NoSL step that used to be here is gone with the backend it served.
REM Matchbox's own shaders are compiled by build_shaders.bat at the repository
REM root and embedded into the package, so a game only builds itself.

echo === Building Odin project ===
odin build "%PROJECT_SRC%" -debug -out:build\%PROJECT_NAME%.exe
if errorlevel 1 (
    echo [ERROR] Odin build failed
    exit /b 1
)

echo.
echo === Build complete: build\%PROJECT_NAME%.exe ===
echo.

echo === Running Odin project ===
build\%PROJECT_NAME%.exe
if errorlevel 1 (
    echo [ERROR] Could not run application
    exit /b 1
)

endlocal
