@echo off
:: Checks the game in the folder given, or the one at the repository root when none is.
:: 3ds_check.bat examples\handheld-boot
:: Through matchbox\handheld_entry, as 3ds_build.bat builds it, so a game the entry point
:: can't call (no `main`) fails here too
set SRC=%~1
if "%SRC%"=="" set SRC=.
for %%I in ("%SRC%") do set "GAME_DIR=%%~fI"
odin check matchbox\handheld_entry -collection:matchbox_game="%GAME_DIR%" -target:freestanding_arm32 -no-entry-point -no-thread-local -max-error-count:100
