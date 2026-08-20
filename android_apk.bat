@echo off
setlocal enabledelayedexpansion

REM Builds one example into an installable .apk.
REM
REM   android_apk.bat                    build examples\init-window
REM   android_apk.bat ui                 build examples\ui
REM   android_apk.bat ui install         build it, adb install -r it, launch it
REM
REM Prerequisites, once per machine:
REM
REM   android.bat        cross-compiles stb for arm64 into libs\android
REM   android_sdl.bat    fetches libSDL3.so and SDL's Java classes
REM   ODIN_ANDROID_NDK   and ODIN_ANDROID_SDK set in the environment
REM   the vendor:stb patch described in improvements.md
REM
REM ----------------------------------------------------------------------
REM The one thing here that is not obvious:
REM
REM   -L libs\android
REM
REM   vendor:stb names its archives by path, and Odin turns a path-named foreign
REM   import into -l:<absolute path>, which lld cannot use. The vendor bindings
REM   have to be patched to fall through to their "system:" form, and then this
REM   -L resolves them against the lib-prefixed archives android.bat writes. See
REM   the Android section of improvements.md.
REM
REM The entry point used to be a linker flag here too, aliasing SDL_main onto
REM Odin's main. That was wrong -- in -build-mode:shared Odin's main is a stub
REM that returns 0 -- and it now lives in matchbox/android.odin, which explains
REM itself at length.
REM ----------------------------------------------------------------------

REM The one API level everything is built against. Odin defaults to 34, which
REM quietly produces a binary referencing symbols such as __register_atfork that
REM API 21's libc does not have -- while the manifest still advertised 21, so the
REM apk claimed devices it could not load on. It is one number here, spent on the
REM compile, the dex, the signature and the manifest, so the four cannot drift.
REM SDL's own .so and android.bat's stb are both built for 21 too.
set "APILEVEL=21"

set "EXAMPLE=%~1"
if "%EXAMPLE%"=="" set "EXAMPLE=init-window"

set "ROOT=%~dp0"
set "SRC=%ROOT%examples\%EXAMPLE%"
set "LIBS=%ROOT%libs\android"
set "OUT=%ROOT%build\android\%EXAMPLE%"

if not exist "%SRC%" (
    echo [ERROR] No such example: examples\%EXAMPLE%
    exit /b 1
)

REM TankMovement keeps its source a level down, in src\. Follow that rather than
REM special-casing the name.
if not exist "%SRC%\main.odin" (
    if exist "%SRC%\src\main.odin" set "SRC=%SRC%\src"
)

if not exist "%LIBS%\libSDL3.so" (
    echo [ERROR] No libs\android\libSDL3.so. Run android_sdl.bat first.
    exit /b 1
)

if not exist "%LIBS%\SDL3-classes.jar" (
    echo [ERROR] No libs\android\SDL3-classes.jar. Run android_sdl.bat first.
    exit /b 1
)

if not exist "%LIBS%\libstb_truetype.a" (
    echo [ERROR] No stb archives in libs\android. Run android.bat first.
    exit /b 1
)

if not defined ODIN_ANDROID_SDK (
    echo [ERROR] ODIN_ANDROID_SDK is not set.
    exit /b 1
)

REM Pick the newest build-tools and platform the SDK has, rather than pinning a
REM version that only exists on the machine this was written on.
for /f "delims=" %%d in ('dir /b /ad /on "%ODIN_ANDROID_SDK%\build-tools" 2^>nul') do set "BTV=%%d"
for /f "delims=" %%d in ('dir /b /ad /on "%ODIN_ANDROID_SDK%\platforms" 2^>nul') do set "PLATV=%%d"

if not defined BTV (
    echo [ERROR] No build-tools under "%ODIN_ANDROID_SDK%\build-tools"
    exit /b 1
)
if not defined PLATV (
    echo [ERROR] No platforms under "%ODIN_ANDROID_SDK%\platforms"
    exit /b 1
)

set "BT=%ODIN_ANDROID_SDK%\build-tools\%BTV%"
set "ANDROID_JAR=%ODIN_ANDROID_SDK%\platforms\%PLATV%\android.jar"

REM A package name has to be a Java identifier, so the dashes have to go.
set "PKGSUFFIX=%EXAMPLE:-=%"
set "PACKAGE=org.matchbox.%PKGSUFFIX%"

echo === Building %EXAMPLE% for Android arm64 ===
echo     build-tools %BTV%, %PLATV%

