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
layout(location=1) flat in vec4 dest;
layout(location=2) flat in vec4 source;
layout(location=4) flat in vec4 rounded;
layout(location=5) flat in vec4 parameters;
layout(location=0) out vec4 out_color;

float decodeComponent(float value) {
    int transfer=int(pc.transfer.x+0.5);
    if (transfer==0) return value;
    if (transfer==1) return pow(max(value,0.0),2.2);
    if (transfer==2) return value<=0.04045 ? value/12.92 : pow((value+0.055)/1.055,2.4);
    if (transfer==3) {
        float black=max(pc.transfer.y,0.0);
        float white=max(pc.transfer.w,black+0.000001);
        float black_root=pow(black,1.0/2.4);
        float denominator=pow(white,1.0/2.4)-black_root;
        float a=pow(denominator,2.4);
        float b=black_root/denominator;
        return a*pow(max(value+b,0.0),2.4);
    }
    if (transfer==4) return sign(value)*pow(abs(value),pc.transfer.y);
    if (transfer==5) {
        const float m1=2610.0/16384.0;
        const float m2=2523.0/32.0;
        const float c1=3424.0/4096.0;
        const float c2=2413.0/128.0;
        const float c3=2392.0/128.0;
        float p=pow(max(value,0.0),1.0/m2);
        return 10000.0*pow(max(p-c1,0.0)/max(c2-c3*p,0.000001),1.0/m1)+pc.transfer_aux.x;
    }
    if (transfer==6) {
        const float a=0.17883277;
        const float b=0.28466892;
        const float c=0.55991073;
        float scene=value<=0.5 ? value*value/3.0 : (exp((value-c)/a)+b)/12.0;
        return scene;
    }
    return value;
}

vec3 toneMapHdr(vec3 nits) {
    float reference_nits=pc.transfer.z;
    float peak_nits=max(pc.transfer.w,reference_nits+0.001);
    vec3 relative=max(nits,vec3(0.0))/reference_nits;
    float output_peak=max(pc.output_transfer.w/pc.output_transfer.z,1.0);
    vec3 high=vec3(1.0)+(output_peak-1.0)*
        log(max(relative,vec3(1.0)))/log(peak_nits/reference_nits);
    return min(mix(relative,high,greaterThan(relative,vec3(1.0))),vec3(output_peak));
}

vec3 decodeColor(vec3 electrical) {
    vec3 optical=vec3(
        decodeComponent(electrical.r),
        decodeComponent(electrical.g),
        decodeComponent(electrical.b)
    );
    int transfer=int(pc.transfer.x+0.5);
    if (transfer==0) {}
    else if (transfer==5) {
        if (int(pc.output_transfer.x+0.5)>=5) optical/=pc.transfer.z;
        else optical=toneMapHdr(optical);
    }
    else if (transfer==6) {
        float scene_luminance=max(dot(pc.transfer_aux.yzw,max(optical,vec3(0.0))),0.0);
        optical=pc.transfer.y*pow(scene_luminance,0.2)*optical;
        if (int(pc.output_transfer.x+0.5)>=5) optical/=pc.transfer.z;
        else optical=toneMapHdr(optical);
    }
    else if (transfer==3) optical/=pc.transfer.z;
    else optical=((pc.transfer.w-pc.transfer_aux.x)*optical+pc.transfer_aux.x)/pc.transfer.z;
    return vec3(
        dot(pc.color_matrix_0.xyz,optical),
        dot(pc.color_matrix_1.xyz,optical),
        dot(pc.color_matrix_2.xyz,optical)
    );
}

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
    vec3 straight=color.a>0.0 ? color.rgb/color.a : vec3(0.0);
    color.rgb=decodeColor(straight)*color.a;
    color*=parameters.w;
    if (parameters.x>0.0) {
        vec2 center=clamp(pixel,rounded.xy+vec2(parameters.x),rounded.xy+rounded.zw-vec2(parameters.x));
        float coverage=clamp(parameters.x+0.5-distance(pixel,center),0.0,1.0);
        color*=coverage;
    }
    out_color=color;
}
