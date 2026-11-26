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
    float accent[216]; // 24 independent voices × 9 floats; must match Swift accentCapacity
    float accentSerial;
    float trace[192]; // 16 independent passage memories × 12 floats
    float traceSerial;
    float lastTraceBirth;
    float lastTraceCenter;
};


float pulseDistance(float a,float b) {return abs(fract(a-b+0.5)-0.5);}
// Only received commands supply accent energy. Resting light has no time noise.
float pulseMotion(constant PulseOrbitParams &s) {
    float energy=0.0;
    for(int n=0;n<24;n++) {
        int k=n*9;
        if(s.accent[k]<0.5) break;
        float age=s.simulationTime-s.accent[k+1],duration=s.accent[k+2];
        if(age>=0.0 && age<duration)
            energy=max(energy,smoothstep(0.0,0.18,age)
                *(1.0-smoothstep(duration-1.4,duration,age))*s.accent[k+6]);
    }
    return energy;
}
float pulseRadius(int lane) {
    const float radii[10]={0.18,0.5,0.82,0.34,0.66,0.1,0.9,0.26,0.74,0.58};
    return radii[clamp(lane,0,9)];
}
// A local lens folds the moving paths toward the gravity center. It has no
// marker sprite: its location is read through the convergence of the filaments.
float pulseFieldRadius(float radius,float u,OrbitParams p) {
    float d=pulseDistance(u,p.shape0);
    float lens=exp(-pow(d/(0.035+0.045*p.turbulence),2.0))*p.turbulence;
    return 0.5+(radius-0.5)*(1.0-0.68*lens);
}
// A sharp tapered core with a local halo, evaluated at native output resolution.
// Glow follows the stroke; it is never an image-wide blur or a texture.
float pulseStroke(float2 uv,float head,float direction,float radius,float span,float width,float aa,float halo=0.19) {
    float behind=fract((head-uv.x)*direction);
    float cap=1.0-smoothstep(0.0,max(width*0.02,0.00015),pulseDistance(head,uv.x));
    float tail=max(cap,clamp(1.0-behind/max(span,0.0001),0.0,1.0));
    float taper=pow(tail,0.62);
    float d=abs(uv.y-radius);
    float halfWidth=width*(0.12+0.88*taper);
    float core=(1.0-smoothstep(max(0.0,halfWidth-aa),halfWidth+aa,d))*pow(tail,0.45);
    float glow=exp(-pow(d/max(width*3.2,0.006),2.0))*tail*halo;
    return core+glow;
}
float pulseRibbon(float2 uv,float head,float direction,float radius,float span,float width,float aa,OrbitParams p,float energy) {
    float curved=pulseFieldRadius(radius,uv.x,p);
    if(abs(uv.y-curved)>0.15) return 0.0;
    float center=pulseStroke(uv,head,direction,curved,span,width,aa,mix(0.30,0.40,energy));
    float spread=0.045*(1.0-0.5*p.turbulence*exp(-pow(pulseDistance(uv.x,p.shape0)/0.07,2.0)));
    float upper=pulseStroke(uv,fract(head-direction*0.008),direction,curved+spread,span*0.86,width*0.60,aa);
    float lower=pulseStroke(uv,fract(head+direction*0.006),direction,curved-spread,span*0.68,width*0.48,aa);
    return max(center,max(upper*0.68,lower*0.48));
}
// Perpendicular marks belong only to explicit trigger commands.
// All ages and positions come from the shared simulation, including pause.
float3 pulseRadialAccents(float2 uv,constant PulseOrbitParams &s,float motion,float aa) {
    OrbitParams p=s.base;
    float angularPixel=1.0/max(p.outputWidth,1.0);
    if(p.viewMode>1.5) angularPixel=3840.0/(p.outputWidth*15444.0);
    else if(p.viewMode>0.5) angularPixel=1.0/max(ORBIT_TAU*min(p.outputWidth,p.outputHeight)*0.34722222*0.94,1.0);
    float3 rgb=0;
    for(int n=0;n<16;n++) {
        int k=n*12;
        float duration=s.trace[k+1];
        if(duration<=0.0) break;
        float age=s.simulationTime-s.trace[k];
        if(age<0.0 || age>=duration) continue;
        float level=smoothstep(0.0,0.15,age)*(1.0-smoothstep(duration*0.42,duration,age));
        float release=s.trace[k+9];
        if(release>=0.0) level=s.trace[k+11]*(1.0-smoothstep(0.0,s.trace[k+10],s.simulationTime-release));
        if(level<=0.0) continue;
        float u=s.trace[k+2],d=pulseDistance(uv.x,u);
        float w=0.00085*(0.35+0.65*level);
        if(d>max(w*5.0,angularPixel*3.0)) continue;
        float center=s.trace[k+4];
        float halfLength=s.trace[k+5]*(0.28+0.72*sqrt(level));
        float y=abs(uv.y-center);
        float radial=1.0-smoothstep(max(0.0,halfLength-aa),halfLength+aa,y);
        float core=1.0-smoothstep(max(0.0,w-angularPixel*0.6),w+angularPixel*0.6,d);
        float halo=exp(-pow(d/max(w*3.0,angularPixel),2.0))*0.32;
        float ends=exp(-pow(y/max(halfLength*1.25,0.001),6.0));
        float light=(core*radial+halo*ends)*level*s.trace[k+6];
        rgb=max(rgb,(s.trace[k+7]>0.5?float3(1):float3(1,0,0))*light);
    }
    return rgb;
}
float3 pulseOrbitShade(float2 uv,constant PulseOrbitParams &s,float motion) {
    OrbitParams p=s.base;
    float pixel=1.0/max(p.outputHeight,1.0);
    if(p.viewMode>1.5) pixel=2160.0/(p.outputHeight*300.0);
    else if(p.viewMode>0.5) pixel=1.0/max(min(p.outputWidth,p.outputHeight)*0.34722222*clamp(p.ringWidth,0.01,0.6),1.0);
    float aa=pixel*0.65;
    float time=s.simulationTime;
    float3 rgb=pulseRadialAccents(uv,s,motion,aa);
    // Unequal, opposing flows gather, pass and stretch. Density reveals 1–9 voices.
    for(int lane=0;lane<clamp(int(s.lineCount),3,10);lane++) {
        float radius=pulseRadius(lane);
        float guide=(1.0-smoothstep(max(0.0,0.0015-aa),0.0015+aa,abs(uv.y-pulseFieldRadius(radius,uv.x,p))))*(lane<3?0.008:0.022);
        rgb=max(rgb,float3(guide)*float3(1.0,0.65,0.65));
        if(lane>=3) continue;
        for(int slot=0;slot<3;slot++) {
            float active=clamp(1.0+8.0*p.shape2-float(lane+slot*3),0.0,1.0);
            if(active<=0) continue;
            int index=lane*4+slot;
            float velocity=s.velocity[index];
            float direction=(p.density<0.5?-1.0:1.0)*(lane==1?-1.0:1.0);
            float life=slot==0 ? 1.0 : 0.70+0.30*motion;
            float speed=clamp(abs(velocity)/0.32,0.0,1.0);
            float span=lane==1 ? mix(0.035,0.105,motion)*mix(0.8,1.0,speed)
                              : mix(0.050,0.085,motion)*mix(0.8,1.0,speed);
            span*=slot==0 ? 1.0 : (slot==1 ? 0.48 : 0.30);
            // Bright commas with unequal lengths leave generous black space.
            // An event extends them briefly without winding a long ribbon.
            float head=s.position[index];
            float near=exp(-pow(pulseDistance(head,p.shape0)/0.045,2.0));
            span*=1.0-0.55*p.turbulence*near;
            float width=0.040+0.005*near+0.012*motion;
            float light=pulseRibbon(uv,head,direction,radius,span,width,aa,p,motion)*active
                *life*mix(1.45,0.95,motion);
            float3 color=lane==1?float3(1):float3(1,0,0);
            rgb=max(rgb,color*light);
        }
    }
    // A real crossing leaves a short tangent arc rather than a diagram-like spoke.
    for(int pair=0;pair<16;pair++) {
        float age=time-s.eventTime[pair];
        if(motion<=0.0 || age<0.0 || age>0.48 || s.eventStrength[pair]<0.01) continue;
        float fade=smoothstep(0.0,0.025,age)*pow(1.0-age/0.48,2.0);
        float light=pulseStroke(uv,fract(s.eventAngle[pair]+age*0.06),1.0,
            pulseFieldRadius(0.5,uv.x,p),0.025+age*0.07,0.016,aa);
        rgb=max(rgb,float3(light*fade*s.eventStrength[pair]*s.crossFlash*0.5));
    }
    for(int n=0;n<24;n++) {
        int k=n*9;
        int kind=int(s.accent[k]);
        if(kind==0) break;
        float age=time-s.accent[k+1],duration=s.accent[k+2];
        if(kind==0 || age<0 || age>=duration) continue;
        float progress=age/duration;
        float fade=smoothstep(0.0,0.2,age)*(1.0-smoothstep(duration-1.2,duration,age));
        float head=s.accent[k+3],radius=s.accent[k+5],direction=s.accent[k+8];
        float span=0.12,width=0.045;
        float3 color=float3(1,0,0);
        if(kind==1) { // departure: a red ribbon is born, accelerates and thins.
            span=mix(0.012,0.075,smoothstep(0.0,1.1,age));
            width=mix(0.045,0.025,progress);
        } else if(kind==2) { // breakthrough: white light escapes across the band.
            color=float3(1);span=0.09;
            radius=mix(radius,mix(radius,0.94,0.38),smoothstep(0.1,0.85,progress));
            width=0.042;
        } else if(kind==3) { // new orbit: draw from the gravity point, then leave a quiet trace.
            float travel=age/2.8;
            span=min(0.10,travel);
            head=fract(s.accent[k+7]+direction*travel);
            width=0.028;
        } else { // completion: a shortening ribbon gathers and vanishes.
            color=float3(1);
            span=mix(0.09,0.008,smoothstep(0.1,0.9,progress));
            width=mix(0.042,0.008,progress);
        }
        float eventRadius=kind==2 ? mix(pulseFieldRadius(radius,uv.x,p),radius,smoothstep(0.0,0.7,progress))
                                 : pulseFieldRadius(radius,uv.x,p);
        float light=pulseStroke(uv,head,direction,eventRadius,span,width,aa)*fade*s.accent[k+6];
        // Max blending keeps overlapping events from adding up to a white wash.
        rgb=max(rgb,color*light);
    }
    return rgb;
}
// A quiet, lens-shaped weave occupies the same LED band as the travelling light.
// The field stays steady while the light drifts; commands tighten and light it.
float3 pulseGravityField(float2 uv,OrbitParams p,float motion) {
    float radialPixel=1.0/max(p.outputHeight,1.0);
    if(p.viewMode>1.5) {
        radialPixel=2160.0/(p.outputHeight*300.0);
    } else if(p.viewMode>0.5) {
        float outer=min(p.outputWidth,p.outputHeight)*0.34722222;
        float width=clamp(p.ringWidth,0.01,0.6);
        radialPixel=1.0/max(outer*width,1.0);
    }
    float d=pulseDistance(uv.x,p.shape0);
    float g=clamp(p.turbulence,0.0,1.0);
    if(g<=0.0 || d>0.13) return float3(0);
    float envelope=exp(-pow(d/(0.035+0.035*g),2.0));
    float fold=1.0-exp(-pow(d/(0.024+0.03*g),2.0));
    float breath=0.95+0.05*motion;
    float3 rgb=0;
    for(int strand=0;strand<6;strand++) {
        float side=(float(strand)-2.5)/2.5;
        float radius=0.5+side*(0.028+(0.22+0.12*g)*fold);
        float dist=abs(uv.y-radius);
        float width=0.0035+0.002*g;
        float core=1.0-smoothstep(max(0.0,width-radialPixel*0.55),width+radialPixel*0.55,dist);
        float glow=exp(-pow(dist/0.035,2.0))*0.09;
        float strength=(core+glow)*envelope*sqrt(g)*breath*mix(strand==2||strand==3?0.85:0.50,strand==2||strand==3?0.62:0.37,motion);
        rgb=max(rgb,(strand==2||strand==3?float3(1):float3(1,0,0))*strength);
    }
    // A restrained, diffuse red afterimage occupies the field between travelling
    // phrases. It contracts during acceleration; it is a volume of light, not dots.
    float quiet=1.0-motion;
    float mist=exp(-pow(d/(0.018+0.026*quiet),2.0))
        *exp(-pow((uv.y-0.5)/(0.10+0.08*quiet),2.0));
    rgb=max(rgb,float3(1,0,0)*mist*g*(0.035+0.04*quiet)*breath);
    return rgb;
}
float4 samplePulseOrbit(float2 pixel,constant PulseOrbitParams &state) {
    OrbitParams p=state.base;
    float3 uv=orbitCoordinates(pixel,p);
    if(uv.z<=0.0) return float4(0,0,0,1);
    float motion=pulseMotion(state);
    // Common gap animation must not add autonomous pulses to the quiet current.
    p.phaseTime=0.0;
    float3 rgb=pulseOrbitShade(uv.xy,state,motion)*orbitPresence(uv.xy,p);
    rgb=max(rgb,pulseGravityField(uv.xy,p,motion))*p.brightness*uv.z;
    return float4(clamp(rgb,0.0,1.0),1.0);
}
