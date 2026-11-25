// Native stateful scene. The host integrates 3–10 lanes of angular particles, then shares
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
    float clustering;
    float laneRate[3];
    float outerReverse;
    float linkRange;
    float linkStrength;
    float crossFlash;
    float waveTravel;
    float eventAngle[16];
    float eventTime[16];
    float eventStrength[16];
    float substepRemainder;
    float extraPosition[28];
    float extraVelocity[28];
    float lineCount;
};

int pulseLines(constant PulseOrbitParams &state) { return clamp(int(state.lineCount),3,10); }
float pulsePosition(int index, constant PulseOrbitParams &state) { return index<12 ? state.position[index] : state.extraPosition[index-12]; }
float pulseVelocity(int index, constant PulseOrbitParams &state) { return index<12 ? state.velocity[index] : state.extraVelocity[index-12]; }

float pulseWeight(int index, constant PulseOrbitParams &state) {
    int lane = index / 4, slot = index % 4;
    int rank = slot == 1 ? 2 : (slot == 2 ? 1 : slot);
    float active = clamp(1.0 + 3.0 * state.base.shape2 - float(rank),0.0,1.0);
    float period = (10.0-state.rhythmRate*7.0)*(1.0+float(lane)*0.09+float(slot)*0.13);
    float phase = fract(state.simulationTime/period+float(lane)*0.19+float(slot)*0.27);
    float life = smoothstep(0.0,0.035,phase)*(1.0-smoothstep(0.66,0.98,phase));
    return active * mix(1.0,life,state.dynamics);
}

float pulseDistance(float a, float b) { return abs(fract(a-b+0.5)-0.5); }

