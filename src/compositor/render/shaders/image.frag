#version 450
layout(set=0,binding=0) uniform sampler2D tex;
layout(push_constant) uniform Push {
    vec2 target_size;
    vec2 texture_size;
    float swap_rb;
} pc;
layout(location=0) in vec2 pixel;
layout(location=1) flat in vec4 dest;
layout(location=2) flat in vec4 source;
layout(location=4) flat in vec4 rounded;
layout(location=5) flat in vec4 parameters;
layout(location=0) out vec4 out_color;
void main() {
    vec2 q=(pixel-dest.xy)/dest.zw;
    vec2 transformed=source.xy+q*source.zw;
    vec2 coordinate;
    switch (int(parameters.y)) {
        case 1: coordinate=vec2(transformed.y,pc.texture_size.y-transformed.x); break;
        case 2: coordinate=pc.texture_size-transformed; break;
        case 3: coordinate=vec2(pc.texture_size.x-transformed.y,transformed.x); break;
        case 4: coordinate=vec2(pc.texture_size.x-transformed.x,transformed.y); break;
        case 5: coordinate=pc.texture_size-transformed.yx; break;
        case 6: coordinate=vec2(transformed.x,pc.texture_size.y-transformed.y); break;
        case 7: coordinate=transformed.yx; break;
        default: coordinate=transformed; break;
    }
    if (parameters.z>0.5) coordinate.y=pc.texture_size.y-coordinate.y;
    vec2 uv=coordinate/pc.texture_size;
    vec4 color=texture(tex,uv);
    if (pc.swap_rb>0.5) color=color.bgra;
    color*=parameters.w;
    if (parameters.x>0.0) {
        vec2 center=clamp(pixel,rounded.xy+vec2(parameters.x),rounded.xy+rounded.zw-vec2(parameters.x));
        float coverage=clamp(parameters.x+0.5-distance(pixel,center),0.0,1.0);
        color*=coverage;
    }
    out_color=pc.swap_rb>0.5 ? color.bgra : color;
}
