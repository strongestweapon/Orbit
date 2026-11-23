// Native stateful scene. The host integrates 12 angular particles, then shares
// this same snapshot between the ring, strip, packed output and benchmark.
struct PulseOrbitParams {
    OrbitParams base;
    float position[12];
    float velocity[12];
    float hue[3];
    float simulationTime;
    float dynamics;
    float rhythmRate;
    float afterglow;
    float counterflow;
};

float3 pulseOrbitShade(float2 uv, constant PulseOrbitParams &state) {
    OrbitParams p = state.base;
    int lane = int(clamp(floor(uv.y * 3.0), 0.0, 2.0));
    float center = (float(lane) + 0.5) / 3.0;
    float width = mix(0.035, 0.27, clamp(p.shape3, 0.0, 1.0));
    float radialPixel, angularPixel;
    if (p.viewMode > 1.5) {
        radialPixel = 2160.0 / (p.outputHeight * 300.0);
        angularPixel = 3840.0 / (p.outputWidth * 15444.0);
    } else if (p.viewMode > 0.5) {
        float outer = min(p.outputWidth, p.outputHeight) * 0.34722222;
        float ringWidth = clamp(p.ringWidth, 0.01, 0.6);
        radialPixel = 1.0 / max(outer * ringWidth, 1.0);
        angularPixel = 1.0 / max(ORBIT_TAU * outer * (1.0 - ringWidth + uv.y * ringWidth), 1.0);
    } else {
        radialPixel = 1.0 / p.outputHeight;
        angularPixel = 1.0 / p.outputWidth;
    }
    // Pixel-sized edge coverage, no blur/noise/glow. Same physical line width in every view.
    float radialAA = radialPixel * 0.65;
    float line = 1.0 - smoothstep(width * 0.5 - radialAA, width * 0.5 + radialAA, abs(uv.y - center));
    if (line <= 0.0) return float3(0.0);
    // Each emitter has a bright leading edge and a directional, decaying tail.
    float length = mix(0.012, 0.62, clamp(p.shape1, 0.0, 1.0));
    float count = 1.0 + 3.0 * clamp(p.shape2, 0.0, 1.0);
    float light = 0.0;
    for (int slot = 0; slot < 4; slot++) {
        int index = lane * 4 + slot;
        int rank = slot == 1 ? 2 : (slot == 2 ? 1 : slot);
        float active = clamp(count - float(rank), 0.0, 1.0);
        float proportion = slot == 0 ? 1.0 : (slot == 2 ? 0.72 : (slot == 1 ? 0.42 : 0.27));
        float period = (10.0 - state.rhythmRate * 7.0) * (1.0 + float(lane)*0.09 + float(slot)*0.13);
        float phase = fract(state.simulationTime/period + float(lane)*0.19 + float(slot)*0.27);
        float burst = smoothstep(0.02,0.08,phase) * (1.0-smoothstep(0.30,0.74,phase));
        float life = smoothstep(0.0,0.035,phase) * (1.0-smoothstep(0.66,0.98,phase));
        life = mix(1.0,life,clamp(state.dynamics,0.0,1.0));
        float velocity = state.velocity[index];
        float fallback = (p.density < 0.5 ? -1.0 : 1.0) * (state.counterflow >= 0.5 && lane == 1 ? -1.0 : 1.0);
        float direction = abs(velocity) > 0.0001 ? sign(velocity) : fallback;
        float speed = clamp(abs(velocity)/0.22,0.0,1.0);
        float span = min(0.82,length * proportion * mix(1.0,0.30 + 0.95*burst + 0.75*speed,state.dynamics));
        float behind = fract((state.position[index] - uv.x) * direction);
        float relative = behind / max(span,0.0001);
        float tail = pow(max(0.0,1.0-relative),mix(3.2,0.55,clamp(state.afterglow,0.0,1.0)));
        // A packet can resolve into a train of short dashes, then join into a sweep.
        // It is spatial modulation inside each tail, never a whole-screen strobe.
        float chopped = state.dynamics * smoothstep(0.20,0.80,0.5 + 0.5*sin(state.simulationTime*0.68 + float(lane)*1.8));
        float spacing = mix(0.014,0.045,burst);
        float cell = fract(behind/spacing);
        float cellAA = min(0.12,angularPixel/spacing);
        float dash = smoothstep(0.0,cellAA,cell)*(1.0-smoothstep(0.45-cellAA,0.45+cellAA,cell));
        tail *= mix(1.0,0.08 + 0.92*dash,chopped);
        float distance = abs(fract(uv.x-state.position[index]+0.5)-0.5);
        float head = 1.0-smoothstep(0.004-angularPixel*0.65,0.004+angularPixel*0.65,distance);
        light = max(light,clamp(tail*1.25 + head,0.0,1.0)*life*active);
    }
    // Preserve the existing color slots; restrict the palette to pure red or white.
    float3 color = state.hue[lane] >= 0.5 ? float3(1.0) : float3(1.0, 0.0, 0.0);
    return color * light * line;
}

float4 samplePulseOrbit(float2 pixel, constant PulseOrbitParams &state) {
    OrbitParams p = state.base;
    float3 uv = orbitCoordinates(pixel, p);
    if (uv.z <= 0.0) return float4(0, 0, 0, 1);
    float3 rgb = pulseOrbitShade(uv.xy, state) * p.brightness * orbitPresence(uv.xy, p) * uv.z;
    return float4(clamp(rgb, 0.0, 1.0), 1.0);
}
