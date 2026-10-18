// Height, world slope X/Z and vertical speed. Same profile as ocean_tsunami_state.gd.
vec4 ocean_tsunami_wave(vec2 p,vec4 center_radius,vec4 shape,vec4 motion) {
	if(center_radius.w<=0.0) { return vec4(0.0); }
	vec2 radial=p-center_radius.xy;
	float r=length(radial);
	float q=r-center_radius.z;
	float width=max(q<0.0?shape.x:shape.y,0.1);
	float g=exp(-q*q/(width*width));
	float tq=q+shape.w;
	float tw=max(shape.z,0.1);
	float trough=exp(-tq*tq/(tw*tw));
	float f=g-motion.z*trough;
	float derivative=center_radius.w*(-2.0*q*g/(width*width)+motion.z*2.0*tq*trough/(tw*tw));
	return vec4(center_radius.w*f,derivative*radial/max(r,0.001),motion.y*f-motion.x*derivative);
}
