// Texture input is display-referred SDR RGB. Neutral controls preserve the extracted pixels.
float3 textureColor(float2 uv, OrbitParams p, texture2d<float> source) {
    constexpr sampler sampling(coord::normalized, s_address::repeat, t_address::clamp_to_edge,
                               min_filter::linear, mag_filter::linear);
    if (p.testPattern > 0.5) uv.x = fract(uv.x - p.phaseTime * p.markerWidth);
    float a = ORBIT_TAU * uv.x;
    uv.x = fract(uv.x + sin(a * 3.0 + p.phaseTime * 0.4) * p.turbulence * 0.018 * sin(uv.y * 3.14159265));
    uv.y = clamp(uv.y + sin(a * 2.0 - p.phaseTime * 0.6) * p.turbulence * 0.12, 0.0, 1.0);
    float3 color = source.sample(sampling, uv).rgb;
    float contrast = exp2((p.density - 0.5) * 1.5);
    color = max((color - 0.5) * contrast + 0.5, 0.0);
    if (p.energy > 0.0) {
        float2 d = float2(2.0 / source.get_width(), 2.0 / source.get_height());
        float3 soft = source.sample(sampling, uv + float2(d.x,0)).rgb
                    + source.sample(sampling, uv - float2(d.x,0)).rgb
                    + source.sample(sampling, uv + float2(0,d.y)).rgb
                    + source.sample(sampling, uv - float2(0,d.y)).rgb;
        color += soft * (p.energy * 0.125);
    }
    if (abs(p.hueShift) > 0.00001) {
        float3 axis = float3(0.57735026919);
        float angle = p.hueShift * ORBIT_TAU;
        color = color * cos(angle) + cross(axis, color) * sin(angle)
              + axis * dot(axis, color) * (1.0 - cos(angle));
    }
    return color;
}
float4 sampleTexturePixel(float2 pixel, OrbitParams p, texture2d<float> source) {
    float3 uv = orbitCoordinates(pixel,p);
    if (uv.z <= 0.0) return float4(0,0,0,1);
    float3 color = textureColor(uv.xy,p,source);
    color = clamp(color * p.brightness,0.0,1.0) * uv.z * orbitPresence(uv.xy,p);
    return float4(color,1.0);
}
