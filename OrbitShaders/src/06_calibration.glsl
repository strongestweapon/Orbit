float orbitRect(vec2 p, vec2 center, vec2 halfSize) {
    vec2 d = abs(p - center) - halfSize;
    return 1.0 - smoothstep(0.0, 0.009, max(d.x, d.y));
}
float orbitDigit(vec2 p, float n) {
    // Glyph tops point outward. Canonical radial v grows outward, unlike raster Y.
    p.y = -p.y;
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
vec3 orbitRadialTest(vec2 uv, float mode) {
    // Three numbers per long segment, one in the short fifth segment.
    float sector = min(floor(min(uv.x * 15444.0,15443.999) / 3564.0),4.0) + 1.0;
    // Segment colors identify 1–5; narrow edge bands identify inner/outer.
    vec3 col = orbitHsv((sector - 1.0) * 0.18 + 0.55, 0.45, 0.80);
    float x = fract(uv.x * 13.0) * 1188.0 - 594.0;
    bool innerOnly = mode > 9.5 && mode < 10.5;
    bool outerOnly = mode > 10.5;
    if ((innerOnly && uv.y >= 0.48) || (outerOnly && uv.y <= 0.52)) return vec3(0);
    // 24 of 300 logical pixels (8%) per edge; scales with output resolution.
    if (uv.y < 0.08) return vec3(1,0,0);
    if (uv.y >= 0.92) return vec3(0,0,1);
    float center = innerOnly ? 75.0 : (outerOnly ? 225.0 : 150.0);
    float scale = innerOnly || outerOnly ? 150.0 : 300.0;
    float number = orbitDigit(vec2(x,uv.y * 300.0 - center) / scale,sector);
    return mix(col,vec3(0.03),number);
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
                         1.0-step(1.0, fract((1.0-uv.y)*300.0/50.0)*50.0));
        return mix(vec3(0.02),vec3(0.9),line);
    }
    if (mode < 2.5) return orbitRadialTest(uv,mode);
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
    if (mode < 9.5) return vec3(fract((floor(s)+floor((1.0-uv.y)*300.0))*0.5)*2.0);
    return orbitRadialTest(uv,mode);
}
