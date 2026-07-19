#version 450
layout(push_constant) uniform Push {
    vec2 target_size;
    vec2 texture_size;
    float swap_rb;
} pc;
layout(location=3) flat in vec4 color;
layout(location=0) out vec4 out_color;
void main() { out_color=pc.swap_rb>0.5 ? color.bgra : color; }
