#version 460
#extension GL_EXT_buffer_reference : require
#extension GL_EXT_buffer_reference2 : require
#extension GL_EXT_nonuniform_qualifier : require
#extension GL_EXT_scalar_block_layout : require
#extension GL_EXT_shader_image_load_formatted : require
#extension GL_EXT_debug_printf : require
layout(set = 0, binding = 0) uniform texture2D _res_textures_[];
layout(set = 1, binding = 0) uniform image2D _res_textures_rw_[];
layout(set = 2, binding = 0) uniform sampler _res_samplers_[];


// Intrinsics:

#define texture_sample(t, s, uv)       texture(sampler2D(_res_textures_[nonuniformEXT(t)], _res_samplers_[nonuniformEXT(s)]), uv)
#define texture_load(t, coord)         imageLoad(_res_textures_rw_[nonuniformEXT(t)], ivec2(coord))
#define texture_store(t, coord, value) imageStore(_res_textures_rw_[nonuniformEXT(t)], ivec2(coord), value)
#define texture_size(t, s, lod)        textureSize(sampler2D(_res_textures_[nonuniformEXT(t)], _res_samplers_[nonuniformEXT(s)]), lod)
#define image_size(t)                  imageSize(_res_textures_rw_[nonuniformEXT(t)])

// Intrinsics end.

bool bool_ZERO;
int int_ZERO;
uint uint_ZERO;
float float_ZERO;
vec2 vec2_ZERO;
vec3 vec3_ZERO;
vec4 vec4_ZERO;
mat4 mat4_ZERO;
uint texture_id_ZERO;
uint sampler_id_ZERO;
uint bvh_id_ZERO;

layout(location = 0) out vec2 _res_out_loc0_;

layout(buffer_reference) readonly buffer _res_ptr_void;
layout(buffer_reference) readonly buffer _res_slice_Vertex;
layout(buffer_reference) readonly buffer _res_ptr_Data;

struct Vertex
{
    vec3 pos_;
    vec2 uv_;
};
Vertex Vertex_ZERO;
struct Data
{
    _res_slice_Vertex verts_;
    vec2 position_;
    vec2 size_;
    vec2 screen_;
    float rotation_;
    uint flip_x_;
    uint flip_y_;
    vec2 uv_min_;
    vec2 uv_max_;
    uint _res_padding_0;
};
Data Data_ZERO;
struct Output
{
    vec4 pos_;
    vec2 uv_;
};
Output Output_ZERO;
void main();
layout(buffer_reference, scalar) readonly buffer _res_ptr_void { uint _res_void_; };
layout(buffer_reference, scalar) readonly buffer _res_slice_Vertex { Vertex _res_[]; };
_res_slice_Vertex _res_slice_Vertex_ZERO;
layout(buffer_reference, scalar) readonly buffer _res_ptr_Data { Data _res_; };
_res_ptr_Data _res_ptr_Data_ZERO;

layout(push_constant, scalar) uniform Push
{
    _res_ptr_Data _res_vert_data_;
    _res_ptr_Data _res_frag_data_;
    _res_ptr_void _res_indirect_data_;
};

void main()
{
    uint vert_id_ = gl_VertexIndex;
    _res_ptr_Data data_ = _res_vert_data_;
    Output out_ = Output_ZERO;
    vec2 local_ = vec2_ZERO;
    float s_ = float_ZERO;
    float c_ = float_ZERO;
    vec2 rotated_ = vec2_ZERO;
    vec2 world_ = vec2_ZERO;
    vec2 ndc_ = vec2_ZERO;
    vec2 base_uv_ = vec2_ZERO;
    local_ = (data_._res_.verts_._res_[vert_id_].pos_.xy * data_._res_.size_);
    s_ = sin(data_._res_.rotation_);
    c_ = cos(data_._res_.rotation_);
    rotated_ = vec2(((local_.x * c_) - (local_.y * s_)), ((local_.x * s_) + (local_.y * c_)));
    world_ = (rotated_ + data_._res_.position_);
    ndc_ = (((world_ / data_._res_.screen_) * 2.0) - 1.0);
    out_.pos_ = vec4(ndc_, 0.0, 1.0);
    base_uv_ = data_._res_.verts_._res_[vert_id_].uv_;
    out_.uv_ = (data_._res_.uv_min_ + (base_uv_ * (data_._res_.uv_max_ - data_._res_.uv_min_)));
    gl_Position = out_.pos_; _res_out_loc0_ = out_.uv_; 
}

