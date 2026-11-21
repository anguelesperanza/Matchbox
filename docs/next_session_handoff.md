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
   `make` does not work from this shell (compile C by hand, see "Tooling").

## State of the repo (2026-11-21)

- HEAD `f165a6f` on `full-rewrite`; working tree: only `fixes.md` modified (the user's).
- Tests: `odin test tools/mbsc` -> 120 pass (a leak report from `pica_safe_name` in `pica.odin` prints during the run:
  a small test-only leak to fix). `odin test matchbox` -> 54 pass. `odin check matchbox -no-entry-point` is clean;
  with `-vet` it reports three older issues (`logger_windows.odin` unused `core:log`, `texture_windows.odin` unused
  `png`, `reflection_windows.odin:101` shadowed `line`).
- **The 3DS build is broken** by API changes (the user knows; to be fixed later). `matchbox/shared.odin` (parallax) has no build tag but uses
  Windows-only names (`Sprite`, `create_texture`, `get_window_size`), so it also fails a `-target:freestanding_arm32` check; the user knows. **The Vita is not started**:
  `vita_build.bat` / `vita_check.bat` are empty, no `matchbox/target.odin`, no Vita entry point.
- `render_plan.md` in the repo is the newest copy. The old session's scratchpad held three older snapshots
  (`f4b/`, `mbsc/`, `plan/render_plan_3d_first.md`); diffed 2026-11-21, they contain nothing the repo lacks.

## Status by phase (from `render_plan.md`, checked against the repo)

| Phase | State |
|---|---|
| A (shared foundations) | PC-first decision (2026-11-14): `core:math/linalg`, no shared `math.odin` yet. **A0b not done** (target selection `-define:MATCHBOX_VITA`, Vita scripts, Vita entry point). A0 (o3dx context) was only verified statically in 2026-11-14. A1/A4 shared maths moves over when a handheld needs it. |
| B (PC 3D core) | Done on PC. **B8 (viewport/scissor, fit policy, overscan cap) deferred** by the user. |
| C (3DS core), V (Vita core) | **Not done.** Everything in them is still to do. |
| D (textures/assets) | D1-D3 done on PC. **D4 (subfolder asset names on the 3DS) open.** |
| E (2D) | E1-E7 done on PC (shia-test ported, `examples/shia-test`). Handheld halves open. |
| F (HUD/text/input/bottom screen) | F1, F3, F4 done on PC. **F2 text**: font code ported from `main` (`font.odin`, `text.odin`, CC0 Bitrimus font); the plan does not mark it done, and the 3DS/Vita text approach is undecided. |
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
| S5 3DS vertex (PICA) | yes | every program assembles with `picasso`; assembly agrees numerically with the IR interpreter for all 3DS built-ins; a triangle drawn in **Azahar** with matrix, `[4]f32` and bool uniforms. **No real 3DS.** Doc: `docs/shader_pica.md`. |
| S6 3DS fragment (TexEnv `.tev`) | plan generator + tests | One run on Azahar with hand-applied stages: `MULTIPLY_ADD TEXTURE0 PRIMARY_COLOR CONSTANT` gave the exact expected colour; alpha test `GEQUAL 0x70` kept, `0x90` discarded. **Not covered:** INTERPOLATE, ADD_MULTIPLY, one-minus operands, PREVIOUS chaining, several textures, real 3DS. **No runtime reads `.tev` yet.** |
| S7 capabilities | yes | tests |

Open Phase S work:
- A 3DS runtime step that reads `.tev` and applies it (`C3D_TexEnv*`, `C3D_AlphaTest`), plus Azahar checks of the other
  stage functions. Note citro3d blends by default: an opaque draw must turn blending off.
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
- `create_sprite` should create its texture; `.meta` best guess when no `.meta` exists (a sheet without one draws as one
  frame); `sheetpack` should accept a single file; asset subfolders work only by writing them in the name
  (`"sprites/meme.png"`), nothing scans nested folders; positioning around `(0,0,0)` is tedious; move procs for sprites.
- Parallax was written with the user's first test game (the Flappy clone): `create_parallax_sprites(filename, amount, direction, scale_factor, layer)`,
  `parallax_move(&layer, dt, speed)`, `render_parallax`, `destroy_parallax` in `matchbox/shared.odin`, using one shared
  offset per layer (avoids drift). `get_screen_bounds` assumes the camera is at the origin.
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
- Emulators: Azahar `C:\Program Files\Azahar\azahar.exe` (an "Update Available" dialog may appear; ignore it); Vita3K
  `C:\Users\King-\Documents\windows-latest\Vita3K.exe`. The test 3DS is a New 3DS LL.
- Building a small 3DS test app by hand (the shape that worked): `picasso -o x.shbin x.v.pica`; `bin2s -a 4 -H x_shbin.h x.shbin > x_shbin.s`;
  `arm-none-eabi-gcc -c x_shbin.s`; compile `main.c` with `-O2 -mword-relocations -march=armv6k -mtune=mpcore -mfloat-abi=hard -mtp=soft -D__3DS__ -I<libctru include>`;
  link with `-specs=3dsx.specs ... -lcitro3d -lctru -lm`; `3dsxtool app.elf app.3dsx`. PATH needs `C:\devkitPro\devkitARM\bin` and `C:\devkitPro\tools\bin`.
  `C3D_TexEnvColor` takes `0xAABBGGRR`; RGBA8 texels are `0xRRGGBBAA`.
- Screenshots of an emulator window: bring it to the front before capturing, or you capture whatever is on top (it once captured the user's editor).
- Other tools: `tools/sheetpack.odin` (`odin build tools/sheetpack.odin -file -out:tools/sheetpack.exe -o:speed`),
  `tools/tritex.odin`, `tools/mp3towav.odin`, `tools/mbsc_probe.odin`; usage in `tools/howto.md`.

## Suggested order for the next stretch

1. Finish the PC side of the plan while the 2D game keeps feeding `fixes.md`: B8 (viewport, fit policy, overscan), F2 closure,
   the open decisions above, the `[c]` renames.
2. Unblock the handhelds: repair the 3DS build against the new API (shared files need target-correct build tags), do A0b
   (target selection, Vita scripts), then Phase C steps against the plan with generated shaders from `mbsc`.
3. Phase V (Vita), reusing `mbsc --emit-cg` + committed `.gxp`.
4. Then G (3D games), then H.
5. In parallel when convenient: S6 runtime applier, real-hardware tests of the PICA and TexEnv output, S8a.
