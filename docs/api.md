```odin
create_animation_clip :: proc(texture:Texture, seconds_per_frame:f32) -> Animation_Clip
animation_range :: proc(clip:Animation_Clip, first, last:int, seconds_per_frame:f32 = 0) -> Animation_Clip
create_animated_sprite_from_clip :: proc(clip:Animation_Clip, scale:f32 = 1, looping := true, pixels_per_unit:f32 = 0) -> Animated_Sprite
destroy_animation_clip :: proc(clip:Animation_Clip)
switch_animation :: proc(sprite:^Animated_Sprite, clip:Animation_Clip, looping := true)
queue_animation :: proc(sprite:^Animated_Sprite, clip:Animation_Clip, looping:bool)
update_animation :: proc(sprite:^Animated_Sprite, delta_time:f32)
calculate_animation_frame :: proc(sprite:Animated_Sprite) -> int
is_animation_in_window :: proc(sprite:Animated_Sprite, first, last:int) -> bool
calculate_animation_render_offset :: proc(sprite:Animated_Sprite) -> [2]f32
render_animated_sprite :: proc(sprite:Animated_Sprite, mode:Sprite_Mode = .CUTOUT)

create_animator :: proc(model:Model, blend := Animation_Blend{enabled = true, duration = 0.2}) -> Animator
destroy_animator :: proc(animator:^Animator)
get_animation_index :: proc(model:Model, name:string) -> (index:int, found:bool)
get_animation_names :: proc(model:Model, allocator := context.temp_allocator) -> []string
get_node_index :: proc(model:Model, name:string) -> (node:u32, found:bool)
calculate_node_matrix :: proc(model:Model, animator:Animator, node:u32) -> matrix[4, 4]f32
calculate_node_world_matrix :: proc(model:Model, animator:Animator, node:u32, transform:Transform) -> matrix[4, 4]f32
play_animation :: proc(animator:^Animator, model:Model, name:string, looping := true) -> bool
play_animation_index :: proc(animator:^Animator, model:Model, index:int, looping := true)
stop_animation :: proc(animator:^Animator)
update_animator :: proc(animator:^Animator, model:Model, delta_time:f32)
play_animation_layer :: proc(animator:^Animator, model:Model, layer:int, name:string, mask:[]f32 = nil, mode := Animation_Layer_Mode.REPLACE, looping := true) -> bool
play_animation_layer_index :: proc(animator:^Animator, model:Model, layer:int, index:int, mask:[]f32 = nil, mode := Animation_Layer_Mode.REPLACE, looping := true) -> bool
stop_animation_layer :: proc(animator:^Animator, layer:int)
set_animation_layer_weight :: proc(animator:^Animator, layer:int, weight:f32)
set_animation_layer_mask :: proc(animator:^Animator, layer:int, mask:[]f32) -> bool
calculate_animation_mask_below :: proc(model:Model, root:u32, falloff := 0, allocator := context.temp_allocator) -> []f32
calculate_animation_mask_named :: proc(model:Model, names:[]string, allocator := context.temp_allocator) -> []f32

calculate_skybox_rays :: proc(view:matrix[4, 4]f32, fov_y:f32, aspect:f32) -> Skybox_Rays
split_cubemap_cross :: proc(pixels:[][4]u8, width, height:int, allocator := context.allocator) -> (faces:[6][][4]u8, face_size:int, ok:bool)
// PC only. On the 3DS and Vita these names exist and panic "A skybox is PC only for now"; destroy_skybox is empty there
create_skybox_cubemap :: proc(faces:[6]rawptr, face_size:i32) -> (skybox:Skybox)
create_skybox_panorama :: proc(pixels:rawptr, width, height:i32) -> (skybox:Skybox)
load_skybox_cubemap :: proc(filename:string) -> (skybox:Skybox)
load_skybox_panorama :: proc(filename:string) -> (skybox:Skybox)
render_skybox :: proc(skybox:Skybox)
destroy_skybox :: proc(skybox:Skybox)

// Runtime humanoid retargeting. PC only (humanoid_windows.odin, retarget_windows.odin): not compiled for the handhelds, and not in the `destroy` group
// Types: Humanoid_Bone, Humanoid_Map, Humanoid_Bone_Name, Animation_Source, Retarget_Options{names, fit}, Retarget_Fit{PROPORTIONS, ROTATION_ONLY}
// Name tables: UNITY_BONE_NAMES (a character's usual), UNREAL_BONE_NAMES (Mesh2Motion and Quaternius clip libraries; the default source)
map_humanoid_bones :: proc(model:Model, names:[]Humanoid_Bone_Name = UNITY_BONE_NAMES) -> (humanoid:Humanoid_Map, mapped:int)
get_humanoid_node :: proc(humanoid:Humanoid_Map, bone:Humanoid_Bone) -> (node:u32, found:bool)
load_animation_source :: proc(path:string, rest_pose_path := "") -> (source:Animation_Source, ok:bool)
destroy_animation_source :: proc(source:Animation_Source)
retarget_animations :: proc(model:^Model, humanoid:Humanoid_Map, source:Animation_Source, options:Retarget_Options = {}) -> (added:int)

load_audio :: proc(filepath:string) -> (audio:Audio)
play_audio :: proc(audio:Audio)
destroy_audio :: proc(audio:Audio)

calculate_billboard_matrix :: proc(camera:Camera, position:[3]f32, size := [2]f32{1, 1}, settings := Billboard_Settings{}, roll:f32 = 0) -> matrix[4, 4]f32
render_billboard :: proc(sprite:Sprite, settings := Billboard_Settings{}, mode:Sprite_Mode = .CUTOUT)
render_animated_billboard :: proc(sprite:Animated_Sprite, settings := Billboard_Settings{}, mode:Sprite_Mode = .CUTOUT)

calculate_bottom_screen_view_height :: proc(height:f32, aspect:f32) -> f32

set_bottom_screen :: proc(layout:Bottom_Screen_Layout)
get_bottom_screen_layout :: proc() -> Bottom_Screen_Layout
is_bottom_screen_visible :: proc() -> bool
bottom_screen_start :: proc()
bottom_screen_end :: proc()
calculate_bottom_screen_visible_rectangle :: proc() -> (min, max:[2]f32)
calculate_bottom_screen_anchor_position :: proc(anchor:Anchor, offset:[2]f32 = {}) -> [3]f32
calculate_mouse_bottom_screen_position :: proc() -> (position:[2]f32, inside:bool)

calculate_camera_view_height :: proc(camera:Camera) -> f32
calculate_camera_view_matrix :: proc(camera:Camera) -> matrix[4,4]f32
calculate_camera_projection_gl :: proc(camera:Camera, aspect:f32) -> matrix[4, 4]f32
create_camera_2d :: proc(view_height:f32 = 0) -> Camera
is_point_in_rectangle :: proc(point, min, max:[2]f32) -> bool
calculate_model_matrix :: proc(position:[3]f32 = {0, 0, 0}, rotation:quaternion128 = linalg.QUATERNIONF32_IDENTITY, scale:[3]f32 = {1, 1, 1}) -> matrix[4, 4]f32
calculate_rotation_axis_angle :: proc(axis:[3]f32, angle:f32) -> quaternion128
calculate_rotation_euler :: proc(pitch:f32 = 0, yaw:f32 = 0, roll:f32 = 0) -> quaternion128
camera_follow :: proc(camera:^Camera, target:[2]f32, speed:f32, delta_time:f32)
calculate_screen_to_world_2d :: proc(camera:Camera, screen:[2]f32, window:[2]f32) -> [2]f32
calculate_camera_snap_scale :: proc(camera:Camera, window_height:f32) -> f32
calculate_snapped_to_pixel :: proc(value:f32, scale:f32) -> f32
calculate_camera_snapped :: proc(camera:Camera, window:[2]f32) -> Camera
camera_set_pixel_scale :: proc(camera:^Camera, pixels_per_unit:f32, scale:f32, window_height:f32)
calculate_integer_zoom :: proc(design_height:f32, window_height:f32 = 0) -> f32
create_screen_camera :: proc(view_height:f32) -> Camera
calculate_camera_visible_rectangle :: proc(camera:Camera, aspect:f32) -> (min, max:[2]f32)
calculate_camera_anchor_position :: proc(camera:Camera, aspect:f32, anchor:Anchor, offset:[2]f32 = {}) -> [3]f32

create_camera_3d :: proc(position:[3]f32, target:[3]f32, fov_y:f32 = 70, near:f32 = 0.1, far:f32 = 1000) -> Camera
calculate_camera_forward :: proc(camera:Camera) -> [3]f32
calculate_camera_right :: proc(camera:Camera) -> [3]f32
calculate_direction_from_angles :: proc(yaw:f32, pitch:f32) -> [3]f32
calculate_camera_angles :: proc(camera:Camera) -> (yaw:f32, pitch:f32)
calculate_yaw_from_direction :: proc(direction:[3]f32) -> f32
calculate_walk_direction :: proc(yaw:f32, input:[2]f32) -> [3]f32
turn_angle_toward :: proc(angle:^f32, target:f32, speed:f32, delta_time:f32)
calculate_orbit_position :: proc(focus:[3]f32, yaw:f32, pitch:f32, distance:f32) -> [3]f32
calculate_facing_rotation :: proc(yaw:f32, facing:Model_Facing = .NEG_Z) -> quaternion128
calculate_aim_rotation :: proc(yaw:f32, pitch:f32, facing:Model_Facing = .NEG_Z) -> quaternion128
create_first_person_camera :: proc(position:[3]f32 = {0, 0, 0}, yaw:f32 = 0, pitch:f32 = 0, eye_offset:[3]f32 = {0, 1.7, 0}, fov_y:f32 = 70, near:f32 = 0.1, far:f32 = 1000, sensitivity:f32 = 0.003, stick_speed:f32 = 2.5, pitch_min:f32 = -1.56, pitch_max:f32 = 1.56) -> First_Person_Camera
update_first_person_input :: proc(rig:^First_Person_Camera)
aim_first_person_camera :: proc(rig:^First_Person_Camera, position:[3]f32)
walk_first_person_camera :: proc(rig:^First_Person_Camera, position:^[3]f32, speed:f32, delta_time:f32)
create_third_person_camera :: proc(position:[3]f32 = {0, 0, 0}, facing:f32 = 0, focus_offset:[3]f32 = {0, 1.6, 0}, distance:f32 = 6, pitch:f32 = -0.3, shoulder:Camera_Shoulder = .CENTER, shoulder_offset:f32 = 0.75, steering:Camera_Steering = .CAMERA, turn_speed:f32 = 12, fov_y:f32 = 70, near:f32 = 0.1, far:f32 = 1000, sensitivity:f32 = 0.003, stick_speed:f32 = 2.5, pitch_min:f32 = -1.30, pitch_max:f32 = 0.30, zoom_speed:f32 = 1, distance_min:f32 = 1.5, distance_max:f32 = 20) -> Third_Person_Camera
update_third_person_input :: proc(rig:^Third_Person_Camera)
follow_third_person_camera :: proc(rig:^Third_Person_Camera, position:[3]f32, delta_time:f32)
walk_third_person_camera :: proc(rig:^Third_Person_Camera, position:^[3]f32, speed:f32, delta_time:f32)

create_drift_camera :: proc(position:[3]f32 = {0, 0, 0}, yaw:f32 = 0, pitch:f32 = -0.3, distance:f32 = 6, dead_zone:f32 = 1.5, follow_speed:f32 = 3, swing_speed:f32 = 0, focus_offset:[3]f32 = {0, 1.6, 0}, fov_y:f32 = 70, near:f32 = 0.1, far:f32 = 1000) -> Drift_Camera
follow_drift_camera :: proc(rig:^Drift_Camera, position:[3]f32, delta_time:f32)
snap_drift_camera :: proc(rig:^Drift_Camera, position:[3]f32)

create_fixed_camera :: proc(focus_offset:[3]f32 = {0, 1.6, 0}, near:f32 = 0.1, far:f32 = 1000) -> Fixed_Camera
add_fixed_camera_shot :: proc(rig:^Fixed_Camera, shot:Camera_Shot) -> int
follow_fixed_camera :: proc(rig:^Fixed_Camera, position:[3]f32)

get_mouse_delta :: proc() -> [2]f32
get_camera_look_input :: proc(sensitivity:f32, stick_speed:f32, delta_time:f32) -> [2]f32
get_camera_zoom_input :: proc(speed:f32, delta_time:f32) -> f32
get_movement_input :: proc() -> [2]f32

get_delta_time :: proc() -> f32
get_time :: proc() -> f64

is_bounding_box_collision :: proc(a_min, a_max, b_min, b_max:[2]f32) -> bool
is_bounding_box_contact :: proc(a_min, a_max, b_min, b_max:[2]f32) -> bool
calculate_sprite_collision_bounds :: proc(sprite:Sprite) -> (min, max:[2]f32)
is_sprite_collision :: proc(a, b:Sprite) -> bool
is_sprite_contact :: proc(a, b:Sprite) -> bool
calculate_sprite_clamped_position :: proc(sprite:Sprite, area_min, area_max:[2]f32) -> [3]f32
is_mouse_over_sprite :: proc(sprite:Sprite, camera:Camera) -> bool
render_bounding_box_outline :: proc(sprite:Sprite, color:[4]f32, thickness:f32, in_front:f32 = 0.01)

start_cooldown :: proc(cooldown:^Cooldown, duration:f32)
update_cooldown :: proc(cooldown:^Cooldown, delta_time:f32)
stop_cooldown :: proc(cooldown:^Cooldown)
is_cooldown_finished :: proc(cooldown:Cooldown) -> bool
is_cooldown_running :: proc(cooldown:Cooldown) -> bool
calculate_cooldown_progress :: proc(cooldown:Cooldown) -> f32

destroy :: proc{ destroy_audio, destroy_mesh, destroy_model, destroy_texture, destroy_render_target, destroy_sprite, destroy_animation_clip, destroy_parallax, destroy_font, destroy_skybox, destroy_shader }

poll_events :: proc()

create_font :: proc(bytes:[]byte, pixel_size:f32, pixels_per_unit:f32 = 0, filter:Filter_Mode = .LINEAR) -> (font:Font)
destroy_font :: proc(font:Font)

is_gamepad_pressed :: proc (button:Button, id:i32 = 0) -> bool
is_gamepad_held :: proc (button:Button, id:i32 = 0) -> bool
is_gamepad_released :: proc (button:Button, id:i32 = 0) -> bool
get_thumbstick_value :: proc(thumbstick:Button) -> (axis:[2]f32)
get_trigger_value :: proc(trigger:Button) -> f32
is_key_pressed :: proc(key:Key) -> bool
is_key_held :: proc(key:Key) -> bool
is_key_released :: proc(key:Key) -> bool
get_mouse_position :: proc() -> [2]i32
get_mouse_wheel_value :: proc() -> i16
is_mouse_pressed :: proc(mouse:Mouse) -> bool
is_mouse_held :: proc(mouse:Mouse) -> bool
is_mouse_released :: proc(mouse:Mouse) -> bool
set_mouse_capture :: proc()
release_mouse_capture :: proc()
is_mouse_captured :: proc() -> bool
calculate_mouse_world_position :: proc(camera:Camera) -> [2]f32

create_directional_light :: proc(direction:[3]f32, color:[4]f32 = WHITE) -> Light
create_point_light :: proc(position:[3]f32, color:[4]f32 = WHITE) -> Light
create_spot_light :: proc(position, direction:[3]f32, color:[4]f32 = WHITE, inner_angle:f32 = 20, outer_angle:f32 = 30) -> Light
set_lights :: proc(lights:[]Light)
set_lighting :: proc(settings := Lighting_Settings{enabled = true, ambient = {0.2, 0.2, 0.2, 1}})
get_max_lights :: proc() -> int

create_cube_geometry :: proc(size:f32 = 1, colored:bool = true, allocator := context.allocator) -> (vertices:[]Lit_Vertex, indices:[]u16)
create_quad_geometry :: proc(size:f32 = 1, color:[4]f32 = {1, 1, 1, 1}, allocator := context.allocator) -> (vertices:[]Vertex, indices:[]u16)
create_triangle_geometry :: proc(allocator := context.allocator) -> (vertices:[]Vertex, indices:[]u16)
create_circle_geometry :: proc(segments:int = 48, allocator := context.allocator) -> (vertices:[]Vertex, indices:[]u16)
create_plane_geometry :: proc(size:f32 = 1, allocator := context.allocator) -> (vertices:[]Lit_Vertex, indices:[]u16)
create_sphere_geometry :: proc(radius:f32 = 1, rings:int = 16, sectors:int = 24, allocator := context.allocator) -> (vertices:[]Lit_Vertex, indices:[]u16)
create_cylinder_geometry :: proc(radius:f32 = 0.5, height:f32 = 1, sectors:int = 24, allocator := context.allocator) -> (vertices:[]Lit_Vertex, indices:[]u16)

create_transform :: proc(position:[3]f32 = {}, rotation:quaternion128 = linalg.QUATERNIONF32_IDENTITY, scale:f32 = 1) -> Transform
calculate_transform_matrix :: proc(transform:Transform) -> matrix[4, 4]f32
calculate_transform_pivoted :: proc(transform:Transform, pivot:[3]f32) -> Transform
calculate_model_center :: proc(model:Model) -> [3]f32
calculate_model_size :: proc(model:Model) -> [3]f32
render_model :: proc{ render_model_transform, render_model_at, render_model_pivoted, render_model_animated }
render_model_transform :: proc(model:Model, transform:Transform, tint:[4]f32 = {1, 1, 1, 1})
render_model_animated :: proc(model:Model, animator:Animator, transform:Transform, tint:[4]f32 = {1, 1, 1, 1})
render_model_at :: proc(model:Model, position:[3]f32, tint:[4]f32 = {1, 1, 1, 1})
render_model_pivoted :: proc(model:Model, pivot:[3]f32, transform:Transform, tint:[4]f32 = {1, 1, 1, 1})
create_model_from_mesh :: proc(vertices:[]Lit_Vertex, indices:[]u16) -> (model:Model)
create_model_from_data :: proc(data:Model_Data, textures:[]Texture) -> (model:Model)
destroy_model :: proc(model:Model)
calculate_material_from_roughness :: proc(roughness, metallic:f32) -> Material
create_cube_model :: proc(size:f32 = 1) -> Model
create_plane_model :: proc(size:f32 = 1) -> Model
create_sphere_model :: proc(radius:f32 = 1, rings:int = 16, sectors:int = 24) -> Model
create_cylinder_model :: proc(radius:f32 = 0.5, height:f32 = 1, sectors:int = 24) -> Model

load_model :: proc(filename:string, filter:Filter_Mode = .POINT) -> (model:Model)

create_character_controls :: proc(facing:f32 = 0, scheme:Control_Scheme = .TANK, tank_turn_speed:f32 = 3, backward_speed:f32 = 0.6, turn_speed:f32 = 12, hold_basis:bool = true, hold_tolerance:f32 = math.PI / 3) -> Character_Controls
steer_character :: proc(controls:^Character_Controls, input:[2]f32, camera:Camera, delta_time:f32)
walk_character :: proc(controls:^Character_Controls, position:^[3]f32, speed:f32, camera:Camera, delta_time:f32)

render_mesh :: proc(mesh:Mesh, model:matrix[4, 4]f32 = linalg.MATRIX4F32_IDENTITY, tint:[4]f32 = {1, 1, 1, 1}, blend:Blend_Mode = .NONE, cull:Cull_Mode = .BACK, texture:Texture = {})

calculate_upscaled_rectangle :: proc(target:Render_Target, fit := Fit_Mode.FIT) -> (min, max:[2]f32)
calculate_target_position :: proc(target:Render_Target, window_position:[2]f32, fit := Fit_Mode.FIT) -> [2]f32
create_render_target :: proc(settings := Render_Target_Settings{}) -> (target:Render_Target)
destroy_render_target :: proc(target:^Render_Target)
render_target_start :: proc(target:^Render_Target, clear_color:Maybe([4]f32) = [4]f32{0, 0, 0, 0})
render_target_end :: proc()
render_upscaled_target :: proc(target:Render_Target, fit := Fit_Mode.FIT, tint := [4]f32{1, 1, 1, 1}, shader := Shader{})
set_internal_resolution :: proc(settings := Internal_Resolution_Settings{})
get_internal_resolution :: proc() -> [2]i32

read_render_target_pixels :: proc(target:Render_Target, allocator := context.allocator) -> []u8

create_mesh :: proc(vertices:[]Vertex, indices:[]u16) -> (mesh:Mesh)
create_lit_mesh :: proc(vertices:[]Lit_Vertex, indices:[]u16) -> (mesh:Mesh)
create_skinned_mesh :: proc(vertices:[]Skinned_Vertex, indices:[]u16) -> (mesh:Mesh)
destroy_mesh :: proc(mesh:Mesh)
set_shader_value :: proc(name:string, value:any, shader := Shader{})

// Game shaders (shader.odin, docs/game_shaders_plan.md). A shader exists only after the game loads it; the PSX ones are in
// matchbox/optional/shaders/ and a game copies the ones it uses into assets/pc/shaders/. PC only: on the 3DS and Vita
// load_shader panics "Custom shaders are PC only for now"
load_shader :: proc(name:string) -> Shader
load_shader_checked :: proc(name:string) -> (Shader, bool)
destroy_shader :: proc(shader:Shader)
set_shader :: proc(shader:Shader)
get_gpu_times :: proc() -> [2]f32
render_start :: proc()
render_end :: proc()
clear_background :: proc(color:[4]f32)
uses :: proc(kind:Block_Kind) -> bool
camera_start :: proc(camera:Camera)
camera_end :: proc()

set_screen_height :: proc(units:f32)
screen_start :: proc()
screen_end :: proc()
calculate_visible_rectangle :: proc() -> (min, max:[2]f32)
calculate_anchor_position :: proc(anchor:Anchor, offset:[2]f32 = {}) -> [3]f32
calculate_mouse_screen_position :: proc() -> [2]f32

render_rectangle :: proc(position:[3]f32, size:[2]f32, color:[4]f32, rotation:f32 = 0, pivot:[2]f32 = {0.5, 0.5})
render_circle :: proc(position:[3]f32, radius:f32, color:[4]f32)
render_triangle :: proc(a, b, c:[3]f32, color:[4]f32)
render_line :: proc(start, end:[3]f32, thickness:f32, color:[4]f32)
render_rectangle_outline :: proc(min, max:[2]f32, z:f32, thickness:f32, color:[4]f32)

is_model_skinned :: proc(model:Model) -> bool

create_sprite :: proc(texture:Texture, position:[3]f32 = {}, pixels_per_unit:f32 = 0) -> Sprite
calculate_sprite_bounds :: proc(sprite:Sprite) -> (min, max:[2]f32)
render_sprite :: proc(sprite:Sprite, mode:Sprite_Mode = .CUTOUT)
destroy_sprite :: proc(sprite:Sprite)

render_text_string :: proc(font:Font, text:string, position:[3]f32, color:[4]f32 = {1, 1, 1, 1})
render_text_i64 :: proc(font:Font, integer:i64, position:[3]f32, color:[4]f32 = {1, 1, 1, 1})
render_text_float :: proc(font:Font, value:$T, position:[3]f32, color:[4]f32 = {1, 1, 1, 1})
render_text_2_float :: proc(font:Font, value:[2]$T, position:[3]f32, color:[4]f32 = {1, 1, 1, 1}, separator:string = " ")
render_text_2_i64 :: proc(font:Font, values:[2]i64, position:[3]f32, color:[4]f32 = {1, 1, 1, 1}, separator:string = " ")
render_text :: proc{ render_text_string, render_text_i64, render_text_float, render_text_2_float, render_text_2_i64 }
calculate_text_size :: proc(font:Font, text:string) -> [2]f32
calculate_line_height :: proc(font:Font, spacing:f32 = mbi.font_settings.line_spacing) -> f32
calculate_text_block_height :: proc(font:Font, count:int, spacing:f32 = mbi.font_settings.line_spacing) -> f32
wrap_text :: proc(font:Font, text:string, max_width:f32, allocator := context.allocator) -> []string
render_text_wrapped :: proc(font:Font, text:string, top_left:[3]f32, max_width:f32, color:[4]f32 = {1, 1, 1, 1}, spacing:f32 = mbi.font_settings.line_spacing) -> [2]f32
render_text_lines :: proc(font:Font, lines:[]string, top_left:[3]f32, color:[4]f32 = {1, 1, 1, 1}, spacing:f32 = mbi.font_settings.line_spacing) -> [2]f32
calculate_text_wrapped_size :: proc(font:Font, text:string, max_width:f32, spacing:f32 = mbi.font_settings.line_spacing) -> [2]f32

calculate_texture_frame_rectangle :: proc(texture:Texture, frame:int) -> [4]f32

load_texture :: proc(filename:string, filter:Filter_Mode = .LINEAR) -> (texture:Texture)
create_texture_from_pixels :: proc(pixels:rawptr, width, height:i32, filter:Filter_Mode = .LINEAR) -> (texture:Texture)
destroy_texture :: proc(texture:Texture)

calculate_thumbstick_dead_zone :: proc(axis:[2]f32, dead_zone:f32 = mbi.thumbstick_settings.dead_zone) -> [2]f32

print :: proc(args: ..any)
get_window_size :: proc() -> [4]i32
get_asset :: proc(filename:string, asset_type:Asset_Type) -> string

init :: proc(title:string, width:i32, height:i32)
is_running :: proc() -> bool
stop_running :: proc()
cleanup :: proc()
```
