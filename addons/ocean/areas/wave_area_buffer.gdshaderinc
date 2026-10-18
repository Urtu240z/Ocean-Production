struct WaveAreaRecord { mat4 inverse_frame; vec4 shape; vec4 blend; vec4 meta; vec4 reserved; };
layout(std430,set=0,binding=WAVE_AREA_BINDING) readonly buffer WaveAreaBuffer {
	vec4 wave_area_header;
	WaveAreaRecord wave_area_records[8];
	vec4 local_fft_data[4];
	vec4 tsunami_data[3];
};
layout(set=0,binding=LOCAL_FFT_BINDING) uniform sampler2D local_fft_0_0;
layout(set=0,binding=LOCAL_FFT_BINDING+1) uniform sampler2D local_fft_0_1;
layout(set=0,binding=LOCAL_FFT_BINDING+2) uniform sampler2D local_fft_0_2;
layout(set=0,binding=LOCAL_FFT_BINDING+3) uniform sampler2D local_fft_1_0;
layout(set=0,binding=LOCAL_FFT_BINDING+4) uniform sampler2D local_fft_1_1;
layout(set=0,binding=LOCAL_FFT_BINDING+5) uniform sampler2D local_fft_1_2;
vec3 wave_area_fft_displacement(int state,vec2 q,vec3 weights,vec3 horizontal) {
	vec4 space=local_fft_data[state*2];
	if(space.z<0.5) { return vec3(0.0); }
	vec3 domains=local_fft_data[state*2+1].xyz;
	vec2 p=q/max(space.x,0.001);
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
	value.xz=(a.xz*weights.x*horizontal.x+b.xz*weights.y*horizontal.y+c.xz*weights.z*horizontal.z)*space.x;
	value.y*=space.y;
	return value;
}
vec3 wave_areas_displacement(vec2 q,vec3 base,vec3 weights,vec3 horizontal) {
	vec3 value=base;
	for(int i=0;i<int(wave_area_header.x);i++) {
		WaveAreaRecord area=wave_area_records[i];
		float w=wave_area_weight(vec3(q.x,wave_area_header.z,q.y),area.inverse_frame,area.shape,area.blend)*area.meta.z;
		if(w>0.0) { value=mix(value,wave_area_fft_displacement(int(area.meta.x),q,weights,horizontal),w); }
	}
	return value;
}
