#include <metal_stdlib>
using namespace metal;
vertex float4 orbit_fullscreen_vertex(uint id [[vertex_id]]) {
    const float2 p[3] = { float2(-1,-1), float2(3,-1), float2(-1,3) };
    return float4(p[id],0,1);
}
