/*{
  "ISFVSN": "2.0",
  "VSN": "1.3.0",
  "DESCRIPTION": "어두운 유체 링 / Chroma Flow",
  "CREDIT": "SUPERLESS / Orbit project; procedural study based on supplied reference video",
  "CATEGORIES": [
    "Generator",
    "Orbit"
  ],
  "INPUTS": [
    {
      "NAME": "viewMode",
      "LABEL": "View",
      "TYPE": "long",
      "DEFAULT": 1,
      "VALUES": [
        0,
        1,
        2
      ],
      "LABELS": [
        "Unwrapped",
        "Ring preview",
        "Packed 4K"
      ]
    },
    {
      "NAME": "speed",
      "LABEL": "speed",
      "TYPE": "float",
      "DEFAULT": 1.0,
      "MIN": 0,
      "MAX": 3
    },
    {
      "NAME": "externalClock",
      "LABEL": "Use continuous host clock",
      "TYPE": "bool",
      "DEFAULT": false
    },
    {
      "NAME": "clockSeconds",
      "LABEL": "clockSeconds",
      "TYPE": "float",
      "DEFAULT": 0,
      "MIN": 0,
      "MAX": 86400
    },
    {
      "NAME": "density",
      "LABEL": "density",
      "TYPE": "float",
      "DEFAULT": 0.48,
      "MIN": 0,
      "MAX": 1
    },
    {
      "NAME": "turbulence",
      "LABEL": "turbulence",
      "TYPE": "float",
      "DEFAULT": 0.68,
      "MIN": 0,
      "MAX": 1
    },
    {
      "NAME": "energy",
      "LABEL": "energy",
      "TYPE": "float",
      "DEFAULT": 0.52,
      "MIN": 0,
      "MAX": 1
    },
    {
      "NAME": "hueShift",
      "LABEL": "hueShift",
      "TYPE": "float",
      "DEFAULT": 0,
      "MIN": -0.5,
      "MAX": 0.5
    },
    {
      "NAME": "brightness",
      "LABEL": "brightness",
      "TYPE": "float",
      "DEFAULT": 1,
      "MIN": 0,
      "MAX": 1
    },
    {
      "NAME": "seed",
      "LABEL": "seed",
      "TYPE": "float",
      "DEFAULT": 3,
      "MIN": 0,
      "MAX": 100
    },
    {
      "NAME": "angleOffset",
      "LABEL": "angleOffset",
      "TYPE": "float",
      "DEFAULT": 0,
      "MIN": -1,
      "MAX": 1
    },
    {
      "NAME": "flipU",
      "LABEL": "Reverse direction",
      "TYPE": "bool",
      "DEFAULT": false
    },
    {
      "NAME": "flipV",
      "LABEL": "Swap inner / outer",
      "TYPE": "bool",
      "DEFAULT": false
    },
    {
      "NAME": "ringWidth",
      "LABEL": "ringWidth",
      "TYPE": "float",
      "DEFAULT": 0.128,
      "MIN": 0.01,
      "MAX": 0.6
    },
    {
      "NAME": "coverage",
      "LABEL": "coverage",
      "TYPE": "float",
      "DEFAULT": 1.0,
      "MIN": 0,
      "MAX": 1
    },
    {
      "NAME": "gapSoftness",
      "LABEL": "gapSoftness",
      "TYPE": "float",
      "DEFAULT": 0.8,
      "MIN": 0,
      "MAX": 1
    },
    {
      "NAME": "gapMotion",
      "LABEL": "gapMotion",
      "TYPE": "float",
      "DEFAULT": 0.25,
      "MIN": 0,
      "MAX": 1
    },
    {
      "NAME": "fragmentation",
      "LABEL": "fragmentation",
      "TYPE": "float",
      "DEFAULT": 0.0,
      "MIN": 0,
      "MAX": 1
    }
  ]
}*/
#define ORBIT_ATAN atan
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

