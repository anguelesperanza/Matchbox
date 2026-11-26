# G3: 3D cameras (plan)

Written 2026-11-25. Source: `main:matchbox/camera3d.odin`, `camera3d_drift.odin`, `camera3d_fixed.odin` (and their
tests). Target: `matchbox/camera.odin`'s `Camera`, which is already world units, +Y up, right-handed, looking down -Z,
with `fov_y` in degrees. Status of each step is ticked here; the public API (step 2) is the user's to approve.

## What "PSX camera systems" means

`Drift_Camera` and `Fixed_Camera` (survival-horror cameras). `main:matchbox/psx_geometry.odin` is **not** a camera: it
is vertex snapping and affine texturing done in the model's vertex/fragment shader and switched on through
`Lighting_Settings.psx`. It is a rendering effect, so it is not part of G3 (it would be its own shader task).

## Differences between `main` and this branch that shape the port

| Topic | `main` | This branch | Consequence |
|---|---|---|---|
| Camera type | `Camera3D` (fov, `near`/`far` zero-filled) | `Camera` (`fov_y`, `near`, `far`, `projection`) | rigs hold a `Camera`; needs a 3D constructor |
| Yaw 0 | looks along +X | camera looks down -Z | yaw 0 looks down -Z here, positive yaw turns left |
| Mouse look | `get_mouse_delta()` | no delta on any target | add `get_mouse_delta`; touch drag is the handhelds' look |
| Right stick | gamepad on PC | PC, Vita and 3DS C-stick all report `get_thumbstick_value(.RIGHT_THUMBSTICK)` | stick look on all targets |
| Wheel | `get_mouse_wheel` | `get_mouse_wheel_value` (always 0 on handhelds) | L/R shoulders zoom everywhere |
| Keys | WASD | keys exist only on PC | left stick moves on all targets, WASD as well on PC |
| Fixed camera shots | `[dynamic]` (heap, needs `destroy`) | 3DS/Vita runtime | fixed-size array, no `destroy` |
| Defaults | `CAMERA3D_DEFAULTS` package constant | no new package constants | defaulted constructor arguments and a `Camera_Look` struct |

## Table of `main`'s public surface and what it becomes

| `main` | Becomes | Notes |
|---|---|---|
| `Camera3D`, `Camera3D_Projection`, `create_camera3d` | `Camera`, `Projection`, new `create_camera_3d` | `fov` -> `fov_y`; zero-filling `camera3d_defaults` dropped |
| `camera3d_view`, `camera3d_projection`, `camera3d_view_projection` | exist: `calculate_camera_view_matrix`, `calculate_camera_projection_gl` | nothing to port |
| `camera3d_forward`, `camera3d_right` | `calculate_camera_forward`, `calculate_camera_right` | |
| `CAMERA3D_DEFAULTS`, `Camera3D_Defaults` | dropped | numbers move into constructor defaults and `Camera_Look` |
| `direction_from_angles` | `calculate_direction_from_angles` | -Z convention |
| `camera3d_angles`, `camera3d_orbit_angles` | `calculate_camera_angles` | |
| `camera3d_look`, `camera3d_zoom` | internal to the rigs' input procedures | now read mouse drag, right stick, L/R |
| `camera3d_aim`, `camera3d_follow`, `camera3d_orbit_position`, `camera3d_orbit_focus`, `camera3d_side_offset`, `camera3d_shoulder_amount`, `camera3d_third_person`, `camera3d_first_person` | dropped as loose pieces | the rig procedures below replace them; `calculate_orbit_position` stays public (wall-avoiding ray) |
| `walk_direction` | `calculate_walk_direction` | keyboard and left stick |
| `First_Person_Camera`, `create_first_person_camera`, `first_person_input`, `first_person_aim`, `first_person_walk` | `First_Person_Camera`, `create_first_person_camera`, `update_first_person_input`, `aim_first_person_camera`, `walk_first_person_camera` | `yaw`, `pitch`, sensitivity, limits grouped in `Camera_Look` |
| `Third_Person_Camera`, `create_third_person_camera`, `third_person_input`, `third_person_follow`, `third_person_walk` | `Third_Person_Camera`, `create_third_person_camera`, `update_third_person_input`, `follow_third_person_camera`, `walk_third_person_camera` | this is also the orbit camera: nothing in `main` orbits without it |
| `Camera3D_Shoulder`, `Camera3D_Steering` | `Camera_Shoulder`, `Camera_Steering` | values unchanged |
| `yaw_from_direction`, `turn_toward` | `calculate_yaw_from_direction`, `turn_angle_toward` | |
| `facing_rotation`, `Model_Facing`, `model_facing_rotation`, `facing_rotation_of`, `aim_rotation` | `calculate_facing_rotation`, `Model_Facing`, `calculate_aim_rotation` | character helpers, not cameras; small; optional |
| `Drift_Camera`, `create_drift_camera`, `drift_camera_follow`, `drift_camera_snap` | `Drift_Camera`, `create_drift_camera`, `follow_drift_camera`, `snap_drift_camera` | needs `exp`; check the 3DS libm |
| `Fixed_Camera`, `Camera_Shot`, `Camera_Shot_Aim`, `create_fixed_camera`, `fixed_camera_add_shot`, `fixed_camera_follow`, `destroy_fixed_camera` | same types, `create_fixed_camera`, `add_fixed_camera_shot`, `follow_fixed_camera`; no `destroy` | `[MAX_CAMERA_SHOTS]Camera_Shot` plus a count |
| `Character_Controls`, `character_steer` (movement3d.odin) | not ported | not a camera; only mentioned in main's comments |
| `psx_geometry.odin` | not ported | see above |

## Steps

- [ ] G3-1. Read main's cameras and write this plan. (done with this file)
- [ ] G3-2. **User approves the public API** (proposal sent with this file). Nothing below starts before.
- [ ] G3-3. Input: `get_mouse_delta` on PC (from `WM_MOUSEMOVE`), touch drag on the handhelds; tests drive `mbi`.
- [ ] G3-4. `create_camera_3d`, `Camera_Look`, direction/angle/walk helpers, `turn_angle_toward`; tests against numpy-checked values.
- [ ] G3-5. First- and third-person rigs; tests with synthetic input.
- [ ] G3-6. Drift and fixed cameras; tests ported from main's `camera3d_drift_test` and `camera3d_fixed_test`.
- [ ] G3-7. `examples/camera-check`: each camera, measured view matrices; `odin check`, `odin test`, `3ds_check.bat`, `vita_check.bat`, Azahar, Vita3K.
- [ ] G3-8. Uniquely named hardware builds in the main checkout's `build/hardware/`, then ask the user for the hardware check.