if exist "%OUT%" rmdir /s /q "%OUT%"
mkdir "%OUT%\lib\arm64-v8a"

echo -- compiling libmain.so
odin build "%SRC%" -target:linux_arm64 -subtarget:android -build-mode:shared ^
    -minimum-os-version:%APILEVEL% ^
    -out:"%OUT%\lib\arm64-v8a\libmain.so" ^
    -extra-linker-flags:"-L%LIBS%" || exit /b 1

copy /y "%LIBS%\libSDL3.so" "%OUT%\lib\arm64-v8a\" >nul || exit /b 1

echo -- dexing SDL's Java classes
call "%BT%\d8.bat" --min-api %APILEVEL% --lib "%ANDROID_JAR%" --output "%OUT%" "%LIBS%\SDL3-classes.jar" || exit /b 1

REM Everything the example ships that is not source becomes an asset, keeping
REM its path: examples\ui\art\ember.png is read back as "art/ember.png". That is
REM the same string the desktop build opens, because read_entire_file goes
REM through SDL's IOStream, which sends a relative path to the asset manager on
REM Android and to the filesystem everywhere else.
echo -- staging assets
robocopy "%SRC%" "%OUT%\assets" /E /XF *.odin *.dll *.so *.exe *.pdb *.lib /XD build >nul
if errorlevel 8 (
    echo [ERROR] Could not stage assets from %SRC%
    exit /b 1
)

set "ASSETFLAG="
dir /b /s /a-d "%OUT%\assets" 2>nul | findstr /r "." >nul && set "ASSETFLAG=-A assets"

echo -- manifest for %PACKAGE%
powershell -NoProfile -Command ^
    "(Get-Content '%ROOT%android\AndroidManifest.xml' -Raw) -replace '__PACKAGE__','%PACKAGE%' -replace '__LABEL__','matchbox %EXAMPLE%' -replace '__MINSDK__','%APILEVEL%' | Set-Content -NoNewline '%OUT%\AndroidManifest.xml'" || exit /b 1

echo -- packaging
pushd "%OUT%"
"%BT%\aapt.exe" package -f -M AndroidManifest.xml -I "%ANDROID_JAR%" %ASSETFLAG% -F app.apk-build || (popd & exit /b 1)

REM Forward slashes, deliberately. aapt writes the entry name exactly as given,
REM and Android only recognises a native library at lib/<abi>/, so a backslash
REM here produces an apk that installs and then dies in System.loadLibrary.
"%BT%\aapt.exe" add app.apk-build classes.dex lib/arm64-v8a/libmain.so lib/arm64-v8a/libSDL3.so >nul || (popd & exit /b 1)
popd

echo -- aligning
"%BT%\zipalign.exe" -p -f 4 "%OUT%\app.apk-build" "%OUT%\%EXAMPLE%.apk" || exit /b 1

REM A self-signed debug key. Android refuses to install an unsigned apk, so this
REM is not optional even for a throwaway build. It is not a release key and the
REM password is not a secret -- 'android' is the convention the SDK's own debug
REM keystore uses. Gitignored all the same.
if not exist "%ROOT%android\debug.keystore" (
    echo -- generating android\debug.keystore
    keytool -genkeypair -keystore "%ROOT%android\debug.keystore" ^
        -storepass android -keypass android -alias androiddebugkey ^
        -keyalg RSA -keysize 2048 -validity 10000 ^
        -dname "CN=Matchbox Debug,O=Matchbox,C=US" || exit /b 1
)

echo -- signing
call "%BT%\apksigner.bat" sign --ks "%ROOT%android\debug.keystore" ^
    --ks-pass pass:android --key-pass pass:android ^
    --ks-key-alias androiddebugkey --min-sdk-version %APILEVEL% ^
    "%OUT%\%EXAMPLE%.apk" || exit /b 1

del "%OUT%\app.apk-build" >nul 2>nul

echo === Built %OUT%\%EXAMPLE%.apk ===

if /i "%~2"=="install" (
    echo -- installing
    "%ODIN_ANDROID_SDK%\platform-tools\adb.exe" install -r "%OUT%\%EXAMPLE%.apk" || exit /b 1
    echo -- launching
    "%ODIN_ANDROID_SDK%\platform-tools\adb.exe" shell monkey -p %PACKAGE% -c android.intent.category.LAUNCHER 1 >nul
    echo.
    echo     adb logcat -s SDL:V DEBUG:V     to see what it says
)

endlocal
