@echo off
setlocal enabledelayedexpansion

REM ================================
REM  CONFIGURATION
REM ================================
set PROJECT_NAME=game
set PROJECT_SRC=src
set SHADER_DIR=src\shaders

set GPU_COMPILER=..\..\gpu_compiler\gpu_compiler.exe

REM ================================
REM  CHECK GPU COMPILER EXISTS
REM ================================
if not exist "%GPU_COMPILER%" (
    echo [ERROR] gpu_compiler.exe not found at "%GPU_COMPILER%"
    exit /b 1
)

REM ================================
REM  COMPILE NOSL SHADERS
REM ================================
echo.
echo === Compiling NOSL shaders ===

for %%F in ("%SHADER_DIR%\*.nosl") do (
    set FILE=%%~nF
    echo -- Compiling %%F

    "%GPU_COMPILER%" "%SHADER_DIR%\!FILE!.nosl"
    if errorlevel 1 (
        echo [ERROR] gpu_compiler failed on %%F
        exit /b 1
    )

    glslangValidator -V "%SHADER_DIR%\!FILE!.glsl" -o "%SHADER_DIR%\!FILE!.spv"
    if errorlevel 1 (
        echo [ERROR] glslangValidator failed on %%F
        exit /b 1
    )
)

echo === Shader compilation complete ===
echo.

REM ================================
REM  BUILD ODIN PROJECT
REM ================================
echo === Building Odin project ===
odin build "%PROJECT_SRC%" -debug -out:build\%PROJECT_NAME%.exe
if errorlevel 1 (
    echo [ERROR] Odin build failed
    exit /b 1
)

echo.
echo === Build complete: build\%PROJECT_NAME%.exe ===
echo.

REM ================================
REM  RUN ODIN PROJECT
REM ================================
echo === Running Odin project ===
build\%PROJECT_NAME%.exe
if errorlevel 1 (
    echo [ERROR] Could not run application
    exit /b 1
)

echo.
echo === Finished Running: build\%PROJECT_NAME%.exe ===
echo.

endlocal

