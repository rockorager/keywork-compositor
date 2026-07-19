#version 450
layout(set=0,binding=0) uniform sampler2D tex;
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
layout(location=0) in vec2 pixel;
layout(location=5) flat in vec4 parameters;
layout(location=0) out vec4 out_color;
void main() {
    ivec2 coordinate=ivec2(pixel);
    int radius=int(parameters.x);
    int left=min(radius,coordinate.x);
    int right=min(radius,int(pc.texture_size.x)-1-coordinate.x);
    vec2 center=(vec2(coordinate)+vec2(0.5))/pc.texture_size;
    vec4 sum=texelFetch(tex,coordinate,0);
    for (int offset=1; offset<=left; offset+=2) {
        if (offset<left) {
            sum+=2.0*texture(tex,center-vec2(float(offset)+0.5,0.0)/pc.texture_size);
        } else {
            sum+=texelFetch(tex,coordinate-ivec2(offset,0),0);
        }
    }
    for (int offset=1; offset<=right; offset+=2) {
        if (offset<right) {
            sum+=2.0*texture(tex,center+vec2(float(offset)+0.5,0.0)/pc.texture_size);
        } else {
            sum+=texelFetch(tex,coordinate+ivec2(offset,0),0);
        }
    }
    out_color=sum/float(1+left+right);
}
