// Height, world slope X/Z and vertical speed. Same profile as ocean_tsunami_state.gd.
vec4 ocean_tsunami_wave(vec2 p,vec4 center_radius,vec4 shape,vec4 motion) {
	if(center_radius.w<=0.0) { return vec4(0.0); }
	vec2 radial=p-center_radius.xy;
	float r=length(radial);
	float q=r-center_radius.z;
	float width=max(q<0.0?shape.x:shape.y,0.1);
	float g=exp(-q*q/(width*width));
	float tq=q+shape.x*2.2;
	float tw=max(shape.z,0.1);
	float trough=exp(-tq*tq/(tw*tw));
	float f=g-motion.z*trough;
	float derivative=center_radius.w*(-2.0*q*g/(width*width)+motion.z*2.0*tq*trough/(tw*tw));
	float angular_delta=atan(radial.y,radial.x)-motion.w;
	angular_delta=mod(angular_delta+3.14159265,6.2831853)-3.14159265;
	float arc_half_angle=radians(clamp(shape.w,0.0,180.0));
	const float ARC_EDGE_ANGLE=0.5;
	float edge_t=clamp((arc_half_angle-abs(angular_delta))/ARC_EDGE_ANGLE,0.0,1.0);
	float arc_mask=edge_t*edge_t*(3.0-2.0*edge_t);
	float mask_derivative=edge_t>0.0&&edge_t<1.0?-6.0*edge_t*(1.0-edge_t)/ARC_EDGE_ANGLE*sign(angular_delta):0.0;
	vec2 direction=radial/max(r,0.001);
	vec2 angular_gradient=vec2(-radial.y,radial.x)/max(r*r,0.001);
	vec2 slope=derivative*direction*arc_mask+center_radius.w*f*mask_derivative*angular_gradient;
	return vec4(center_radius.w*f*arc_mask,slope,motion.y*f*arc_mask-motion.x*derivative*arc_mask);
}
