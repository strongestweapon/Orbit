#include <metal_stdlib>
using namespace metal;
#define vec2 float2
#define vec3 float3
#define vec4 float4
#define ORBIT_ATAN atan2
#define ORBIT_STYLE 8
namespace OrbitHybrid8 {
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

// Still reference, bottom-right: luminous gold head, sparse particles, vanishing tail.
vec3 orbitShade(vec2 uv, OrbitParams p) {
    float t = p.phaseTime * 0.25;
    float center = orbitLightCenter(p);
    float d = orbitDistance(uv.x, center - 0.04);
    float head = exp(-d * d * (32.0 + p.density * 28.0));
    float grain = orbitNoise(orbitCircle(uv.x - t * 0.006, uv.y * 1.5,
                            90.0 + p.density * 80.0, t * 0.2, p.seed));
    float cloud = orbitFbm(orbitCircle(uv.x, uv.y * 0.4, 5.0, t * 0.35, p.seed));
    float spark = pow(smoothstep(0.68,0.95,grain),3.0);
    vec3 amber = orbitHsv(0.10 + p.hueShift, 0.83, 0.62);
    vec3 gold = orbitHsv(0.13 + p.hueShift, 0.55, 1.0);
    vec3 white = orbitHsv(0.14 + p.hueShift, 0.15, 1.0);
    float ribbon = exp(-pow((uv.y - 0.27) * 2.2,2.0));
    float ripple = 0.75 + 0.25 * sin(uv.y * 7.0 + cloud * (3.0 + p.turbulence * 5.0));
    vec3 col = amber * (0.035 + head * 0.75) * ripple;
    col += gold * head * ribbon * 0.55;
    col += white * pow(head,2.5) * exp(-uv.y * 5.0) * 1.25;
    col += gold * spark * (0.18 + head * 0.65);
    return col * (0.6 + p.energy * 0.75) * orbitBandEdge(uv.y);
}

struct HybridControls { float generation; float sharpness; float evolution; float detail; };
float3 sharpReference(float2 uv, texture2d<float> source, float amount) {
    constexpr sampler s(coord::normalized,s_address::repeat,t_address::clamp_to_edge,filter::linear);
    float2 px=1.0/float2(source.get_width(),source.get_height());
    float3 center=source.sample(s,uv).rgb;
    float3 neighbors=(source.sample(s,uv+float2(px.x,0)).rgb+source.sample(s,uv-float2(px.x,0)).rgb
                    +source.sample(s,uv+float2(0,px.y)).rgb+source.sample(s,uv-float2(0,px.y)).rgb)*0.25;
    // Bounded edge enhancement, not an attempt to recover missing source pixels.
    return clamp(center+clamp(center-neighbors,-0.12,0.12)*amount*1.6,0.0,1.0);
}
float4 hybridPixel(float2 pixel, OrbitParams p, HybridControls c, texture2d<float> source) {
    float3 mapped=orbitCoordinates(pixel,p);
    if(mapped.z<=0.0) return float4(0,0,0,1);
    float2 uv=mapped.xy;
    float t=p.phaseTime*(0.25+c.evolution*1.5);
    float gen=clamp(c.generation,0.0,1.0);
    float a=ORBIT_TAU*uv.x;
    float f=orbitFbm(orbitCircle(uv.x,uv.y*0.7,3.4,t*0.24,p.seed));
    float g=orbitFbm(orbitCircle(uv.x,uv.y*0.9,5.7,-t*0.19,p.seed+6.1));
    float strength=gen*(0.35+c.evolution*0.65+p.turbulence);
    // Neighboring parts evolve differently; no rigid rotation of the seed image.
    float2 flow=float2(fract(uv.x+(f-0.5)*strength*0.085),
                      clamp(uv.y+(g-0.5)*strength*0.38,0.0,1.0));
    float3 ref=sharpReference(flow,source,c.sharpness);
    float luma=dot(ref,float3(0.2126,0.7152,0.0722));
    float3 palette=clamp(ref/max(luma,0.15),0.0,2.0);
    OrbitParams q=p;
    q.phaseTime=t; q.hueShift=0.0;
    q.density=0.25+c.detail*0.65; q.turbulence=0.35+c.evolution*0.6;
    q.energy=0.58+p.energy*0.4;
    float3 procedural=orbitShade(flow,q);
    float power=dot(procedural,float3(0.2126,0.7152,0.0722));
    float3 generated=mix(procedural,palette*power,0.62);
    float life=smoothstep(0.22,0.69,orbitNoise(orbitCircle(uv.x,uv.y*0.2,9.0,t*0.36,p.seed+19.0)));
    generated*=0.22+life*1.15;
    float3 color=mix(ref,generated,gen);
    float3 lightTint=mix(palette,float3(1.0),0.55);
    float angularPixels=p.viewMode>1.5 ? 15444.0 : (p.viewMode>0.5 ? min(p.outputWidth,p.outputHeight)*2.18166 : p.outputWidth);
#if ORBIT_STYLE == 4
    float count=floor(1000.0+c.detail*1200.0);
    float aa=1.0-smoothstep(0.18,0.65,count/angularPixels);
    float strand=pow(0.5+0.5*sin(a*count+g*10.0-uv.y*4.0-t*2.0),28.0);
    float tip=1.0-smoothstep(0.35+f*0.5,0.55+f*0.5,uv.y);
    color+=lightTint*strand*tip*life*gen*(0.10+c.detail*0.45)*aa;
#elif ORBIT_STYLE == 7
    float count=floor(210.0+c.detail*200.0);
    float cell=floor(fract(uv.x)*count);
    float h=orbitHash(float3(cell,3.7,p.seed));
    float birth=smoothstep(-0.45,0.35,sin(t*(0.45+h)+h*47.0));
    float bar=1.0-smoothstep(0.15+h*0.4,0.20+h*0.4,fract(uv.x*count));
    float radial=smoothstep(h*0.4,h*0.4+0.04,uv.y)*(1.0-smoothstep(0.6+h*0.2,0.68+h*0.2,uv.y));
    color*=mix(1.0,0.15+birth*0.85,gen*0.75);
    color+=lightTint*bar*birth*radial*gen*c.detail*0.55;
#elif ORBIT_STYLE == 8 || ORBIT_STYLE == 3
    float count=floor(900.0+c.detail*900.0);
    float aa=1.0-smoothstep(0.18,0.65,count/angularPixels);
    float2 grid=float2(fract(uv.x)*count,uv.y*24.0);
    float2 cell=floor(grid);
    float h=orbitHash(float3(cell,p.seed));
    float2 point=fract(grid)-0.5-float2(h-0.5,orbitHash(float3(cell,7.3))-0.5)*0.42;
    float born=smoothstep(0.05,0.65,sin(t*(0.7+h)+h*65.0));
    float dust=exp(-dot(point,point)*90.0)*born*smoothstep(0.55,0.9,h);
    color+=lightTint*dust*gen*c.detail*(0.3+life)*0.9*aa;
#else
    float fold=sin(a*7.0+uv.y*5.0+f*9.0-t*0.7);
    float caustic=exp(-abs(fold)*65.0);
    color+=lightTint*caustic*gen*c.detail*life*0.22;
#endif
    color=max((color-0.5)*exp2((p.density-0.5)*1.5)+0.5,0.0);
    // Emission is localized to generated highlights rather than a full-screen blur.
    color+=lightTint*pow(clamp(power,0.0,1.0),4.0)*p.energy*0.20;
    if(abs(p.hueShift)>0.00001) {
        float3 axis=float3(0.57735026919); float angle=p.hueShift*ORBIT_TAU;
        color=color*cos(angle)+cross(axis,color)*sin(angle)+axis*dot(axis,color)*(1.0-cos(angle));
    }
    color=clamp(color*p.brightness,0.0,1.0)*mapped.z*orbitPresence(uv,p);
    return float4(color,1.0);
}

}
fragment float4 orbit_hybrid_08_golden_drift_fragment(float4 pos [[position]],constant OrbitHybrid8::OrbitParams &p [[buffer(0)]],
 constant OrbitHybrid8::HybridControls &c [[buffer(1)]],texture2d<float> source [[texture(0)]]) {
 return OrbitHybrid8::hybridPixel(pos.xy,p,c,source);
}
kernel void orbit_hybrid_08_golden_drift_compute(device uchar4* output [[buffer(0)]],constant OrbitHybrid8::OrbitParams &p [[buffer(1)]],
 constant OrbitHybrid8::HybridControls &c [[buffer(2)]],texture2d<float> source [[texture(0)]],uint2 gid [[thread_position_in_grid]]) {
 if(gid.x>=uint(p.outputWidth)||gid.y>=uint(p.outputHeight)) return;
 output[gid.y*uint(p.outputWidth)+gid.x]=uchar4(OrbitHybrid8::hybridPixel(float2(gid)+0.5,p,c,source)*255.0+0.5);
}
#undef vec2
#undef vec3
#undef vec4
#undef ORBIT_ATAN
#undef ORBIT_TAU
#undef ORBIT_STYLE