// Reference 12s: translucent metallic folds, dark pockets and thin caustics.
vec3 orbitShade(vec2 uv, OrbitParams p) {
    // One clock second is one reference second. The former clock was ~13x slower.
    float t = p.phaseTime * 3.6;
    float a = ORBIT_TAU * uv.x;
    vec3 q = orbitCircle(uv.x - t * 0.008, uv.y * 0.55, 1.3 + p.density * 1.7, t * 0.42, p.seed);
    vec3 warp = vec3(orbitFbm(q), orbitFbm(q + 9.1), orbitFbm(q + 17.7));
    float field = orbitFbm(q + warp * (1.8 + p.turbulence * 3.2));
    float fold = sin(a * 3.0 - t * 0.15 + uv.y * 1.4 + field * 4.0 - t * 0.3);
    float caustic = exp(-abs(fold) * 24.0);
    float satin = pow(0.5 + 0.5 * fold, 4.0);
    float pool = smoothstep(0.28, 0.78, orbitFbm(q * 0.64 + 5.2));
    // Palette evolution is slower than the folding surface, as in the source.
    float paletteTime = p.phaseTime - floor(p.phaseTime / 23.0) * 23.0;
    float green = smoothstep(9.0,11.0,paletteTime) * (1.0-smoothstep(12.0,14.0,paletteTime));
    float violet = smoothstep(13.0,15.0,paletteTime) * (1.0-smoothstep(18.0,20.0,paletteTime));
    vec3 bronze = mix(orbitHsv(0.045+p.hueShift,0.75,0.52),orbitHsv(0.24+p.hueShift,0.68,0.56),green);
    bronze = mix(bronze,orbitHsv(0.84+p.hueShift,0.66,0.56),violet);
    vec3 pearl = mix(orbitHsv(0.065+p.hueShift,0.27,1.0),orbitHsv(0.24+p.hueShift,0.24,1.0),green);
    pearl = mix(pearl,orbitHsv(0.84+p.hueShift,0.24,1.0),violet);
    vec3 col = bronze * (0.08 + 0.85 * pool) * (0.35 + 0.65 * satin);
    col += pearl * (caustic * 0.74 + satin * 0.34) * (0.14 + 0.86 * pool);
    float reflection = pow(0.5 + 0.5 * cos(a + 0.65 + (field - 0.5) * 1.4), 4.0);
    col += pearl * reflection * (0.35 + satin * 0.7);
    col += pearl * pow(orbitFbm(q * 4.2), 4.0) * 0.15;
    float rim = exp(-uv.y * 65.0) + exp(-(1.0 - uv.y) * 65.0);
    col += pearl * rim * (0.08 + pool * 0.20);
    return col * (0.66 + p.energy * 0.96) * orbitBandEdge(uv.y);
}

void main() {
    OrbitParams p;
    p.outputWidth = RENDERSIZE.x;
    p.outputHeight = RENDERSIZE.y;
    p.viewMode = float(viewMode);
    p.phaseTime = externalClock ? clockSeconds : TIME * speed;
    p.density = density;
    p.turbulence = turbulence;
    p.energy = energy;
    p.hueShift = hueShift;
    p.brightness = brightness;
    p.seed = seed;
    p.angleOffset = angleOffset;
    p.flipU = flipU ? 1.0 : 0.0;
    p.flipV = flipV ? 1.0 : 0.0;
    p.ringWidth = ringWidth;
    p.testPattern = 0.0;
    p.markerWidth = 12.0;
    p.coverage = coverage;
    p.gapSoftness = gapSoftness;
    p.gapMotion = gapMotion;
    p.fragmentation = fragmentation;
    vec2 pixel = vec2(isf_FragNormCoord.x, 1.0-isf_FragNormCoord.y) * RENDERSIZE;
    vec3 uv = orbitCoordinates(pixel, p);
    float presence = orbitPresence(uv.xy, p);
    vec3 color = uv.z > 0.0 ? clamp(orbitShade(uv.xy, p) * brightness, 0.0, 1.0) * uv.z * presence : vec3(0.0);
    gl_FragColor = vec4(color, 1.0);
}
