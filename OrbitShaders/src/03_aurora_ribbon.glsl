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
    float t = p.phaseTime * 1.1;
    float a = ORBIT_TAU * uv.x;
    float drift = t * 0.035;
    vec2 radial = vec2(sin(a + drift), cos(a + drift));
    vec3 q = vec3(radial * (6.0 + uv.y * 0.8), t * 0.25 + p.seed);
    float cloud = orbitFbm(q * (1.2 + p.turbulence));
    // The amber side lobes stay in place; the surface flows through them.
    float warm = pow(abs(sin(a + 0.12)), 7.0);
    float south = 0.5 - 0.5 * cos(a);
    vec3 blue = orbitHsv(0.64 - south * 0.105 + p.hueShift, 0.73, 0.55);
    vec3 gold = orbitHsv(0.055 + p.hueShift, 0.47, 0.92);
    vec3 col = mix(blue, gold, warm * 0.94);
    col *= 0.28 + 0.85 * cloud;
    vec2 dustUV = radial * (92.0 + 60.0 * p.density + uv.y * 15.0);
    float dust = auroraParticles(dustUV, t);
    float grain = pow(orbitNoise(vec3(dustUV * 2.9, t * 0.35)), 5.0);
    vec3 ice = mix(vec3(0.45,0.72,1.0), vec3(1.0,0.87,0.64), warm);
    col += ice * (dust * 0.55 + grain * 0.60) * (0.4 + cloud);
    float flow = 0.5 + 0.5 * sin(a * 2.0 - p.phaseTime * 1.1 + (cloud - 0.5) * 2.0);
    col *= 0.60 + flow * 0.60;
    float shimmer = 0.93 + 0.07 * sin(t * 0.52);
    float inner = exp(-uv.y * 22.0) * 1.65 + exp(-uv.y * 6.0) * 0.31;
    float outer = exp(-(1.0 - uv.y) * 28.0);
    col += vec3(0.85,0.9,1.0) * inner * shimmer;
    col += mix(vec3(0.12,0.9,1.0), ice, warm) * outer * 1.05;
    col += ice * warm * 0.20;
    return col * (0.62 + p.energy * 0.64) * orbitBandEdge(uv.y);
}
