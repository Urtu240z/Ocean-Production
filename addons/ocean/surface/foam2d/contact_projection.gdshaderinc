uniform bool foam2d_contact_enabled = false;
uniform bool foam2d_wake_enabled = false;
uniform int foam2d_vehicle_count = 0;
uniform mat4 foam2d_hull_inverse[12];
uniform vec4 foam2d_center[12];
uniform int foam2d_debug = 0;
uniform vec4 foam2d_water_tint : source_color = vec4(0.08,0.36,0.45,1.0);
uniform vec4 foam2d_white_color : source_color = vec4(0.85,0.93,0.94,1.0);
uniform float foam2d_opacity = 0.85;
uniform float foam2d_tint_strength = 0.20;
uniform float foam2d_calm_strength = 0.90;
uniform float foam2d_roughness = 0.62;
uniform float foam2d_specular = 0.24;
uniform float foam2d_normal_strength = 0.008;
uniform float foam2d_white_threshold = 0.38;
uniform float foam2d_white_transition = 0.32;
uniform float foam2d_white_strength = 0.85;
uniform float foam2d_patch_size = 1.7;
uniform float foam2d_variation = 0.95;
uniform float foam2d_time = 0.0;
uniform float foam2d_filament_deformation = 0.45;
uniform float foam2d_filament_speed = 0.75;
uniform bool foam2d_transport_detail = true;
// Local running foam shares the existing filaments; it never writes history.
uniform int foam2d_running_count = 0;
uniform mat4 foam2d_running_inverse[12];
uniform vec4 foam2d_running_center[12]; // XZ center, smoothed speed weight, spare
uniform vec4 foam2d_running_wet[12];
uniform vec4 foam2d_running_bounds = vec4(0.0);
uniform vec4 foam2d_running_color : source_color = vec4(0.97,0.99,1.0,1.0);
uniform float foam2d_running_strength = 1.8;
uniform float foam2d_running_whiteness = 1.0;
uniform float foam2d_running_roughness = 0.75;
uniform float foam2d_running_specular = 0.18;
uniform float foam2d_running_normal_strength = 0.008;
uniform vec3 foam2d_running_size = vec3(1.25,2.0,0.55);

float foam2d_hash(vec2 p) {
	vec3 q=fract(vec3(p.xyx)*0.1031); q+=dot(q,q.yzx+33.33);
	return fract((q.x+q.y)*q.z);
}
float foam2d_noise(vec2 p) {
	vec2 i=floor(p), f=fract(p); f=f*f*(3.0-2.0*f);
	return mix(mix(foam2d_hash(i),foam2d_hash(i+vec2(1,0)),f.x),mix(foam2d_hash(i+vec2(0,1)),foam2d_hash(i+vec2(1,1)),f.x),f.y);
}
float foam2d_grain_sample(vec2 world, vec2 cell) {
	float seed=foam2d_hash(cell);
	float angle=seed*6.2831853*foam2d_variation;
	mat2 rotation=mat2(vec2(cos(angle),-sin(angle)),vec2(sin(angle),cos(angle)));
	float scale=mix(0.75,1.85,foam2d_hash(cell+vec2(71.4,19.2)));
	vec2 offset=vec2(foam2d_hash(cell+17.3),foam2d_hash(cell+91.8))*17.0;
	return texture(crest_breakup_texture,rotation*world*scale/max(foam2d_patch_size,0.3)+offset).r;
}
// Three independently rotated, shifted and scaled samples on a triangular
// lattice. Shared vertices blend continuously across triangle boundaries.
float foam2d_stochastic_grain(vec2 world) {
	vec2 p=mat2(vec2(1.0,0.0),vec2(-0.5773503,1.1547005))*world/(2.2*max(foam2d_patch_size,0.3));
	vec2 cell=floor(p), f=fract(p);
	vec2 a=cell, b=cell+vec2(1,0), c=cell+vec2(0,1);
	vec3 weights=vec3(1.0-f.x-f.y,f.x,f.y);
	if(f.x+f.y>1.0) {
		a=cell+vec2(1,1); b=cell+vec2(0,1); c=cell+vec2(1,0);
		weights=vec3(f.x+f.y-1.0,1.0-f.x,1.0-f.y);
	}
	weights*=weights; weights/=max(dot(weights,vec3(1)),0.0001);
	float blended=dot(weights,vec3(foam2d_grain_sample(world,a),foam2d_grain_sample(world,b),foam2d_grain_sample(world,c)));
	// Preserve contrast through the blend so triangle centres do not become
	// uniform patches with a different whitening density than their edges.
	return clamp((blended-0.5)/sqrt(max(dot(weights,weights),0.001))+0.5,0.0,1.0);
}
float foam2d_running_contact(vec3 world) {
	if (foam2d_running_count == 0) { return 0.0; }
	if (any(lessThan(world.xz,foam2d_running_bounds.xy)) || any(greaterThan(world.xz,foam2d_running_bounds.zw))) { return 0.0; }
	float result = 0.0;
	float radius = max(foam2d_running_size.x,foam2d_running_size.y) + 1.0;
	for (int i=0;i<foam2d_running_count;i++) {
		if (any(greaterThan(abs(world.xz-foam2d_running_center[i].xy),vec2(radius)))) { continue; }
		vec3 p = (foam2d_running_inverse[i]*vec4(world,1.0)).xyz;
		vec2 radii = max(foam2d_running_size.xy,vec2(0.1));
		vec2 q = vec2(p.x,p.z);
		float k0=length(q/radii), k1=length(q/(radii*radii));
		float distance=k0<0.1?-min(radii.x,radii.y):k0*(k0-1.0)/max(k1,0.0001);
		float contour=(foam2d_noise(world.xz*1.7+vec2(31.7,8.4))-0.5)*0.28;
		float footprint=1.0-smoothstep(-foam2d_running_size.z,0.15,distance-contour);
		float port=1.0-smoothstep(-0.15,0.15,p.x);
		float front=1.0-smoothstep(-0.2,0.2,p.z);
		vec4 weights=vec4(port*front,(1.0-port)*front,port*(1.0-front),(1.0-port)*(1.0-front));
		float wet=dot(foam2d_running_wet[i],weights);
		result=max(result,footprint*wet*foam2d_running_center[i].z);
	}
	return result;
}

// Only a soft visibility window for the isolated contact comparison. All white
// foam, including beneath the hull, is sampled from the same persistent field.
vec4 foam2d_contact(vec3 world) {
	vec4 result=vec4(0.0);
	for(int i=0;i<foam2d_vehicle_count;i++) {
		if(any(greaterThan(abs(world.xz-foam2d_center[i].xy),vec2(2.7)))) continue;
		vec3 p=(foam2d_hull_inverse[i]*vec4(world,1.0)).xyz;
		float window=(1.0-smoothstep(0.85,1.25,abs(p.x)))*(1.0-smoothstep(1.6,2.25,abs(p.z)));
		result.x=max(result.x,window);
	}
	return result;
}