float3 pulseOrbitShade(float2 uv, constant PulseOrbitParams &state) {
    OrbitParams p = state.base;
    int lanes = pulseLines(state);
    int lane = clamp(int(floor(uv.y * float(lanes))),0,lanes-1);
    int role = lane == 0 ? 0 : (lane == lanes-1 ? 2 : 1);
    float center = (float(lane) + 0.5) / float(lanes);
    float width = mix(0.035, 0.27, clamp(p.shape3, 0.0, 1.0))*3.0/float(lanes);
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
    // Each emitter is one continuous stroke, widening with its surge and
    // tapering toward the tail. No periodic gaps or dash modulation.
    float length = mix(0.012, 0.62, clamp(p.shape1, 0.0, 1.0));
    float count = 1.0 + 3.0 * clamp(p.shape2, 0.0, 1.0);
    float light = 0.0;
    for (int slot = 0; slot < 4 && line > 0.0; slot++) {
        int index = lane * 4 + slot;
        int rank = slot == 1 ? 2 : (slot == 2 ? 1 : slot);
        float active = clamp(count - float(rank), 0.0, 1.0);
        float proportion = slot == 0 ? 1.0 : (slot == 2 ? 0.72 : (slot == 1 ? 0.42 : 0.27));
        float period = (10.0 - state.rhythmRate * 7.0) * (1.0 + float(lane)*0.09 + float(slot)*0.13);
        float phase = fract(state.simulationTime/period + float(lane)*0.19 + float(slot)*0.27);
        float burst = smoothstep(0.02,0.08,phase) * (1.0-smoothstep(0.30,0.74,phase));
        float life = smoothstep(0.0,0.035,phase) * (1.0-smoothstep(0.66,0.98,phase));
        life = mix(1.0,life,clamp(state.dynamics,0.0,1.0));
        float velocity = pulseVelocity(index,state);
        bool reverse = (state.counterflow >= 0.5 && role == 1 && lane % 2 == 1) || (state.outerReverse >= 0.5 && role == 2);
        float fallback = (p.density < 0.5 ? -1.0 : 1.0) * (reverse ? -1.0 : 1.0);
        float direction = abs(velocity) > 0.0001 ? sign(velocity) : fallback;
        float speed = clamp(abs(velocity)/0.22,0.0,1.0);
        float span = min(0.82,length * proportion * mix(1.0,0.30 + 0.95*burst + 0.75*speed,state.dynamics));
        float behind = fract((pulsePosition(index,state) - uv.x) * direction);
        float relative = behind / max(span,0.0001);
        float tail = pow(max(0.0,1.0-relative),mix(3.2,0.55,clamp(state.afterglow,0.0,1.0)));
        float distance = abs(fract(uv.x-pulsePosition(index,state)+0.5)-0.5);
        float head = 1.0-smoothstep(0.004-angularPixel*0.65,0.004+angularPixel*0.65,distance);
        float breathing = mix(1.0,0.22+0.78*max(burst,speed*0.8),state.dynamics)
            * mix(0.1,1.0,life);
        float taper = max(head,mix(0.04,1.0,pow(clamp(1.0-relative,0.0,1.0),0.65)));
        float halfWidth = width*0.5*breathing*taper;
        float stroke = 1.0-smoothstep(halfWidth-radialAA,halfWidth+radialAA,abs(uv.y-center));
        float emission = clamp(tail*1.25 + head,0.0,1.0)*life*active;
        // The relay brightens the same continuous stroke, preserving its taper.
        if (role == 1 && head > 0.0 && state.linkStrength > 0.0) {
            float threshold = mix(5.0,45.0,state.linkRange)/360.0;
            float near = 0.0;
            for (int k=0;k<8;k++) {
                int neighbor = k<4 ? k : k-4+(lanes-1)*4;
                near = max(near,max(0.0,1.0-pulseDistance(pulsePosition(index,state),pulsePosition(neighbor,state))/threshold)*pulseWeight(neighbor,state));
            }
            emission = max(emission,head*near*life*active*state.linkStrength);
        }
        light = max(light,emission*stroke);
    }
    // Preserve the existing color slots; restrict the palette to pure red or white.
    int palette = role == 2 ? 2 : (role == 0 ? 0 : lane % 2);
    float3 color = state.hue[palette] >= 0.5 ? float3(1.0) : float3(1.0, 0.0, 0.0);
    float3 rgb = color * light;
    float threshold = mix(5.0,45.0,state.linkRange)/360.0;
    // Proximity bridges traverse the real LED band; no room/speaker diagram is rendered.
    float bridge = 0.0;
    float inner = 0.5/float(lanes), outer = 1.0-inner;
    float radial = clamp((uv.y-inner)/(outer-inner),0.0,1.0);
    float bridgeMask = smoothstep(inner-radialAA,inner+radialAA,uv.y)
        * (1.0-smoothstep(outer-radialAA,outer+radialAA,uv.y));
    if (state.linkStrength > 0.0 && bridgeMask > 0.0) {
        for (int i=0;i<4;i++) {
            float innerWeight = pulseWeight(i,state);
            if (innerWeight < 0.01) continue;
            for (int j=0;j<4;j++) {
                int outerIndex = j+(lanes-1)*4;
                float delta = fract(pulsePosition(outerIndex,state)-pulsePosition(i,state)+0.5)-0.5;
                if (abs(delta) >= threshold) continue;
                float power = (1.0-abs(delta)/threshold)*min(innerWeight,pulseWeight(outerIndex,state));
                float angle = pulsePosition(i,state)+delta*radial;
                float d = pulseDistance(uv.x,angle);
                float thickness = mix(0.00055,0.0018,power);
                bridge = max(bridge,(1.0-smoothstep(max(0.0,thickness-angularPixel),thickness+angularPixel,d))*power);
            }
        }
    }
    rgb = max(rgb,float3(bridge*bridgeMask*state.linkStrength));
    if (state.crossFlash > 0.0) {
        float duration = mix(0.15,1.2,state.waveTravel);
        for (int e=0;e<16;e++) {
            float age = state.simulationTime-state.eventTime[e];
            if (age < 0.0 || age > duration || state.eventStrength[e] < 0.01) continue;
            float d = pulseDistance(uv.x,state.eventAngle[e]);
            float progress = age/duration;
            float flash = (1.0-smoothstep(0.0,0.14,age))
                * (1.0-smoothstep(0.002,0.002+angularPixel,d));
            float wave = (1.0-smoothstep(0.035,0.035+radialAA,abs(uv.y-progress)))
                * (1.0-smoothstep(0.012,0.024+progress*0.025,d)) * (1.0-progress);
            float power = state.eventStrength[e]*state.crossFlash;
            rgb = max(rgb,float3(flash)*power);
            rgb = max(rgb,float3(1.0,0.0,0.0)*wave*power);
        }
    }
    return rgb;
}

float4 samplePulseOrbit(float2 pixel, constant PulseOrbitParams &state) {
    OrbitParams p = state.base;
    float3 uv = orbitCoordinates(pixel, p);
    if (uv.z <= 0.0) return float4(0, 0, 0, 1);
    float3 rgb = pulseOrbitShade(uv.xy, state) * p.brightness * orbitPresence(uv.xy, p) * uv.z;
    return float4(clamp(rgb, 0.0, 1.0), 1.0);
}
