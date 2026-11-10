struct HybridControls { float generation; float sharpness; float evolution; float detail; };
float3 sharpReference(float2 uv, texture2d<float> source, float amount) {
    constexpr sampler s(coord::normalized,s_address::repeat,t_address::clamp_to_edge,filter::linear);
    float2 px=1.0/float2(source.get_width(),source.get_height());
    float3 center=source.sample(s,uv).rgb;
    float3 neighbors=(source.sample(s,uv+float2(px.x,0)).rgb+source.sample(s,uv-float2(px.x,0)).rgb
                    +source.sample(s,uv+float2(0,px.y)).rgb+source.sample(s,uv-float2(0,px.y)).rgb)*0.25;
    // Bounded edge enhancement, not an attempt to recover missing source pixels.
    return clamp(center+clamp(center-neighbors,-0.12,0.12)*amount*1.6,0.0,1.0);
}
float4 hybridPixel(float2 pixel, OrbitParams p, HybridControls c, texture2d<float> source) {
    float3 mapped=orbitCoordinates(pixel,p);
    if(mapped.z<=0.0) return float4(0,0,0,1);
    float2 uv=mapped.xy;
    float t=p.phaseTime*(0.25+c.evolution*1.5);
    float gen=clamp(c.generation,0.0,1.0);
    float a=ORBIT_TAU*uv.x;
    float f=orbitFbm(orbitCircle(uv.x,uv.y*0.7,3.4,t*0.24,p.seed));
    float g=orbitFbm(orbitCircle(uv.x,uv.y*0.9,5.7,-t*0.19,p.seed+6.1));
    float strength=gen*(0.35+c.evolution*0.65+p.turbulence);
    // Neighboring parts evolve differently; no rigid rotation of the seed image.
    float2 flow=float2(fract(uv.x+(f-0.5)*strength*0.085),
                      clamp(uv.y+(g-0.5)*strength*0.38,0.0,1.0));
    float3 ref=sharpReference(flow,source,c.sharpness);
    float luma=dot(ref,float3(0.2126,0.7152,0.0722));
    float3 palette=clamp(ref/max(luma,0.15),0.0,2.0);
    OrbitParams q=p;
    q.phaseTime=t; q.hueShift=0.0;
    q.density=0.25+c.detail*0.65; q.turbulence=0.35+c.evolution*0.6;
    q.energy=0.58+p.energy*0.4;
    float3 procedural=orbitShade(flow,q);
    float power=dot(procedural,float3(0.2126,0.7152,0.0722));
    float3 generated=mix(procedural,palette*power,0.62);
    float life=smoothstep(0.22,0.69,orbitNoise(orbitCircle(uv.x,uv.y*0.2,9.0,t*0.36,p.seed+19.0)));
    generated*=0.22+life*1.15;
    float3 color=mix(ref,generated,gen);
    float3 lightTint=mix(palette,float3(1.0),0.55);
    float angularPixels=p.viewMode>1.5 ? 15444.0 : (p.viewMode>0.5 ? min(p.outputWidth,p.outputHeight)*2.18166 : p.outputWidth);
#if ORBIT_STYLE == 4
    float count=floor(1000.0+c.detail*1200.0);
    float aa=1.0-smoothstep(0.18,0.65,count/angularPixels);
    float strand=pow(0.5+0.5*sin(a*count+g*10.0-uv.y*4.0-t*2.0),28.0);
    float tip=1.0-smoothstep(0.35+f*0.5,0.55+f*0.5,uv.y);
    color+=lightTint*strand*tip*life*gen*(0.10+c.detail*0.45)*aa;
#elif ORBIT_STYLE == 7
    float count=floor(210.0+c.detail*200.0);
    float cell=floor(fract(uv.x)*count);
    float h=orbitHash(float3(cell,3.7,p.seed));
    float birth=smoothstep(-0.45,0.35,sin(t*(0.45+h)+h*47.0));
    float bar=1.0-smoothstep(0.15+h*0.4,0.20+h*0.4,fract(uv.x*count));
    float radial=smoothstep(h*0.4,h*0.4+0.04,uv.y)*(1.0-smoothstep(0.6+h*0.2,0.68+h*0.2,uv.y));
    color*=mix(1.0,0.15+birth*0.85,gen*0.75);
    color+=lightTint*bar*birth*radial*gen*c.detail*0.55;
#elif ORBIT_STYLE == 8 || ORBIT_STYLE == 3
    float count=floor(900.0+c.detail*900.0);
    float aa=1.0-smoothstep(0.18,0.65,count/angularPixels);
    float2 grid=float2(fract(uv.x)*count,uv.y*24.0);
    float2 cell=floor(grid);
    float h=orbitHash(float3(cell,p.seed));
    float2 point=fract(grid)-0.5-float2(h-0.5,orbitHash(float3(cell,7.3))-0.5)*0.42;
    float born=smoothstep(0.05,0.65,sin(t*(0.7+h)+h*65.0));
    float dust=exp(-dot(point,point)*90.0)*born*smoothstep(0.55,0.9,h);
    color+=lightTint*dust*gen*c.detail*(0.3+life)*0.9*aa;
#else
    float fold=sin(a*7.0+uv.y*5.0+f*9.0-t*0.7);
    float caustic=exp(-abs(fold)*65.0);
    color+=lightTint*caustic*gen*c.detail*life*0.22;
#endif
    color=max((color-0.5)*exp2((p.density-0.5)*1.5)+0.5,0.0);
    // Emission is localized to generated highlights rather than a full-screen blur.
    color+=lightTint*pow(clamp(power,0.0,1.0),4.0)*p.energy*0.20;
    if(abs(p.hueShift)>0.00001) {
        float3 axis=float3(0.57735026919); float angle=p.hueShift*ORBIT_TAU;
        color=color*cos(angle)+cross(axis,color)*sin(angle)+axis*dot(axis,color)*(1.0-cos(angle));
    }
    color=clamp(color*p.brightness,0.0,1.0)*mapped.z*orbitPresence(uv,p);
    return float4(color,1.0);
}
