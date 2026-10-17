#[compute]
#version 450
layout(local_size_x=8, local_size_y=8) in;
layout(rgba16f,set=0,binding=0) uniform image2D fields;
layout(push_constant,std430) uniform Params {
	vec4 region; // origin, cell size, radial launch speed
	vec4 roi; // min pixel xy, extent xy
	vec4 source; // current hull center XZ, deposit interval, unique seed
	vec4 heading; // hull forward XZ, travelled speed, wake spread
	vec4 previous; // previous hull center XZ, contour irregularity m, edge fade m
	vec4 wet;
	vec4 birth;
	vec4 style; // patch size, irregularity, initial full width m, emission
} pc;
float hash21(vec2 p) {
	vec3 q=fract(vec3(p.xyx)*0.1031);
	q+=dot(q,q.yzx+33.33);
	return fract((q.x+q.y)*q.z);
}
float noise2(vec2 p) {
	vec2 i=floor(p), f=fract(p); f=f*f*(3.0-2.0*f);
	return mix(mix(hash21(i),hash21(i+vec2(1,0)),f.x),mix(hash21(i+vec2(0,1)),hash21(i+vec2(1,1)),f.x),f.y);
}
void main() {
	ivec2 local=ivec2(gl_GlobalInvocationID.xy);
	if(any(greaterThanEqual(local,ivec2(pc.roi.zw)))) return;
	ivec2 p=ivec2(pc.roi.xy)+local;
	vec2 world=pc.region.xy+(vec2(p)+0.5)*pc.region.z;
	vec2 forward=normalize(pc.heading.xy+vec2(0.000001));
	vec2 lateral=vec2(-forward.y,forward.x);
	vec2 segment=pc.source.xy-pc.previous.xy;
	float along_segment=clamp(dot(world-pc.previous.xy,segment)/max(dot(segment,segment),0.00001),0.0,1.0);
	vec2 d=world-mix(pc.previous.xy,pc.source.xy,along_segment);
	float along=dot(d,forward), across=dot(d,lateral);
	float seed=pc.source.w;
	vec2 offset=vec2(hash21(vec2(seed,19.7)),hash21(vec2(71.3,seed)))*91.0;
	// Non-repeating world patches and independent port/starboard variation.
	float scale=max(pc.style.x,0.3);
	// World-coherent lobes survive successive deposits instead of averaging
	// into a straight strip. Only the fine bubbles vary between deposits.
	float coarse=noise2(world*0.83/scale+vec2(17.3,51.8));
	float contour=noise2(world*2.1/scale+vec2(81.6,9.4));
	float fine=noise2(mat2(0.8,-0.6,0.6,0.8)*world*5.7/scale+offset*2.31);
	float filament=1.0-smoothstep(0.035,0.19,abs(fine-0.51));
	// Filled inner hull, hidden initially by the boat. There is no perimeter
	// ring at birth: the same pigment will be transported beyond the sides.
	vec2 hull=vec2(across,along), radii=vec2(max(pc.style.z*0.5,0.1),0.78);
	float k0=length(hull/radii), k1=length(hull/(radii*radii));
	float distance_to_hull=k0<0.2?-0.52:k0*(k0-1.0)/max(k1,0.0001);
	float perturbation=((coarse-0.5)*1.3+(contour-0.5)*0.7)*pc.previous.z;
	float shell=1.0-smoothstep(-0.05,pc.previous.w*0.55,distance_to_hull-perturbation*0.45);
	float detail=mix(0.75,0.24+0.76*filament*(0.28+coarse*0.72),pc.style.y);
	float port=1.0-smoothstep(-0.12,0.12,across);
	float front=smoothstep(-0.2,0.2,along);
	vec4 weights=vec4(port*front,(1.0-port)*front,port*(1.0-front),(1.0-port)*(1.0-front));
	float wet=dot(pc.wet,weights), birth=dot(pc.birth,weights);
	float movement=clamp(pc.heading.z/4.0,0.0,1.0);
	float variation=0.82+hash21(vec2(seed,57.8))*0.36;
	float generation=(0.05+birth*0.10+movement*(0.22+birth*0.20))*variation;
	if(shell<=0.0 || wet<=0.0) return;
	vec4 old=imageLoad(fields,p);
	// A feathered capacity cannot slowly fill the rectangular dispatch bounds.
	// Exponential approach also avoids a visible hard clamp on each new stamp.
	float ceiling=mix(0.16,0.58,movement)*mix(0.6,1.0,coarse);
	float capacity=ceiling*shell*mix(0.65,1.0,contour);
	float rate=detail*wet*generation*pc.source.z*8.0*pc.style.w/max(ceiling,0.01);
	float alpha=max(capacity-old.r,0.0)*(1.0-exp(-rate));
	float total=old.r+alpha;
	float spread=min(pc.heading.z*0.16,4.0)*(0.35+coarse*1.1)*pc.heading.w;
	// Elliptical radial flow favours the sides while also reaching bow/stern.
	// Broad coherent variation prevents a uniform expanding circle.
	vec2 radial=lateral*across+forward*along*0.55;
	radial/=max(length(radial),0.06);
	float contact_share=1.0-0.9*smoothstep(0.5,3.0,pc.heading.z);
	vec2 outward=radial*pc.region.w*(0.65+coarse*0.7)*contact_share
		+lateral*sign(across)*spread+forward*(fine-0.5)*spread*0.12;
	float coverage=total;
	float agitation=clamp(smoothstep(0.5,14.0,pc.heading.z)*0.85+birth*0.65,0.0,1.0);
	// Premultiplied velocity and agitation survive filtering against empty texels.
	float normalization=coverage/max(total,0.00001);
	imageStore(fields,p,vec4(coverage,(old.gb+outward*alpha)*normalization,(old.a+agitation*alpha)*normalization));
}
