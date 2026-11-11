// Still reference, bottom-right: luminous gold head, sparse particles, vanishing tail.
vec3 orbitShade(vec2 uv, OrbitParams p) {
    float t = p.phaseTime * 0.25;
    float center = orbitLightCenter(p);
    float d = orbitDistance(uv.x, center - 0.04);
    float head = exp(-d * d * (44.6 / max(p.shape0*p.shape0,0.01)));
    float grain = orbitNoise(orbitCircle(uv.x - t * 0.006, uv.y * 1.5,
                            90.0 + p.density * 80.0, t * 0.2, p.seed));
    float cloud = orbitFbm(orbitCircle(uv.x, uv.y * 0.4, 5.0, t * 0.35, p.seed));
    float spark = pow(smoothstep(0.68,0.95,grain),3.0/max(p.shape1,0.05));
    vec3 amber = orbitHsv(0.10 + p.hueShift, 0.83, 0.62);
    vec3 gold = orbitHsv(0.13 + p.hueShift, 0.55, 1.0);
    vec3 white = orbitHsv(0.14 + p.hueShift, 0.15, 1.0);
    float ribbon = exp(-pow((uv.y - 0.27) * 2.2,2.0));
    float ripple = 0.75 + 0.25 * sin(uv.y * 7.0 + cloud * (3.0 + p.turbulence * 5.0));
    vec3 col = amber * (0.035 + head * 0.75) * ripple;
    col += gold * head * ribbon * 0.55;
    col += white * pow(head,2.5) * exp(-uv.y * 5.0) * 1.25;
    col *= (0.6+p.energy*0.75)/1.0875;
    col += gold * spark * p.shape2 * (0.18 + head * 0.65);
    return col * 1.0875 * orbitBandEdge(uv.y);
}
