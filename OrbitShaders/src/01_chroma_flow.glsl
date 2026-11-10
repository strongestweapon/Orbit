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
