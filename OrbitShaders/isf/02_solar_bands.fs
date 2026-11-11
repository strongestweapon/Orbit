/*{
  "ISFVSN": "2.0",
  "VSN": "1.4.0",
  "DESCRIPTION": "주황·연두 방사형 밴드 / Solar Bands",
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
    },
    {
      "NAME": "bandLength",
      "LABEL": "밴드 길이",
      "TYPE": "float",
      "DEFAULT": 1,
      "MIN": 0.1,
      "MAX": 1
    },
    {
      "NAME": "bandDensity",
      "LABEL": "밴드 밀도",
      "TYPE": "float",
      "DEFAULT": 0.62,
      "MIN": 0,
      "MAX": 1
    },
    {
      "NAME": "bandBend",
      "LABEL": "밴드 휘어짐",
      "TYPE": "float",
      "DEFAULT": 0.32,
      "MIN": 0,
      "MAX": 1
    },
    {
      "NAME": "bandGlow",
      "LABEL": "밴드 발광",
      "TYPE": "float",
      "DEFAULT": 0.62,
      "MIN": 0,
      "MAX": 1
    },
    {
      "NAME": "bandSharpness",
      "LABEL": "밴드 명암",
      "TYPE": "float",
      "DEFAULT": 1,
      "MIN": 0.25,
      "MAX": 3
    },
    {
      "NAME": "colorSpread",
      "LABEL": "색 띠 간격",
      "TYPE": "float",
      "DEFAULT": 1,
      "MIN": 0,
      "MAX": 2
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

// Reference 37s: irregular radial shafts, orange inner and green/yellow outer edge.
vec3 orbitShade(vec2 uv, OrbitParams p) {
    float t = p.phaseTime * 2.8;
    float angle = ORBIT_TAU * uv.x;
    // Bands shear locally, instead of a rigidly rotating ring.
    float u = uv.x - t * 0.003 + 0.012 * sin(angle * 3.0 + p.phaseTime * 1.1);
    float bend = (orbitNoise(orbitCircle(u, uv.y * 0.4, 6.0, t * 0.14, p.seed)) - 0.5) * p.turbulence * 0.004;
    vec3 q = orbitCircle(u + bend, uv.y * 0.035, 18.0 + p.density * 27.0, t * 0.38, p.seed);
    float shafts = 0.84 * orbitNoise(q) + 0.16 * orbitNoise(q * 2.07 + 11.4);
    float light = pow(smoothstep(0.17, 0.78, shafts),p.shape1);
    float variation = orbitNoise(orbitCircle(u, 0.0, 4.0, t * 0.14, p.seed + 8.0));
    float hue = 0.034 + uv.y * 0.13 * p.shape2 + 0.045 * sin(angle - p.phaseTime * 1.03)
              + (variation - 0.5) * 0.055 + p.hueShift;
    vec3 col = orbitHsv(hue, 0.78 + 0.16 * (1.0 - light), 0.38 + 0.65 * pow(light, 0.55));
    col += vec3(0.16, 0.13, 0.025) * pow(light, 5.0);
    float lengthMask = 1.0-smoothstep(p.shape0-0.015,p.shape0+0.015,uv.y);
    return col * lengthMask * (0.66 + p.energy * 0.55) * orbitBandEdge(uv.y);
}

void main() {
    OrbitParams p;
    p.outputWidth = RENDERSIZE.x;
    p.outputHeight = RENDERSIZE.y;
    p.viewMode = float(viewMode);
    p.phaseTime = externalClock ? clockSeconds : TIME * speed;
    p.density = bandDensity;
    p.turbulence = bandBend;
    p.energy = bandGlow;
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
    p.shape0 = bandLength;
    p.shape1 = bandSharpness;
    p.shape2 = colorSpread;
    p.shape3 = 1.0;
    vec2 pixel = vec2(isf_FragNormCoord.x, 1.0-isf_FragNormCoord.y) * RENDERSIZE;
    vec3 uv = orbitCoordinates(pixel, p);
    float presence = orbitPresence(uv.xy, p);
    vec3 color = uv.z > 0.0 ? clamp(orbitShade(uv.xy, p) * brightness, 0.0, 1.0) * uv.z * presence : vec3(0.0);
    gl_FragColor = vec4(color, 1.0);
}
