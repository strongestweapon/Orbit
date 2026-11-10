float orbitRect(vec2 p, vec2 center, vec2 halfSize) {
    vec2 d = abs(p - center) - halfSize;
    return 1.0 - smoothstep(0.0, 0.009, max(d.x, d.y));
}
float orbitDigit(vec2 p, float n) {
    float a = orbitRect(p, vec2(0,-0.27), vec2(0.13,0.025));
    float b = orbitRect(p, vec2(0.13,-0.135), vec2(0.025,0.12));
    float c = orbitRect(p, vec2(0.13,0.135), vec2(0.025,0.12));
    float d = orbitRect(p, vec2(0,0.27), vec2(0.13,0.025));
    float e = orbitRect(p, vec2(-0.13,0.135), vec2(0.025,0.12));
    float f = orbitRect(p, vec2(-0.13,-0.135), vec2(0.025,0.12));
    float g = orbitRect(p, vec2(0,0), vec2(0.13,0.025));
    if (n < 1.5) return max(b,c);
    if (n < 2.5) return max(max(a,b),max(max(g,e),d));
    if (n < 3.5) return max(max(a,b),max(max(g,c),d));
    if (n < 4.5) return max(max(f,g),max(b,c));
    return max(max(a,f),max(max(g,c),d));
}
vec3 orbitShade(vec2 uv, OrbitParams p) {
    float s = min(uv.x * 15444.0, 15443.999);
    float sector = min(floor(s / 3564.0), 4.0);
    float span = sector < 3.5 ? 3564.0 : 1188.0;
    float local = s - sector * 3564.0;
    float mode = floor(p.testPattern + 0.5);
    if (mode < 0.5) {
        vec3 col = orbitHsv(sector * 0.18 + 0.55, 0.45, 0.80);
        vec2 q = vec2((local - span * 0.5) / 300.0, uv.y - 0.5);
        float digit = orbitDigit(q, sector + 1.0);
        float arrow = orbitRect(q, vec2(0.70,0), vec2(0.18,0.018));
        vec2 ap = q - vec2(0.92,0);
        arrow = max(arrow, (1.0 - smoothstep(0.0,0.012,abs(ap.y) + ap.x * 0.65))
                  * smoothstep(-0.18,-0.17,ap.x) * (1.0-smoothstep(0.0,0.01,ap.x)));
        return mix(col, vec3(0.03), max(digit,arrow));
    }
    if (mode < 1.5) {
        float line = max(1.0-step(1.0, fract(s/100.0)*100.0),
                         1.0-step(1.0, fract(uv.y*300.0/50.0)*50.0));
        return mix(vec3(0.02),vec3(0.9),line);
    }
    if (mode < 2.5) return uv.y < 0.12 ? vec3(1,0,0) : (uv.y > 0.88 ? vec3(0,0,1) : vec3(0.2));
    if (mode < 3.5) return uv.x < 1.0/3.0 ? vec3(1,0,0) : (uv.x < 2.0/3.0 ? vec3(0,1,0) : vec3(0,0,1));
    if (mode < 4.5) return vec3(min(floor(uv.x*16.0),15.0)/15.0);
    if (mode < 5.5) return vec3(1.0);
    if (mode < 6.5) return vec3(0.0);
    if (mode < 7.5) {
        float dist = orbitDistance(uv.x, fract(p.phaseTime * 0.08));
        return vec3(1.0 - smoothstep(p.markerWidth/15444.0, (p.markerWidth+2.0)/15444.0, dist));
    }
    if (mode < 8.5) {
        float seam = min(local,span-local);
        return seam < 3.0 ? vec3(1.0) : vec3(0.03);
    }
    return vec3(fract((floor(s)+floor(uv.y*300.0))*0.5)*2.0);
}
