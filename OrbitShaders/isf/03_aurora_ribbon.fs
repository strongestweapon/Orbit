/*{
  "ISFVSN": "2.0",
  "VSN": "1.4.0",
  "DESCRIPTION": "청보라 리본과 밝은 테두리 / Aurora Ribbon",
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
      "NAME": "ribbonWidth",
      "LABEL": "리본 폭",
      "TYPE": "float",
      "DEFAULT": 1,
      "MIN": 0.15,
      "MAX": 1
    },
    {
      "NAME": "dustDensity",
      "LABEL": "미세 입자 밀도",
      "TYPE": "float",
      "DEFAULT": 0.4,
      "MIN": 0,
      "MAX": 1
    },
    {
      "NAME": "cloudScale",
      "LABEL": "구름결 밀도",
      "TYPE": "float",
      "DEFAULT": 0.4,
      "MIN": 0,
      "MAX": 1
    },
    {
      "NAME": "edgeGlow",
      "LABEL": "테두리 발광",
      "TYPE": "float",
      "DEFAULT": 0.62,
      "MIN": 0,
      "MAX": 1
    },
    {
      "NAME": "sparkleStrength",
      "LABEL": "입자 반짝임",
      "TYPE": "float",
      "DEFAULT": 1,
      "MIN": 0,
      "MAX": 2
    },
    {
      "NAME": "warmLobes",
      "LABEL": "양옆의 금빛",
      "TYPE": "float",
      "DEFAULT": 1,
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

// Reference 56s: granular luminous glass, warm side lobes, white/cyan rims.
float auroraParticles(vec2 position, float time) {
    vec2 cell = floor(position);
    vec2 f = fract(position);
    float light = 0.0;
    for (int y = -1; y <= 1; y++) {
        for (int x = -1; x <= 1; x++) {
            vec2 offset = vec2(float(x), float(y));
            float h = orbitHash(vec3(cell + offset, 3.1));
            vec2 center = vec2(h, orbitHash(vec3(cell + offset, 8.9)));
            vec2 d = offset + center - f;
            float twinkle = 0.55 + 0.45 * sin(time * 1.5 + h * 32.0);
            light += exp(-dot(d,d) * (12.0 + h * 22.0)) * twinkle * smoothstep(0.25,0.85,h);
        }
    }
    return light;
}
vec3 orbitShade(vec2 uv, OrbitParams p) {
    uv.y /= max(p.shape0,0.05);
    if (uv.y >= 1.0) return vec3(0.0);
    float t = p.phaseTime * 1.1;
    float a = ORBIT_TAU * uv.x;
    float drift = t * 0.035;
    vec2 radial = vec2(sin(a + drift), cos(a + drift));
    vec3 q = vec3(radial * (6.0 + uv.y * 0.8), t * 0.25 + p.seed);
    float cloud = orbitFbm(q * (1.2 + p.turbulence));
    // The amber side lobes stay in place; the surface flows through them.
    float warm = pow(abs(sin(a + 0.12)), 7.0) * p.shape2;
    float south = 0.5 - 0.5 * cos(a);
    vec3 blue = orbitHsv(0.64 - south * 0.105 + p.hueShift, 0.73, 0.55);
    vec3 gold = orbitHsv(0.055 + p.hueShift, 0.47, 0.92);
    vec3 col = mix(blue, gold, warm * 0.94);
    col *= 0.28 + 0.85 * cloud;
    vec2 dustUV = radial * (92.0 + 60.0 * p.density + uv.y * 15.0);
    float dust = auroraParticles(dustUV, t);
    float grain = pow(orbitNoise(vec3(dustUV * 2.9, t * 0.35)), 5.0);
    vec3 ice = mix(vec3(0.45,0.72,1.0), vec3(1.0,0.87,0.64), warm);
    col += ice * (dust * 0.55 + grain * 0.60) * p.shape1 * (0.4 + cloud);
    float flow = 0.5 + 0.5 * sin(a * 2.0 - p.phaseTime * 1.1 + (cloud - 0.5) * 2.0);
    col *= 0.60 + flow * 0.60;
    float shimmer = 0.93 + 0.07 * sin(t * 0.52);
    float inner = exp(-uv.y * 22.0) * 1.65 + exp(-uv.y * 6.0) * 0.31;
    float outer = exp(-(1.0 - uv.y) * 28.0);
    float edgeGlow = (0.62+p.energy*0.64)/1.0168;
    col += edgeGlow * vec3(0.85,0.9,1.0) * inner * shimmer;
    col += edgeGlow * mix(vec3(0.12,0.9,1.0), ice, warm) * outer * 1.05;
    col += ice * warm * 0.20;
    return col * 1.0168 * orbitBandEdge(uv.y);
}

void main() {
    OrbitParams p;
    p.outputWidth = RENDERSIZE.x;
    p.outputHeight = RENDERSIZE.y;
    p.viewMode = float(viewMode);
    p.phaseTime = externalClock ? clockSeconds : TIME * speed;
    p.density = dustDensity;
    p.turbulence = cloudScale;
    p.energy = edgeGlow;
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
    p.shape0 = ribbonWidth;
    p.shape1 = sparkleStrength;
    p.shape2 = warmLobes;
    p.shape3 = 1.0;
    vec2 pixel = vec2(isf_FragNormCoord.x, 1.0-isf_FragNormCoord.y) * RENDERSIZE;
    vec3 uv = orbitCoordinates(pixel, p);
    float presence = orbitPresence(uv.xy, p);
    vec3 color = uv.z > 0.0 ? clamp(orbitShade(uv.xy, p) * brightness, 0.0, 1.0) * uv.z * presence : vec3(0.0);
    gl_FragColor = vec4(color, 1.0);
}
