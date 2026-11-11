// Smooth spectral film and straight, interrupted light fragments. No texture input.
// Geometry is separable in u/v: noise changes light occupancy, never bends a line.
float spectralGaussian(float x, float width) {
    return exp(-0.5*x*x/(width*width));
}
float spectralStroke(float distance, float halfWidth, float pixelWidth) {
    float a = max(pixelWidth*0.5,0.0001);
    return clamp((min(distance+a,halfWidth)-max(distance-a,-halfWidth))/(2.0*a),0.0,1.0);
}
vec3 spectralFilm(float v, float shift) {
    float q = clamp(v+shift,0.0,1.0);
    vec3 c = mix(vec3(0.69,0.105,0.065),vec3(0.91,0.23,0.075),smoothstep(0.05,0.53,q));
    c = mix(c,vec3(0.90,0.63,0.22),smoothstep(0.52,0.72,q));
    c = mix(c,vec3(0.28,0.62,0.38),smoothstep(0.70,0.87,q));
    return mix(c,vec3(0.13,0.43,0.53),smoothstep(0.86,1.0,q));
}
vec3 orbitShade(vec2 uv, OrbitParams p) {
    float u = fract(uv.x), v = uv.y, t = p.phaseTime;
    float angularPixels = p.viewMode > 1.5 ? 15444.0 :
        (p.viewMode > 0.5 ? min(p.outputWidth,p.outputHeight)*2.18166 : p.outputWidth);
    float radialPixels = p.viewMode > 1.5 ? 300.0 :
        (p.viewMode > 0.5 ? min(p.outputWidth,p.outputHeight)*0.34722222*p.ringWidth : p.outputHeight);
    float dv = 1.0/max(radialPixels,1.0);
    // Smooth colour fronts. Their motion is independent from fragment lifetimes.
    float frontA = 0.337+t*0.021+0.012*p.turbulence*sin(t*0.37);
    float frontB = 0.737+t*0.014-0.009*p.turbulence*sin(t*0.29);
    float warm = clamp(spectralGaussian(orbitDistance(u,frontA),0.078)
                     +spectralGaussian(orbitDistance(u,frontB),0.032),0.0,1.0);
    float skin = smoothstep(0.01,0.065,v)*(1.0-smoothstep(0.94,1.0,v));
    float field = orbitNoise(orbitCircle(u,0.0,14.0,t*0.07,p.seed+23.0));
    float occupancy = smoothstep(0.20+0.15*p.fragmentation,0.45+0.15*p.fragmentation,field);
    float pearl = clamp(spectralGaussian(orbitDistance(u,0.643+t*0.017),0.033)
                      +spectralGaussian(orbitDistance(u,0.132+t*0.025),0.017),0.0,1.0);
    vec3 film = spectralFilm(v,p.hueShift*0.8);
    // Flat light, no ridged noise, marble caustics, radial displacement or bright tube rim.
    vec3 colour = film*warm*skin*(0.88+0.12*field);
    colour = mix(colour,vec3(0.82,0.87,0.86)*skin*(0.76+0.24*orbitNoise(orbitCircle(u,0.0,190.0,t*0.08,p.seed+9.0))),pearl*(0.68+0.25*occupancy));
    colour *= 1.0-p.fragmentation*(1.0-occupancy)*0.85;
    colour *= p.shape3; // Film mix affects the colour layer; bars remain independent.
    for (int layer=0; layer<3; layer++) {
        float l = float(layer);
        float count = layer==0 ? 173.0 : (layer==1 ? 389.0 : 857.0);
        // Independent travelling layers; q has no radial dependence, so lines stay straight.
        float drift = layer==0 ? 0.012 : (layer==1 ? 0.018 : -0.007);
        float q = fract(u-t*drift-0.003*p.turbulence*sin(t*0.6+l))*count;
        float cell = floor(q);
        float h = orbitHash(vec3(cell,l+7.0,p.seed));
        float h2 = orbitHash(vec3(cell,l+19.0,p.seed));
        float birthPhase = orbitHash(vec3(cell,l+41.7,p.seed+12.0));
        float phase = t*p.shape2*(0.65+h*0.35) + birthPhase*ORBIT_TAU;
        float life = smoothstep(-0.45+0.32*p.fragmentation,0.35,
                               sin(phase)+0.15*p.turbulence*sin(t*0.87+h*6.0));
        life *= smoothstep(0.72-p.density*0.65,0.83-p.density*0.65,h2);
        float centre = 0.18+0.64*h2;
        float distance = abs(fract(q)-centre);
        float pixelWidth = count/max(angularPixels,1.0);
        float line = spectralStroke(distance,(0.013+0.027*h*h)*p.shape1,pixelWidth);
        float start = 0.025+h*0.30;
        float end = min(0.985,start+(0.62+h2*0.36-start)*p.shape0);
        float body = smoothstep(start-dv,start+dv,v)*(1.0-smoothstep(end-dv,end+dv,v));
        float breakCentre = 0.22+h2*0.50;
        float breakWidth = 0.025+0.11*h;
        float interruption = smoothstep(breakWidth-dv,breakWidth+dv,abs(v-breakCentre));
        float cap = max(spectralStroke(v-start,0.007,dv),spectralStroke(v-end,0.007,dv));
        cap *= spectralStroke(distance,(0.12+0.12*h2)*p.shape1,pixelWidth);
        // Some broad pale chips make the uneven white segments in the reference.
        float plate = spectralStroke(distance,(0.10+0.11*h)*p.shape1,pixelWidth)*body;
        float plateLife = smoothstep(0.25,0.75,h)*life;
        vec3 pale = mix(vec3(0.27,0.39,0.45),vec3(0.91,0.93,0.88),h);
        pale = mix(pale,film,warm*0.25);
        float onDark = 1.0-0.88*smoothstep(0.18,0.70,warm);
        float fine = (line*body*interruption*6.0+cap*1.3)*life;
        float chips = plate*plateLife*(2.1+0.4*pearl);
        colour += pale*(fine+chips)*((0.65+0.55*p.energy)/0.98)*onDark*(0.38+0.62*occupancy)/(1.0+l*0.75);
    }
    // Broken, faint edge fragments retain the flat strip's profile.
    float edgeOccupancy = smoothstep(0.43,0.68,orbitNoise(orbitCircle(u,0.0,51.0,t*0.09,p.seed+31.0)))*occupancy;
    float edges = spectralStroke(v-0.07,0.006,dv)+spectralStroke(v-0.92,0.006,dv);
    colour += vec3(0.56,0.66,0.68)*edges*edgeOccupancy*(1.0-warm)*0.16;
    return colour*0.98*orbitBandEdge(v);
}
