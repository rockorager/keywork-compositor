#version 450
layout(push_constant) uniform Push {
    vec2 target_size;
    vec2 texture_size;
    float swap_rb;
    layout(offset=32) vec4 color_matrix_0;
    vec4 color_matrix_1;
    vec4 color_matrix_2;
    vec4 transfer;
    vec4 output_transfer;
    vec4 transfer_aux;
} pc;
layout(location=0) in vec4 in_dest;
layout(location=1) in vec4 in_source;
layout(location=2) in vec4 in_clip;
layout(location=3) in vec4 in_color;
layout(location=4) in vec4 in_rounded;
layout(location=5) in vec4 in_parameters;
layout(location=0) out vec2 pixel;
layout(location=1) flat out vec4 dest;
layout(location=2) flat out vec4 source;
layout(location=3) flat out vec4 color;
layout(location=4) flat out vec4 rounded;
layout(location=5) flat out vec4 parameters;
void main() {
    vec2 q=vec2(float(gl_VertexIndex&1),float((gl_VertexIndex>>1)&1));
    vec2 pos=in_clip.xy+q*in_clip.zw;
    gl_Position=vec4(pos/pc.target_size*2.0-1.0,0,1);
    pixel=pos;
    dest=in_dest;
    source=in_source;
    color=in_color;
    rounded=in_rounded;
    parameters=in_parameters;
}
