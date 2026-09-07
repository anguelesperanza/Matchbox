/*
    The shadow pass's fragment shader, and it does nothing at all.

    The pass has zero colour targets -- only the depth attachment, which the
    rasterizer writes on its own from SV_Position.z -- so there is nothing
    here to compute and nowhere to write it. A fragment shader still has to
    exist and be bound: SDL_GPU wants a valid shader object for the stage
    even when the pipeline has no colour output.

    Paired with the existing mesh.vert.hlsl and mesh_skinned.vert.hlsl --
    see shadow.odin -- since the vertex layouts and uniforms they already
    declare are exactly what a shadow caster needs, once the light's own
    view-projection is pushed instead of the camera's.
*/
void main(float4 pos : SV_Position)
{
}
