# Porting games/the-game to full-rewrite (PC only first)

Decided 2026-11-27: PC only first; 3DS and Vita come after the port works. Collision stays in the game (see memory). Retargeting is a runtime PC-only API, as on `main`.

## What the game's levels use (read from levels/*.json)
- Sky: always `NONE`. Skybox is **not** needed.
- Lights: point, spot, directional, and one `AREA_RECT` (bedroom). Fog off. Shadows enabled in two levels, with every shadow setting zero.
- Colliders: BOX only (45 / 36). Shapes: BOX. Camera shots on groups (`.TRACK` aim).
- Everything else is models: 36 to 58 per level.

## Pieces
1. **Renames in the game** (about 30 names, mechanical).
2. **`level` package** copied from `main` into `level/` here, minus the sky code. Needs from Matchbox:
   `Transform` from a matrix (and back), `Camera_Shot`/`fixed_camera` (present), `set_lights` (present), 3D debug wires for bounds (optional; the game calls `draw_bounds_wires`).
   Area light: map to a point light for now, with a logged note. Shadows: the level reads the setting and ignores it until Matchbox has shadow maps.
3. **Retargeting**, PC-only files named `*_windows.odin` so handheld builds never see them:
   `map_humanoid_bones`, `UNITY_BONE_NAMES`, `load_animation_source`, `retarget_animations`, ported from `main`'s `vrm.odin` (1,840 lines).
   Needs to attach clips to G6's `Animator` skeleton and clip types (`Model_Animation`, `Skeleton`).
4. **The game's own code** (collision, player, scene view) moves to the new names; the PSX filter is left out (the user ports it later).

## Public API this adds (needs the user's review before it is committed)
- Matchbox, PC only: the four retargeting procedures above.
- `level` package: `load_level`, `destroy_level`, `update_level`, `level_lights`, `draw_level`, `find_entity_path`, `camera_shot_from_entity`, `level_colliders`, as on `main`, renamed to house style (`render_level`, `get_level_lights`...).
- Possibly `render_bounding_box_wires` (3D) if the game needs the debug view.
