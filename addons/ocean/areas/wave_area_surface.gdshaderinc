#include "res://addons/ocean/areas/wave_area_math.gdshaderinc"
uniform int wave_area_count = 0;
uniform mat4 wave_area_inverse[8];
uniform vec4 wave_area_shape[8];
uniform vec4 wave_area_blend[8];
uniform vec4 wave_area_meta[8];
uniform float wave_area_detail_strength[8];
uniform float wave_area_sea_level = 0.0;
uniform bool wave_area_displaced = false;
uniform vec4 local_fft_space_0 = vec4(1.0,1.0,0.0,0.0);
uniform vec4 local_fft_space_1 = vec4(1.0,1.0,0.0,0.0);
uniform vec3 local_fft_domains_0 = vec3(512.0,137.0,37.0);
uniform vec3 local_fft_domains_1 = vec3(512.0,137.0,37.0);
uniform sampler2D local_fft_0_0 : filter_linear, repeat_enable;
uniform sampler2D local_fft_0_1 : filter_linear, repeat_enable;
uniform sampler2D local_fft_0_2 : filter_linear, repeat_enable;
uniform sampler2D local_fft_1_0 : filter_linear, repeat_enable;
uniform sampler2D local_fft_1_1 : filter_linear, repeat_enable;
uniform sampler2D local_fft_1_2 : filter_linear, repeat_enable;
varying float wave_area_base_height;
varying vec2 wave_area_q;

float wave_area_coverage(vec3 p) {
	float value = 0.0;
	for (int i=0;i<wave_area_count;i++) {
		float w=wave_area_weight(p,wave_area_inverse[i],wave_area_shape[i],wave_area_blend[i])*wave_area_meta[i].z;
		value=mix(value,1.0,w);
	}
	return value;
}
float wave_area_detail_weight(vec3 p) {
	float value=1.0;
	for(int i=0;i<wave_area_count;i++) {
		float w=wave_area_weight(p,wave_area_inverse[i],wave_area_shape[i],wave_area_blend[i])*wave_area_meta[i].z;
		value=mix(value,wave_area_detail_strength[i],w);
	}
	return value;
}
vec3 local_fft_displacement(int state,vec2 q) {
	vec4 space=state==0?local_fft_space_0:local_fft_space_1;
	vec3 domains=state==0?local_fft_domains_0:local_fft_domains_1;
	vec2 p=q/max(space.x,0.001);
	float d=distance(q,camera_world_xz);
	vec3 weights=vec3(fade_weight(d,long_fade_range_m),fade_weight(d,mid_fade_range_m),fade_weight(d,short_fade_range_m));
	vec3 a; vec3 b; vec3 c;
	if(state==0) {
		a=textureLod(local_fft_0_0,fract(p/domains.x+vec2(0.5)),0.0).xyz;
		b=textureLod(local_fft_0_1,fract(p/domains.y+vec2(0.5)),0.0).xyz;
		c=textureLod(local_fft_0_2,fract(p/domains.z+vec2(0.5)),0.0).xyz;
	} else {
		a=textureLod(local_fft_1_0,fract(p/domains.x+vec2(0.5)),0.0).xyz;
		b=textureLod(local_fft_1_1,fract(p/domains.y+vec2(0.5)),0.0).xyz;
		c=textureLod(local_fft_1_2,fract(p/domains.z+vec2(0.5)),0.0).xyz;
	}
	vec3 value=a*weights.x+b*weights.y+c*weights.z;
	value.xz*=space.x;
	value.y*=space.y;
	value.xz=(a.xz*visual_horizontal_displacement_scale.x*weights.x+b.xz*visual_horizontal_displacement_scale.y*weights.y+c.xz*visual_horizontal_displacement_scale.z*weights.z)*space.x;
	return value;
}
vec3 wave_areas_displacement(vec3 p,vec3 base) {
	vec3 value=base;
	vec3 cached0=vec3(0.0); vec3 cached1=vec3(0.0);
	bool ready0=false; bool ready1=false;
	for(int i=0;i<wave_area_count;i++) {
		float w=wave_area_weight(p,wave_area_inverse[i],wave_area_shape[i],wave_area_blend[i])*wave_area_meta[i].z;
		if(w>0.0) {
			int state=int(wave_area_meta[i].x);
			vec3 local=state==0?cached0:cached1;
			bool ready=state==0?ready0:ready1;
			if(!ready) {
				local=local_fft_displacement(state,p.xz);
				if(state==0) {cached0=local;ready0=true;}
				else {cached1=local;ready1=true;}
			}
			value=mix(value,local,w);
		}
	}
	return value;
}
// Keep the common compose entry point used by generated foam surface variants.
vec4 wave_areas_compose(vec3 p,vec4 base) {
	vec4 value=base;
	vec3 cached0=vec3(0.0); vec3 cached1=vec3(0.0);
	bool ready0=false; bool ready1=false;
	for(int i=0;i<wave_area_count;i++) {
		float w=wave_area_weight(p,wave_area_inverse[i],wave_area_shape[i],wave_area_blend[i])*wave_area_meta[i].z;
		if(w<=0.0) { continue; }
		int state=int(wave_area_meta[i].x);
		float e=0.1;
		vec3 local=state==0?cached0:cached1;
		bool ready=state==0?ready0:ready1;
		if(!ready) {
			vec3 center=local_fft_displacement(state,p.xz);
			vec3 dx=(local_fft_displacement(state,p.xz+vec2(e,0.0))-local_fft_displacement(state,p.xz-vec2(e,0.0)))/(2.0*e);
			vec3 dz=(local_fft_displacement(state,p.xz+vec2(0.0,e))-local_fft_displacement(state,p.xz-vec2(0.0,e)))/(2.0*e);
			vec3 n=normalize(cross(vec3(dz.x,dz.y,1.0+dz.z),vec3(1.0+dx.x,dx.y,dx.z)));
			vec2 slope=-n.xz/max(n.y,0.01);
			local=vec3(center.y,slope);
			if(state==0) {cached0=local;ready0=true;}
			else {cached1=local;ready1=true;}
		}
		vec2 dw=vec2(wave_area_weight(p+vec3(e,0.0,0.0),wave_area_inverse[i],wave_area_shape[i],wave_area_blend[i])-wave_area_weight(p-vec3(e,0.0,0.0),wave_area_inverse[i],wave_area_shape[i],wave_area_blend[i]),wave_area_weight(p+vec3(0.0,0.0,e),wave_area_inverse[i],wave_area_shape[i],wave_area_blend[i])-wave_area_weight(p-vec3(0.0,0.0,e),wave_area_inverse[i],wave_area_shape[i],wave_area_blend[i]))*wave_area_meta[i].z/(2.0*e);
		value.yz=mix(value.yz,local.yz,w)+dw*(local.x-value.x);
		value.x=mix(value.x,local.x,w);
	}
	return value;
}
float wave_area_foam_weight(vec3 p) {
	// Global residual foam must not paint the exterior crests onto sheltered seas.
	return 1.0-wave_area_coverage(p);
}
