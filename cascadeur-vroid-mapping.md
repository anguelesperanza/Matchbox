# Cascadeur rig slots -> VRoid bone names

Cascadeur's Rigging tool asks for its own generic humanoid slots. When the
skeleton being rigged is a VRoid export, each slot maps onto one `J_Bip_*`
bone as follows.

| Cascadeur slot | VRoid bone |
|---|---|
| `pelvis` | `J_Bip_C_Hips` |
| `stomach` | `J_Bip_C_Spine` |
| `chest` | `J_Bip_C_Chest` |
| `neck` | `J_Bip_C_Neck` |
| `head` | `J_Bip_C_Head` |
| `clavicle_l` / `clavicle_r` | `J_Bip_L_Shoulder` / `J_Bip_R_Shoulder` |
| `arm_l` / `arm_r` | `J_Bip_L_UpperArm` / `J_Bip_R_UpperArm` |
| `forearm_l` / `forearm_r` | `J_Bip_L_LowerArm` / `J_Bip_R_LowerArm` |
| `hand_l` / `hand_r` | `J_Bip_L_Hand` / `J_Bip_R_Hand` |
| `weapon_l` / `weapon_r` | leave `None` -- Cascadeur's own prop socket, no VRoid equivalent |
| `thigh_l` / `thigh_r` | `J_Bip_L_UpperLeg` / `J_Bip_R_UpperLeg` |
| `calf_l` / `calf_r` | `J_Bip_L_LowerLeg` / `J_Bip_R_LowerLeg` |
| `foot_l` / `foot_r` | `J_Bip_L_Foot` / `J_Bip_R_Foot` |
| `toe_l` / `toe_r` | `J_Bip_L_ToeBase` / `J_Bip_R_ToeBase` |
| `thumb_l/r_1/2/3` | `J_Bip_L/R_Thumb1/2/3` |
| `index_finger_l/r_1/2/3` | `J_Bip_L/R_Index1/2/3` |
| `middle_finger_l/r_1/2/3` | `J_Bip_L/R_Middle1/2/3` |
| `ring_finger_l/r_1/2/3` | `J_Bip_L/R_Ring1/2/3` |
| `pinky_l/r_1/2/3` | `J_Bip_L/R_Little1/2/3` |

VRoid also exports `J_Bip_C_UpperChest`, which has no matching Cascadeur
slot -- that bone simply goes unused inside Cascadeur's rig.

## Why this mapping doesn't carry over to Matchbox by itself

The table above only drives Cascadeur's internal rig (FK/IK, its own
retargeting tool). What Matchbox reads is the literal bone-name strings baked
into whatever file the finished animation is exported as -- `retarget_animations`
(`matchbox/vrm.odin:751`) matches source bones by name string through a
lookup table, not by hierarchy or by this Cascadeur mapping. The destination
(VRM) side is always resolved through the VRM file's own `humanoid` block, so
the VRoid model's bone names never matter there -- only the exported clip's
names do.

Matchbox's default table, `UNREAL_BONE_NAMES` (`matchbox/vrm.odin:473`),
expects Unreal/Mesh2Motion-style strings (`upperarm_l`, `lowerarm_l`, `ball_l`,
`thumb_01_l`, `neck_01`, ...). Cascadeur's own slot names (`arm_l`,
`forearm_l`, `toe_l`, `thumb_l_1`) don't match those strings, so if the
exported clip carries Cascadeur's own naming, `retarget_animations` with the
default table will find nothing.

Two ways to close that gap:

1. Check the actual joint names in the exported FBX/glTF -- Cascadeur may
   preserve the original `J_Bip_*` names on export rather than its display
   labels. Whichever names show up, write a `[]Vrm_Bone_Name` table (same
   shape as `UNREAL_BONE_NAMES`) and pass it to `load_animation_source` /
   `retarget_animations` instead of the default.
2. Or rename joints during Cascadeur's export step to match the existing
   `UNREAL_BONE_NAMES` strings, and keep using the default table unmodified.

## Rest pose

The retarget math assumes the source clip's rest pose is the same physical
pose as the VRM's rest pose (T-pose), not just a differently-labeled
skeleton. If Cascadeur's bind pose is an A-pose or otherwise differs,
animations will come out distorted even with correct bone-name mapping.
Matchbox has a fix for exactly this: `rest_pose_path` / `adopt_rest_pose`
(`matchbox/vrm.odin:554-650`), explained in `vrm.md:290-339`. If needed,
export a separate T-pose-only file of the same rig and pass it as
`rest_pose_path`, following the pattern in
`examples/animation-layers/main.odin:73`.
