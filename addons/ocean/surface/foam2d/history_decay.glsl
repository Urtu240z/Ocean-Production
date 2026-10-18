#[compute]
#version 450
layout(local_size_x=8, local_size_y=8) in;
layout(set=0,binding=0) uniform sampler2D previous_fields;
layout(rgba16f,set=0,binding=1) writeonly uniform image2D next_fields;
layout(set=0,binding=2) uniform sampler2D previous_speed;
layout(rg16f,set=0,binding=3) writeonly uniform image2D next_speed;
layout(set=0,binding=4) uniform sampler2D previous_transport;
layout(rgba16f,set=0,binding=5) writeonly uniform image2D next_transport;
layout(set=0,binding=6) uniform sampler2D wave_long;
layout(set=0,binding=7) uniform sampler2D wave_mid;
layout(set=0,binding=8) uniform sampler2D wave_short;
layout(set=0,binding=9) uniform sampler2D crest_long;
layout(push_constant,std430) uniform Params {
	vec4 region; vec4 timing; vec4 motion;
	vec4 drift; // strength, max speed, crest mix, previous source sample valid
	vec4 domains; // effective world domains XYZ, horizontal Ocean Space scale
} pc;
float hash21(vec2 p) {
	vec3 q=fract(vec3(p.xyx)*0.1031); q+=dot(q,q.yzx+33.33);
	return fract((q.x+q.y)*q.z);
}
float noise2(vec2 p) {
	vec2 i=floor(p), f=fract(p); f=f*f*(3.0-2.0*f);
	return mix(mix(hash21(i),hash21(i+vec2(1,0)),f.x),mix(hash21(i+vec2(0,1)),hash21(i+vec2(1,1)),f.x),f.y);
}
void main() {
	ivec2 p=ivec2(gl_GlobalInvocationID.xy), size=imageSize(next_fields);
	if(any(greaterThanEqual(p,size))) return;
	vec2 world=pc.region.xy+(vec2(p)+0.5)*pc.timing.z;
	vec2 uv=(world-pc.region.zw)/128.0;
	vec4 f=vec4(0);
	vec2 metadata=vec2(0.0);
	vec2 detail_offset=vec2(0.0);
	bool wave_active=pc.drift.x>0.0 && pc.domains.x>0.0;
	vec2 displacement=vec2(0.0);
	if(wave_active) {
		displacement=(texture(wave_long,world/pc.domains.x+0.5).xz
			+texture(wave_mid,world/pc.domains.y+0.5).xz
			+texture(wave_short,world/pc.domains.z+0.5).xz)*pc.domains.w;
		if(any(isnan(displacement)) || any(isinf(displacement))) displacement=vec2(0.0);
	}
	if(all(greaterThanEqual(uv,vec2(0))) && all(lessThan(uv,vec2(1)))) {
		vec4 here=texture(previous_fields,uv);
		vec2 velocity=here.gb/max(here.r,0.00001);
		// Extend the incoming velocity by one cell at the advancing foam edge.
		// Without this, empty texels have zero velocity and the wake cannot open.
		if(here.r<0.035) {
			float best=here.r;
			for(int i=0;i<4;i++) {
				vec2 offset=vec2(i==0?1.0:(i==1?-1.0:0.0),i==2?1.0:(i==3?-1.0:0.0))*pc.timing.z/128.0;
				vec4 adjacent=texture(previous_fields,uv+offset);
				if(adjacent.r>best && dot(adjacent.gb,-offset)>0.0) {
					best=adjacent.r;
					velocity=adjacent.gb/max(adjacent.r,0.00001);
				}
			}
		}
		// Transport the stored pigment velocity, plus optional background drift.
		// This moves only the visual history, never wave geometry or physics.
		float phase=pc.motion.w*pc.motion.z;
		vec2 flow=vec2(sin(world.y*0.53+phase*0.8),-cos(world.x*0.47-phase*0.63));
		// Stored velocity already includes the launch's wake-opening setting.
		// Radial contact transport remains active even when that opening is zero.
		velocity+=flow*pc.motion.y;
		vec2 wave_velocity=vec2(0.0);
		if(wave_active && pc.drift.w>0.5) {
			vec2 before=texture(previous_transport,uv).rg;
			wave_velocity=(displacement-before)/max(pc.timing.x,0.00001)*pc.drift.x;
			float speed=length(wave_velocity);
			wave_velocity*=min(1.0,pc.drift.y/max(speed,0.00001));
		}
		velocity+=wave_velocity;
		vec2 back=uv-velocity*pc.timing.x/128.0;
		if(all(greaterThanEqual(back,vec2(0))) && all(lessThan(back,vec2(1)))) {
			f=texture(previous_fields,back);
			metadata=texture(previous_speed,back).rg;
			if(pc.drift.x>0.0) {
				// Premultiplication keeps empty texels from dragging the pattern
				// towards an unrelated coordinate. New stamps start at offset zero.
				detail_offset=texture(previous_transport,back).ba+wave_velocity*pc.timing.x*f.r;
			}
		}
	}
	float erosion_noise=noise2(world*0.71+vec2(23.4,11.8));
	float coverage_fade=exp(-pc.timing.x*(0.12+erosion_noise*0.24)*pc.timing.w);
	f*=coverage_fade;
	metadata*=coverage_fade;
	detail_offset*=coverage_fade;
	if(wave_active && pc.drift.z>0.0 && f.r>0.001) {
		float crest=clamp(texture(crest_long,world/pc.domains.x+0.5).g,0.0,1.0);
		f.a=mix(f.a,max(f.a,f.r*crest),1.0-exp(-pc.timing.x*6.0*pc.drift.z));
	}
	metadata.g*=exp(-pc.timing.x);
	f.gb*=exp(-pc.timing.x*0.045);
	f.a*=exp(-pc.timing.x*pc.timing.y);
	if(f.r<0.001) { f=vec4(0); metadata=vec2(0.0); }
	imageStore(next_fields,p,f);
	imageStore(next_speed,p,vec4(metadata,0,0));
	if(f.r<0.001) detail_offset=vec2(0.0);
	imageStore(next_transport,p,vec4(displacement,detail_offset));
}
