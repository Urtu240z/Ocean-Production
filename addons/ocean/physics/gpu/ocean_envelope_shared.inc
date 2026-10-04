struct Tile { vec4 center_size; uvec4 stamp; uvec4 owner; vec4 atlas; };
layout(std430,set=1,binding=1) readonly buffer Tiles { Tile tiles[]; };
layout(std430,set=1,binding=2) readonly buffer Extrema { uint maxima[16]; };
vec3 coverage_bound() {
    float confidence=p.settings.y>0.5?uintBitsToFloat(maxima[10])*uintBitsToFloat(maxima[11]):0.0;
    float negative=p.settings.y>0.5?max(uintBitsToFloat(maxima[14])*uintBitsToFloat(maxima[11]),uintBitsToFloat(maxima[15])*uintBitsToFloat(maxima[10])):0.0;
    float long_factor=max(1.0+2.0*negative,2.0*confidence-1.0);
    float shoal=confidence<=1.0?max(1.0,uintBitsToFloat(maxima[9])):1.0+confidence*(1.0+uintBitsToFloat(maxima[9]));
    shoal=max(shoal,1.0+negative*(1.0+uintBitsToFloat(maxima[9])));
    vec3 bound;
    for(int axis=0;axis<3;axis++) bound[axis]=uintBitsToFloat(maxima[axis])*long_factor*(axis==1?shoal:1.0)+uintBitsToFloat(maxima[3+axis])+uintBitsToFloat(maxima[6+axis]);
    // Bilinear samples are convex. Upward slack covers FP32 extrema/scaling.
    return bound*abs(vec3(p.scales_time.x,p.scales_time.y,p.scales_time.x))*1.00001+vec3(0.01);
}
