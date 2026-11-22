@echo off
:: Checks the game in the folder given, or the one at the repository root when none is.
:: vita_check.bat examples\handheld-boot
:: The same as 3ds_check.bat plus MATCHBOX_VITA: both consoles are freestanding_arm32, and the
:: define is what picks the Vita's files (matchbox\target.odin)
set SRC=%~1
if "%SRC%"=="" set SRC=.
for %%I in ("%SRC%") do set "GAME_DIR=%%~fI"
odin check matchbox\handheld_entry -collection:matchbox_game="%GAME_DIR%" -target:freestanding_arm32 -no-entry-point -no-thread-local -define:MATCHBOX_VITA=true -max-error-count:100
