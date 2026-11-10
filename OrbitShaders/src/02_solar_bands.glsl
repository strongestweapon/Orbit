// Reference 37s: irregular radial shafts, orange inner and green/yellow outer edge.
vec3 orbitShade(vec2 uv, OrbitParams p) {
    float t = p.phaseTime * 2.8;
    float angle = ORBIT_TAU * uv.x;
    // Bands shear locally, instead of a rigidly rotating ring.
    float u = uv.x - t * 0.003 + 0.012 * sin(angle * 3.0 + p.phaseTime * 1.1);
    float bend = (orbitNoise(orbitCircle(u, uv.y * 0.4, 6.0, t * 0.14, p.seed)) - 0.5) * p.turbulence * 0.004;
    vec3 q = orbitCircle(u + bend, uv.y * 0.035, 18.0 + p.density * 27.0, t * 0.38, p.seed);
    float shafts = 0.84 * orbitNoise(q) + 0.16 * orbitNoise(q * 2.07 + 11.4);
    float light = smoothstep(0.17, 0.78, shafts);
    float variation = orbitNoise(orbitCircle(u, 0.0, 4.0, t * 0.14, p.seed + 8.0));
    float hue = 0.034 + uv.y * 0.13 + 0.045 * sin(angle - p.phaseTime * 1.03)
              + (variation - 0.5) * 0.055 + p.hueShift;
    vec3 col = orbitHsv(hue, 0.78 + 0.16 * (1.0 - light), 0.38 + 0.65 * pow(light, 0.55));
    col += vec3(0.16, 0.13, 0.025) * pow(light, 5.0);
    return col * (0.66 + p.energy * 0.55) * orbitBandEdge(uv.y);
}
