# Matchbox development: handoff for the next session

Written 2026-11-21 at the end of a long session. Read this first, then `render_plan.md` (the plan of record) and
`fixes.md` (the user's pain points from using Matchbox). The Claude memory folder for this project has the standing
rules too; they are repeated here so this file stands alone.

## Who does what

- **This (new) session:** Matchbox development: the renderer, the handheld ports, the shader compiler (`mbsc`), docs.
- **The old session** stays open for debugging while the user builds a small 2D game (`C:\Users\King-\Documents\odin-projects\games\RunTeddyRun`; it follows an earlier Flappy clone test at `games\flappy-clone`)
  to test the Matchbox API and to confirm porting. Findings from that game land in `fixes.md`.
- The user is `anguelesperanza`. Branch: `full-rewrite` (PC D3D11, 3DS through `matchbox/o3dx` + citro3d,
  Vita through `matchbox/vito` + GXM). `main` is the old SDL3_GPU Matchbox.

## Working rules (the user's, learned the hard way)

1. **The user commits everything.** Never commit or push unless asked. When they do ask, end commits with the attribution
   line the harness gives you. If you open a PR, say explicitly whether more is coming (they merge as soon as one appears).
2. **API shape is the user's.** They tailor Matchbox's API to their taste and make those changes themselves. For API
   questions: explain and give an opinion, do not edit unless told to. Items in `fixes.md` marked `[c]` are the ones they
   want Claude to do. Phase S work (mbsc, docs, shader files) is yours to do as asked.
3. **`render_plan.md`:** the decisions list and S-checkboxes are the user's to tick. Propose, don't tick. Dated status
   lines at the top are fine to add.
4. **Engine files edited for Phase S** are logged in `docs/phase_s_engine_changes.md` (the user reviews them).
5. **No legacy 2D path.** The old pixel-space renderer is deleted, not kept alive. No stopgaps.
6. **AI-usage promise in `README.md`:** Claude writes rendering and shader code, but **audio** must be designed and tested
   by hand first before Claude is given free rein. Font code was Claude's and the user plans to redo it by hand.
7. **House style:** `CLAUDE.md` in the repo root (copied from `main` on 2026-11-21; its header says which parts describe `main`
   only). It is the authority: `snake_case` procs, `Pascal_Snake_Case` types, `SCREAMING_CASE` enum values one per line,
   `create_` / `load_` / `destroy_` / `is_` / `get_` prefixes, no callbacks, no new package-level constants or globals,
   comments that explain why.
8. **Report honestly what is not verified** (emulator vs hardware, not run vs run). The user cares about this.
9. **Targets are exactly three:** PC (Windows, D3D11), the 3DS (specifically a New 3DS LL) and the PS Vita. Nothing else is
   planned for this rewrite. (Linux only through Wine/Proton running the Windows build, per `README.md`.)
10. Gotchas on this machine: Bash/Python heredocs mangle `\n` inside Odin string literals (use the Edit tool); devkitPro
   `make` does not work from this shell (compile C by hand, see "Tooling"). `sed -i` on a `.bat` breaks its CRLF line
   endings and cmd then misreads the script; edit `.bat` files with the Edit tool or PowerShell.
11. **Emulators are not hardware.** Azahar drew a shader the real New 3DS LL hung on (partial output write, 2026-11-23;
   see `docs/shader_pica.md`). Claude runs Azahar and Vita3K; the user runs the real consoles. To find a hardware-only
   hang, build a test that adds one feature per frame and waits for the GPU with a timeout (`C3D_FrameBegin` with
   `FRAME_NONBLOCK`), printing each step, so the hang names its step. **Give every hardware test build its own file name
   and on-console title** (the 3DS `TARGET` / the Vita `TITLE` in the build script, and a first printed line naming the
   test): all of them showed as "My Game" once and the wrong one was run.

## State of the repo (2026-11-21, Phase C added 2026-11-22)

- **2026-11-23: the 3DS draws on real hardware, and Phase V is done in Vita3K.** The freeze on the New 3DS LL was mbsc
  writing the `texcoord0` output `.xy` only; the real GPU hangs on that, Azahar does not. mbsc now writes outputs whole
  (`docs/shader_pica.md`). The Vita has the shared renderer, textures, text, touch and a print log
  (`ux0:data/matchbox.log`); `examples/vita-check` is the build for its first hardware pass (`render_plan.md`,
  "Phase V: status").
- **2026-11-22: Phase C, C0 to C4 done on the 3DS, checked in Azahar only** (render_plan.md, "Phase C: status").
  - The 3DS draws the shared render queue with mbsc's `mesh.3ds.v.pica` and `.tev`.
  - `examples/render-check` passes all its framebuffer probes.
- **2026-11-22 (later): Phase D on the 3DS done** (render_plan.md, "Phase D: status").
  - `load_texture` reads the `.t3x` and the `.meta` beside it, and image subfolders are kept.
  - The demo now runs on the 3DS, and its shia sheet animates. One thing still keeps it from looking right there:
    - The demo crops the cat with PC pixel coordinates (`face.source = {150, 150, 64, 64}`) and sets ppu 16
      itself. The 3DS cat is 32x32, so those crops land on transparent padding and are cut away. The cat's
      `.meta` is right since the `.meta` fix (a target's own image no longer takes the shared `.meta`), and a
      sprite that uses frames and the texture's ppu draws it at the same world size as on PC.
- **2026-11-22 (later still): native text on the 3DS** (render_plan.md, "F2: status (3DS)").
  - `create_font` on the 3DS bakes from the console's system font and ignores the TTF. Layout, wrapping and
    measuring stay shared.
- **2026-11-22 (later still): the 3DS bottom screen draws** (render_plan.md, "Bottom screen: status (3DS)").
  - It has its own render target.
  - `print` lines are drawn on it at `render_end`, in place of the ctru console, and still go to the emulator's
    log.
  - **Every pass, every frame:** a game draws the world, the HUD and the bottom screen every frame, and
    Matchbox drops what a target cannot show. On PC and the Vita, `.FULLSCREEN` drops the world and HUD. The
    3DS shows both screens. The demo draws this way now.
  - `set_bottom_screen(.CONSOLE)` gives the 3DS bottom screen to ctru's console, with `print` going there.
  - A failed assert or a panic shows its message on the bottom screen's console and waits for START.
- **The user's decisions for the handhelds (2026-11-22):**
  - Native text per target.
  - On the 3DS, `print` draws on the bottom screen.
  - Touch gets implemented.
  - Audio stays stubbed; the user writes it.
  - The handheld halves of E and F get implemented.
  - Loose ends wait for a tidy-up at the end.

  render_plan.md has these in full.
  - **Use Azahar, not Citra.** The 2024 Citra nightly hangs on `C3D_DrawElements` and ignores vertex uniforms.
    That cost a long hunt in which nothing in Matchbox was wrong.

- HEAD `f165a6f` on `full-rewrite`; working tree: only `fixes.md` modified (the user's).
- Tests: `odin test tools/mbsc` -> 120 pass (a leak report from `pica_safe_name` in `pica.odin` prints during the run:
  a small test-only leak to fix). `odin test matchbox` -> 54 pass. `odin check matchbox -no-entry-point` is clean;
  with `-vet` it reports three older issues (`logger_windows.odin` unused `core:log`, `texture_windows.odin` unused
  `png`, `reflection_windows.odin:101` shadowed `line`).
- **Later on 2026-11-21, A0b (T0-T4) was done**, so the next three points are now history:
  - The 3DS build is repaired.
  - `shared.odin` is shared again.
  - The Vita boots.
- **How the targets are selected:**
  - `matchbox/target.odin` holds `VITA :: #config(MATCHBOX_VITA, false)`. The 3DS files sit inside `when !VITA` and
    the Vita's inside `when VITA`.
  - `mbi` is one shared `Matchbox_Info` (`matchbox_info.odin`, which lists the backend contract), with
    `using backend:Backend_State` from each `backend_<target>.odin`.
- **What boots:**
  - `examples/handheld-boot` checks, builds and boots in Citra (3DS) and Vita3K (Vita). It prints its four `boot:`
    lines at 60 fps.
  - The demo checks and builds on all three. On the handhelds it runs until its first sprite, then stops on
    `ensure("Sprite has no texture")`, because handheld textures have no size until Phases C and V load them.
- **What is still empty on the handhelds:**
  - The Vita draws nothing but the clear colour (Phase V). The 3DS draws both screens, with `print` drawn on the
    bottom one.
  - Text: the 3DS draws it with the console's system font (F2). The Vita has no glyphs until Phase V.
  - Touch: the 3DS reads the stylus as the mouse (`is_mouse_*(.LEFT)`, `get_mouse_position`,
    `calculate_mouse_bottom_screen_position`), checked in Azahar. The Vita's touch panels aren't read yet (Phase V).
  - Audio is stubbed on all three targets.
- **Not verified:** the clear colour on screen (the emulator logs were read, no screenshots), and real hardware.
- `render_plan.md` in the repo is the newest copy. The old session's scratchpad held three older snapshots
  (`f4b/`, `mbsc/`, `plan/render_plan_3d_first.md`); diffed 2026-11-21, they contain nothing the repo lacks.

## Check everything

Run these after any change, on all three targets. The counts are from 2026-11-22.

```
PC:    odin check matchbox -no-entry-point          (clean; -vet: the 3 old issues)
       odin test matchbox                           (69 pass)
       odin test tools/mbsc                         (120 pass)
       odin build examples/shia-test ; odin check demo.odin -file
3DS:   3ds_check.bat                                (the demo at the root)
       3ds_check.bat examples\handheld-boot
       3ds_build.bat examples\handheld-boot         -> app.3dsx; four boot: lines in Azahar
       3ds_build.bat examples\render-check          -> app.3dsx; "check: 21 probes, 2 bottom, 11 facts, text, failures 0" on Azahar's bottom screen
       3ds_build.bat examples\shia-test             -> app.3dsx; idles at 60 FPS in Azahar, SELECT quits
Vita:  vita_check.bat
       vita_check.bat examples\handheld-boot
       vita_build.bat examples\handheld-boot        -> MyGame.vpk; four boot: lines in Vita3K
```

**Reading the prints:**
- **Vita3K** logs `sceClibPrintf` as it is.
- **Citra's command-line build** (`citra.exe`) logs to stderr, but it drops `svcOutputDebugString`, which is where
  `mb.print` goes, unless `%APPDATA%\Citra\config\sdl2-config.ini` has `log_filter = *:Info Debug.Emulated:Debug`.
  Set it for the run, then put the file back.
- **Azahar's log** loses the game's output when the emulator is killed. render-check avoids the log: it prints on
  the bottom screen and keeps drawing, so a screenshot of the Azahar window shows both the scene and the results.
  Launch Azahar with the `.3dsx` path as its argument.
- **Citra is not to be trusted for drawing** (see "State of the repo"). Its logging notes above still hold for
  print-only checks.

## Status by phase (from `render_plan.md`, checked against the repo)

| Phase | State |
|---|---|
| A (shared foundations) | PC-first decision (2026-11-14): `core:math/linalg`, no shared `math.odin` yet. **A0b done** (2026-11-21, T0-T4: target selection, the backend contract, Vita scripts, the handhelds' entry file; since 2026-11-22 that is `matchbox/handheld_entry`, which the scripts build with the game imported through the `matchbox_game` collection, so games carry no entry file). **A0 verified in Citra** (the o3dx context: `fmt.tprintf`, `make`/`append`, and a failed `assert` printed its message). A1/A4 shared maths moves over when a handheld needs it. |
| B (PC 3D core) | Done on PC. **B8 (viewport/scissor, fit policy, overscan cap) deferred** by the user. |
| C (3DS core) | **C0-C4 done** (2026-11-22, Azahar). **Runs on the real New 3DS LL since 2026-11-23** (`gpu_test5`: rectangles, textured sprites, background, circles, lines, blended boxes, text), after the hang fix in `docs/shader_pica.md` ("Output registers are written whole"). C5 waits on B8; C6 optional. The cube-scene gate itself not run on hardware. |
| V (Vita core) | **Done in Vita3K** (2026-11-23) except V8 (deferred with B8) and audio (the user's). See `render_plan.md`, "Phase V: status". **Hardware pass 1 passed** (2026-11-23): `examples/vita-check` runs on a real Vita, and RunTeddyRun plays. Pass 2 comes after Phase G. |
| D (textures/assets) | D1-D3 done on PC. The 3DS half of D1, D2 and D4 done (2026-11-22, Azahar). The Vita half (V5) done in Vita3K (2026-11-23). |
| E (2D) | E1-E7 done on PC (shia-test ported, `examples/shia-test`). E7 done on the 3DS (Azahar) and the Vita (Vita3K, 2026-11-23). |
| F (HUD/text/input/bottom screen) | F1, F3, F4 done on PC. **F2 text**: each target uses its native text: the 3DS's system font (2026-11-22; draws on hardware since 2026-11-23), the Vita's through ScePvf (2026-11-23, Vita3K). Vita front touch is the mouse (2026-11-23). |
| G (3D games) | Not started (models, lighting, 3D cameras, billboards, render targets, skinning). |
| H (hard-float via Farlite) | Late, not started. |
| S (shader language) | S0-S7 done; see below. |

## Phase S in detail (`tools/mbsc/`, `docs/shader_*.md`)

Pipeline: parse -> `check_subset` -> `build_module` -> `check_bodies`/`check_target` -> `lower_module` (IR) -> backends
(`hlsl.odin`, `cg.odin`, `pica.odin` + `pica_expr/ops/stmt.odin`, `tev.odin`) and reflection (`reflection.odin`).
CLI: `--check`, `--dump-ir`, `--emit-hlsl`, `--emit-cg`, `--emit-pica` (writes `<name>.v.pica` and `<name>.tev`),
`--emit-reflection`, `-target:pc|vita|3ds`, `-o:`. Regenerate the PC shader after editing `matchbox/shaders/mesh.mbs`:

```
mbsc matchbox/shaders/mesh.mbs -target:pc --emit-hlsl -o:matchbox/shaders/mesh.pc.hlsl
```

(build mbsc with `odin build tools/mbsc -out:tools/mbsc/mbsc.exe`; a test fails when committed generated files are stale.)

Decisions (also in `render_plan.md`): compiler is `mbsc`; shaders are `.mbs` under `matchbox/shaders/`; Odin-subset syntax;
no silent approximation; numbered errors `MBS-E<n>` explained in `docs/shader_errors.md`; the 3DS fragment stage is a
portable subset mapped to TexEnv; PC output generated at build, Vita `.gxp` stays committed; mbsc stops at Cg for the Vita.

What is done and how well it is verified:

| Step | Done | Verified how |
|---|---|---|
| S0-S3 (language, front end, HLSL, reflection) | yes | tests; the PC engine loads `mesh.pc.hlsl` + `mesh.pc.refl`; pixel tests on the D3D software device. **The user should still run the demo to confirm it looks unchanged**, then may delete the hand-written `matchbox/shaders/mesh.hlsl` (kept, not loaded). |
| S4 Vita Cg | yes | compiled with `psp2cgc`; mesh programs ran in Vita3K. **No Vita runtime exists**, no real Vita. Doc: `docs/shader_cg.md`. |
| S5 3DS vertex (PICA) | yes | every program assembles with `picasso`; assembly agrees numerically with the IR interpreter for all 3DS built-ins; a triangle drawn in **Azahar** with matrix, `[4]f32` and bool uniforms. **`mesh.mbs` runs on the real New 3DS LL** (2026-11-23) since outputs are written whole: a partial write (`mov out.xy`) hangs the real GPU, not Azahar. `every_output_register_is_written_whole` guards it. Doc: `docs/shader_pica.md`. |
| S6 3DS fragment (TexEnv `.tev`) | plan generator + tests | One run on Azahar with hand-applied stages: `MULTIPLY_ADD TEXTURE0 PRIMARY_COLOR CONSTANT` gave the exact expected colour; alpha test `GEQUAL 0x70` kept, `0x90` discarded. **Not covered:** INTERPOLATE, ADD_MULTIPLY, one-minus operands, PREVIOUS chaining, several textures, real 3DS. **The 3DS runtime reads `.tev` since Phase C** (`shader_tev.odin`), and applies `mesh.3ds.tev` (MODULATE, alpha test from `render_alpha_cutoff`). |
| S7 capabilities | yes | tests |

Open Phase S work:
- Azahar checks of the other TexEnv stage functions. The runtime applier exists (Phase C), but only `mesh.3ds.tev` has
  run through it. It refuses a constant read from a uniform and more than one texture, because both need custom shaders.
- Errors without source spans: E3 and E21 come from the backends as plain strings; structural E2 and E5 are not yet
  AST-spanned. Making them rustc-style with a span is the open polish.
- Custom shaders in the engine: `set_shader_value(name, value)` has no `shader` argument (one built-in shader); there is no
  way to bind a second texture per draw. `docs/phase_s_engine_changes.md` lists these.
- `docs/shader_language.md` section 20 has no pointer to the `.tev` format yet.
- Fix the small `pica_safe_name` leak that prints during the mbsc tests.
- **S8a** (`.shbin` writer inside mbsc, `--emit-pica` stays) after the PICA output is tested on a real 3DS. **S8b** (`.gxp`):
  a shared `gxp` back-end package in its own repo (small stable IR, knows nothing of Cg or mbs); vito's own compiler parses
  Cg and calls it; mbsc keeps emitting Cg first; `psp2cgc` stays as the reference. Much larger than S8a because the GPU
  encoding is only partly public. Both are written in `render_plan.md`.

## Open decisions (render_plan.md "Decisions to make")

Vita emulator vs hardware as the per-step check (before V0); Vita MSAA (V8); the default design aspect and fit policy for
three differently shaped screens, plus the overscan cap (F1/B8); sprite pivot convention (recommended centre, which is
what the code does); cut-out vs blended default (code defaults to cut-out); the 3DS text approach (before E1).

## From the user's 2D game and `fixes.md`

Open items (see the file for the user's wording and legend):
- Rename `create_*` texture loaders to `load_*` (marked `[c]`: Claude does it; the rule is in `CLAUDE.md`: `create_x` makes one, `load_x` imports something that already exists whole).
- `create_sprite` should create its texture (`.meta` best guess when no `.meta` exists: done, `calculate_guessed_texture_meta`, used by `create_animation_clip` only);
  `sheetpack` should accept a single file; asset subfolders work only by writing them in the name
  (`"sprites/meme.png"`), nothing scans nested folders; positioning around `(0,0,0)` is tedious; move procs for sprites.
- Parallax was written with the user's first test game (the Flappy clone): `create_parallax_layer(filename, amount, direction, scale_factor, layer)`,
  `parallax_move(&layer, dt, speed)`, `render_parallax`, `destroy_parallax` in `matchbox/shared.odin`, using one shared
  offset per layer (avoids drift). `calculate_screen_bounds` assumes the camera is at the origin.
- Cut-out sprites at the **same z** have undefined draw order (sorted by texture handle, depth test `LESS`), so a bird at the
  same z as the background can vanish on some runs. Documented behaviour is "give overlapping sprites different z"; a
  tie-breaker by submission order, or a warning, would be a real fix (propose to the user).
- `destroy` group lacks the font (the user's note on commit `c0653b1`).
- `engine_plan.md` (a Unity-like engine on top of Matchbox, planning stage) is not on this branch; look on `main`.

## API facts confirmed this session (so you do not re-derive them)

- World units: positions, sprite size (`pixels / pixels_per_unit * scale`) and camera size (`view_height / zoom`) are all in
  world units, +Y up, camera at z = 10 looking down -Z; larger z is nearer. `create_camera_2d(view_height)`; with
  `view_height` = window height and ppu 1, one unit is one pixel.
- `Sprite.position` is `[3]f32`; z is the layer. Default pivot `{0.5, 0.5}` (the sprite's centre sits on `position`).
- `.meta` (next to the image, `name.meta`): `ppu`, `columns`, `rows`, `frames`; optional for single images, required for
  sheets. `sheetpack` builds a sheet **from a folder of same-size frames** and writes the `.meta`.
- `get_asset` (PC): tries `assets/pc/images/<name>` then `assets/images/<name>` (audio likewise); `..` in a name is not blocked.
- A `Texture` is two GPU pointers; sprites and clips copy it. `destroy_texture` frees every copy at once, so destroy a shared
  texture exactly once.

## Tooling and environment (Windows)

- picasso `C:\devkitPro\tools\bin\picasso.exe` (tests find it via `PICASSO`, `DEVKITPRO` or `C:/devkitPro`); `psp2cgc` in the
  vito repo (`PSP2CGC` or `../vito/tools/psp2cgc.exe`); tests skip when a tool is absent.
- Emulators: Azahar `C:\Program Files\Azahar\azahar.exe` (2126.2 since 2026-11-22); Vita3K
  `C:\Users\King-\Documents\vita3k\Vita3K.exe` (updated 2026-11-22; the old one, `C:\Users\King-\Documents\windows-latest\Vita3K.exe`,
  is kept as a fallback). The test 3DS is a New 3DS LL.
- Building a small 3DS test app by hand (the shape that worked): `picasso -o x.shbin x.v.pica`; `bin2s -a 4 -H x_shbin.h x.shbin > x_shbin.s`;
  `arm-none-eabi-gcc -c x_shbin.s`; compile `main.c` with `-O2 -mword-relocations -march=armv6k -mtune=mpcore -mfloat-abi=hard -mtp=soft -D__3DS__ -I<libctru include>`;
  link with `-specs=3dsx.specs ... -lcitro3d -lctru -lm`; `3dsxtool app.elf app.3dsx`. PATH needs `C:\devkitPro\devkitARM\bin` and `C:\devkitPro\tools\bin`.
  `C3D_TexEnvColor` takes `0xAABBGGRR`; RGBA8 texels are `0xRRGGBBAA`.
- Screenshots of an emulator window: bring it to the front before capturing, or you capture whatever is on top (it once captured the user's editor).
- Other tools: `tools/sheetpack.odin` (`odin build tools/sheetpack.odin -file -out:tools/sheetpack.exe -o:speed`),
  `tools/tritex.odin`, `tools/mp3towav.odin`, `tools/mbsc_probe.odin`; usage in `tools/howto.md`.

### Putting a hardware test build on a console (`tools/console_deploy.odin`)

Whenever a new `.3dsx` or `.vpk` needs testing on hardware:

1. Tell the user the build is ready (full path in the main checkout's `build\hardware\`).
2. **Wait until they say the FTP ports are open.** They switch each console's FTP server on by hand (it shuts off while an
   app runs). **Nothing is ever uploaded, and no connection is made to the consoles' addresses, without that go-ahead.**
3. Then run `console_deploy <full path to the build>` (the extension picks the console: `.3dsx` is the 3DS, `.vpk` is the Vita;
   `-target:3ds|vita` overrides). It prints one `uploaded ...` line per file and exits 0 only if every file arrived.
4. Ask the user to confirm the build shows on the console (3DS: `sdmc:/3ds`, Vita: `ux0:downloads/`).

Build it once with `odin build tools/console_deploy.odin -file -out:tools/console_deploy.exe -o:speed`. Settings (addresses,
ports, folders) are in `tools/console_deploy.ini`; a password goes in the gitignored `tools/console_deploy.local.ini`.
Tests (a throwaway FTP server on 127.0.0.1, never a console): `odin test tools/console_deploy.odin -file`.

## Suggested order for the next stretch

1. Finish the PC side of the plan while the 2D game keeps feeding `fixes.md`: B8 (viewport, fit policy, overscan), F2 closure,
   the open decisions above, the `[c]` renames.
2. Handhelds: A0b, Phase C C0-C4, the 3DS half of Phase D, native 3DS text, the 3DS bottom screen, 3DS touch and shia-test on the
   3DS (E7) are done, so the 3DS halves of E and F are finished. Next: the Phase C gate scene, and C5 once B8 is settled.
3. Phase V (Vita), reusing `mbsc --emit-cg` + committed `.gxp`.
4. Then G (3D games), then H.
5. In parallel when convenient: S6 runtime applier, real-hardware tests of the PICA and TexEnv output, S8a.
