// Reference 85s: dense irregular radial filaments rooted in a white inner rim.
vec3 orbitShade(vec2 uv, OrbitParams p) {
    float t = p.phaseTime * 1.2;
    float u = uv.x - t * 0.0015;
    float curl = orbitFbm(orbitCircle(u, uv.y * 1.2, 15.0, -t * 0.22, p.seed));
    float bent = u + (curl - 0.5) * p.turbulence * 0.004 * uv.y;
    vec3 q = orbitCircle(bent, uv.y * 0.52, 74.0 + p.density * 100.0, -t * 0.7, p.seed + 4.0);
    float strand = 0.68 * orbitNoise(q) + 0.32 * orbitNoise(q * 2.07 + 9.8);
    float fine = orbitNoise(orbitCircle(bent, uv.y * 3.2, 300.0, -t * 1.5, p.seed));
    float fiber = pow(smoothstep(0.20,0.80,strand),1.0/max(p.shape1,0.05));
    float ridge = pow(1.0 - abs(2.0 * strand - 1.0), 12.0/max(p.shape1,0.05)) * 0.10;
    float length = (0.38 + 0.72 * orbitNoise(orbitCircle(u,0.0,23.0,-t * 0.16,p.seed))) * p.shape0;
    float plume = 1.0 - smoothstep(length - 0.25, length + 0.15, uv.y);
    float root = exp(-uv.y * 11.0);
    float purple = orbitNoise(orbitCircle(u,0.0,2.4,t * 0.07,p.seed + 7.0));
    vec3 cold = mix(vec3(0.025,0.14,0.40),vec3(0.30,0.18,0.40),smoothstep(0.4,0.8,purple));
    cold = mix(cold, orbitHsv(0.62 + p.hueShift,0.65,0.42),min(abs(p.hueShift) * 4.0,1.0));
    vec3 ice = orbitHsv(0.59 + p.hueShift,0.13,1.0);
    vec3 col = cold * (0.48 + strand * 0.85);
    float detail = (fiber * (0.5 + fine * 0.6) + ridge) * plume;
    col += ice * (detail * (0.65 + p.energy * 0.65) + root * 1.05 * p.shape2);
    col += ice * pow(fine,7.0) * plume * 0.5;
    return col * 1.08 * orbitBandEdge(uv.y);
}
