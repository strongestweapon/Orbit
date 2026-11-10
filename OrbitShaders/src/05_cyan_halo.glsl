// Reference 106–126s: counterclockwise flow (~4.2 s/turn initially), then acceleration.
// Analytic velocity integral, not sampled frames or video textures.
// After the observed acceleration, ease back over six seconds for continuous playback.
float cyanTurns(float seconds) {
    float cycle = floor(seconds / 26.0);
    float local = seconds - cycle * 26.0;
    float ramp = clamp(local - 10.0, 0.0, 10.0);
    float extra = 0.00358272 * ramp * ramp * ramp;
    float release = clamp((local - 20.0) / 6.0, 0.0, 1.0);
    extra += 6.449496 * (release - release * release * release
                              + 0.5 * release * release * release * release);
    return 0.24029088 * seconds + cycle * 6.807468 + extra;
}

vec3 orbitShade(vec2 uv, OrbitParams p) {
    float turns = cyanTurns(p.phaseTime);
    float center = 0.70111796 - turns - 0.03140367 * sin(p.phaseTime * 1.5)
                   + 0.04010302 * cos(p.phaseTime * 1.5);
    float a = ORBIT_TAU * (uv.x - center);
    // Local folds have their own slower deformation clock.
    float textureTime = p.phaseTime * 0.40;
    float n = orbitFbm(orbitCircle(uv.x + turns, uv.y * 0.4,
                                  2.4 + p.density * 3.0, textureTime, p.seed));
    float distortion = (n - 0.5) * p.turbulence * 0.65;
    float sweep = 0.5 + 0.5 * cos(a + distortion);
    vec3 deep = orbitHsv(0.618 + p.hueShift, 0.91, 0.43);
    vec3 cyan = orbitHsv(0.555 + p.hueShift, 0.68, 0.94);
    vec3 white = orbitHsv(0.510 + p.hueShift, 0.18, 1.0);
    vec3 col = mix(deep, cyan, smoothstep(0.03, 0.60, sweep));
    col = mix(col, white, smoothstep(0.48, 0.96, sweep));
    float fold = sin(a * 2.0 + uv.y * 2.5 + n * (2.5 + p.turbulence * 4.0)
                     - textureTime * 0.4);
    col += cyan * exp(-abs(fold) * 42.0) * (1.0 - sweep) * 0.16;
    col *= 0.90 + 0.10 * sin(uv.y * 3.14159265);
    return col * (0.65 + p.energy * 0.54) * orbitBandEdge(uv.y);
}
