#include <metal_stdlib>
using namespace metal;
#define vec2 float2
#define vec3 float3
#define vec4 float4
#define ORBIT_ATAN atan2
namespace OrbitTexture {
// Portable scalar/vector subset shared by the Metal and ISF builds.
// u: clockwise around the ring, zero at twelve o'clock. v: inner -> outer.
#define ORBIT_TAU 6.283185307179586
struct OrbitParams {
    float outputWidth;
    float outputHeight;
    float viewMode;
    float phaseTime;
    float density;
    float turbulence;
    float energy;
    float hueShift;
    float brightness;
    float seed;
    float angleOffset;
    float flipU;
    float flipV;
    float ringWidth;
    float testPattern;
    float markerWidth;
    float coverage;
    float gapSoftness;
    float gapMotion;
    float fragmentation;
    // Scene-specific shape controls; see config/scenes.json.
    float shape0;
    float shape1;
    float shape2;
    float shape3;
};

float orbitHash(vec3 p) {
    p = fract(p * 0.1031);
    p += dot(p, p.yzx + 33.33);
    return fract((p.x + p.y) * p.z);
}

float orbitNoise(vec3 p) {
    vec3 i = floor(p);
    vec3 f = fract(p);
    f = f * f * (3.0 - 2.0 * f);
    return mix(
        mix(mix(orbitHash(i), orbitHash(i + vec3(1,0,0)), f.x),
            mix(orbitHash(i + vec3(0,1,0)), orbitHash(i + vec3(1,1,0)), f.x), f.y),
        mix(mix(orbitHash(i + vec3(0,0,1)), orbitHash(i + vec3(1,0,1)), f.x),
            mix(orbitHash(i + vec3(0,1,1)), orbitHash(i + vec3(1,1,1)), f.x), f.y), f.z);
}

float orbitFbm(vec3 p) {
    return 0.57 * orbitNoise(p) + 0.285 * orbitNoise(p * 2.03 + 17.1)
        + 0.145 * orbitNoise(p * 4.11 + 31.7);
}

vec3 orbitCircle(float u, float v, float scale, float t, float seed) {
    float a = ORBIT_TAU * u;
    return vec3(cos(a) * scale, sin(a) * scale, v * 2.6 + t) + seed * 0.371;
}

vec3 orbitHsv(float h, float s, float v) {
    vec3 p = abs(fract(vec3(h) + vec3(0.0, 2.0/3.0, 1.0/3.0)) * 6.0 - 3.0);
    return v * mix(vec3(1.0), clamp(p - 1.0, 0.0, 1.0), s);
}

float orbitDistance(float a, float b) {
    return abs(fract(a - b + 0.5) - 0.5);
}

// Local light occupancy: a moving arc with truly black gaps, never a global strobe.
float orbitLightCenter(OrbitParams p) {
    return 0.66 + p.phaseTime * p.gapMotion * 0.025;
}

float orbitPresence(vec2 uv, OrbitParams p) {
    float fill = clamp(p.coverage, 0.0, 1.0);
    if (fill <= 0.0) return 0.0;
    if (fill >= 1.0) return 1.0;
    float t = p.phaseTime * p.gapMotion;
    float breathing = sin(t * 0.37 + p.seed) * fill * (1.0 - fill) * 0.20;
    float halfWidth = (fill + breathing) * 0.5;
    float feather = min(halfWidth * 0.65, 0.003 + p.gapSoftness * 0.075);
    float d = orbitDistance(uv.x, orbitLightCenter(p));
    float arc = 1.0 - smoothstep(halfWidth - feather, halfWidth + feather, d);
    float islands = orbitNoise(orbitCircle(uv.x - t * 0.016, 0.0,
                                4.0 + p.fragmentation * 16.0, t * 0.22, p.seed + 15.0));
    float threshold = 0.25 + p.fragmentation * 0.24;
    float pieces = smoothstep(threshold - 0.06, threshold + 0.09, islands);
    return arc * mix(1.0, pieces, p.fragmentation);
}

// Every view samples the same canonical ring. Packed view is always a 4K canvas.
vec3 orbitCoordinates(vec2 pixel, OrbitParams p) {
    vec2 size = vec2(p.outputWidth, p.outputHeight);
    vec2 uv = pixel / size;
    float coverage = 1.0;
    if (p.viewMode > 1.5) {
        vec2 q = uv * vec2(3840.0, 2160.0);
        float row = floor(q.y / 300.0);
        if (q.x >= 3564.0 || q.y >= 1500.0 || (row > 3.5 && q.x >= 1188.0))
            return vec3(0.0);
        uv = vec2((row * 3564.0 + q.x) / 15444.0, fract(q.y / 300.0));
    } else if (p.viewMode > 0.5) {
        vec2 q = pixel - size * 0.5;
        float outer = min(size.x, size.y) * 0.34722222;
        float inner = outer * (1.0 - clamp(p.ringWidth, 0.01, 0.6));
        float r = length(q);
        coverage = smoothstep(inner - 0.7, inner + 0.7, r)
                 * (1.0 - smoothstep(outer - 0.7, outer + 0.7, r));
        if (coverage <= 0.0) return vec3(0.0);
        uv = vec2(fract(ORBIT_ATAN(q.x, -q.y) / ORBIT_TAU),
                  clamp((r - inner) / (outer - inner), 0.0, 1.0));
    }
    uv.x = fract((p.flipU > 0.5 ? -uv.x : uv.x) + p.angleOffset);
    uv.y = p.flipV > 0.5 ? 1.0 - uv.y : uv.y;
    return vec3(uv, coverage);
}

float orbitBandEdge(float v) {
    return smoothstep(0.0, 0.025, v) * (1.0 - smoothstep(0.975, 1.0, v));
}

// Texture input is display-referred SDR RGB. Neutral controls preserve the extracted pixels.
float3 textureColor(float2 uv, OrbitParams p, texture2d<float> source) {
    constexpr sampler sampling(coord::normalized, s_address::repeat, t_address::clamp_to_edge,
                               min_filter::linear, mag_filter::linear);
    if (p.testPattern > 0.5) uv.x = fract(uv.x - p.phaseTime * p.markerWidth);
    float a = ORBIT_TAU * uv.x;
    uv.x = fract(uv.x + sin(a * 3.0 + p.phaseTime * 0.4) * p.turbulence * 0.018 * sin(uv.y * 3.14159265));
    uv.y = clamp(uv.y + sin(a * 2.0 - p.phaseTime * 0.6) * p.turbulence * 0.12, 0.0, 1.0);
    float3 color = source.sample(sampling, uv).rgb;
    float contrast = exp2((p.density - 0.5) * 1.5);
    color = max((color - 0.5) * contrast + 0.5, 0.0);
    if (p.energy > 0.0) {
        float2 d = float2(2.0 / source.get_width(), 2.0 / source.get_height());
        float3 soft = source.sample(sampling, uv + float2(d.x,0)).rgb
                    + source.sample(sampling, uv - float2(d.x,0)).rgb
                    + source.sample(sampling, uv + float2(0,d.y)).rgb
                    + source.sample(sampling, uv - float2(0,d.y)).rgb;
        color += soft * (p.energy * 0.125);
    }
    if (abs(p.hueShift) > 0.00001) {
        float3 axis = float3(0.57735026919);
        float angle = p.hueShift * ORBIT_TAU;
        color = color * cos(angle) + cross(axis, color) * sin(angle)
              + axis * dot(axis, color) * (1.0 - cos(angle));
    }
    return color;
}
float4 sampleTexturePixel(float2 pixel, OrbitParams p, texture2d<float> source) {
    float3 uv = orbitCoordinates(pixel,p);
    if (uv.z <= 0.0) return float4(0,0,0,1);
    float3 color = textureColor(uv.xy,p,source);
    color = clamp(color * p.brightness,0.0,1.0) * uv.z * orbitPresence(uv.xy,p);
    return float4(color,1.0);
}

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
