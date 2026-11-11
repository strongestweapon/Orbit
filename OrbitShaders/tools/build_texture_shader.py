#!/usr/bin/env python3
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]
header='''#include <metal_stdlib>
using namespace metal;
#define vec2 float2
#define vec3 float3
#define vec4 float4
#define ORBIT_ATAN atan2
namespace OrbitTexture {
'''
footer='''
}
fragment float4 orbit_texture_fragment(float4 position [[position]],
    constant OrbitTexture::OrbitParams &p [[buffer(0)]], texture2d<float> source [[texture(0)]]) {
    return OrbitTexture::sampleTexturePixel(position.xy,p,source);
}
kernel void orbit_texture_compute(device uchar4* output [[buffer(0)]],
    constant OrbitTexture::OrbitParams &p [[buffer(1)]], texture2d<float> source [[texture(0)]],
    uint2 gid [[thread_position_in_grid]]) {
    if(gid.x >= uint(p.outputWidth) || gid.y >= uint(p.outputHeight)) return;
    float4 c=OrbitTexture::sampleTexturePixel(float2(gid)+0.5,p,source);
    output[gid.y*uint(p.outputWidth)+gid.x]=uchar4(c*255.0+0.5);
}
#undef vec2
#undef vec3
#undef vec4
#undef ORBIT_ATAN
#undef ORBIT_TAU
'''
def build_texture_shader(regenerate_archive=False):
    (ROOT/'metal/OrbitTexture.metal').write_text(header+(ROOT/'src/common.glsl').read_text()+'\n'+(ROOT/'src/texture_body.metal').read_text()+footer)
    # Archived hybrid experiments retain their original ABI and source.
    if not regenerate_archive: return
    common=(ROOT/'src/common.glsl').read_text()
    body=(ROOT/'src/hybrid_body.metal').read_text()
    for src in sorted((ROOT/'src').glob('0*.glsl')):
        sid=src.stem
        if sid.startswith('06_'): continue
        style=int(sid[:2]);ns='OrbitHybrid'+str(style);entry='orbit_hybrid_'+sid
        prefix=header.replace('namespace OrbitTexture {',f'#define ORBIT_STYLE {style}\nnamespace {ns} {{')
        endings=f"""
}}
fragment float4 {entry}_fragment(float4 pos [[position]],constant {ns}::OrbitParams &p [[buffer(0)]],
 constant {ns}::HybridControls &c [[buffer(1)]],texture2d<float> source [[texture(0)]]) {{
 return {ns}::hybridPixel(pos.xy,p,c,source);
}}
kernel void {entry}_compute(device uchar4* output [[buffer(0)]],constant {ns}::OrbitParams &p [[buffer(1)]],
 constant {ns}::HybridControls &c [[buffer(2)]],texture2d<float> source [[texture(0)]],uint2 gid [[thread_position_in_grid]]) {{
 if(gid.x>=uint(p.outputWidth)||gid.y>=uint(p.outputHeight)) return;
 output[gid.y*uint(p.outputWidth)+gid.x]=uchar4({ns}::hybridPixel(float2(gid)+0.5,p,c,source)*255.0+0.5);
}}
#undef vec2
#undef vec3
#undef vec4
#undef ORBIT_ATAN
#undef ORBIT_TAU
#undef ORBIT_STYLE
"""
        (ROOT/'metal'/f'OrbitHybrid_{sid}.metal').write_text(prefix+common+'\n'+src.read_text()+'\n'+body+endings)
    print('Built texture and seven hybrid shaders.')

if __name__=='__main__':
    build_texture_shader()
