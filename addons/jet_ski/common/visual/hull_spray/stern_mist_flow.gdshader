shader_type particles;
render_mode disable_force, disable_velocity;

uniform mat4 hull_transform;
uniform bool guide_active = false;
uniform float hull_speed_mps = 0.0;
uniform float particle_lifetime_s = 0.65;
uniform vec3 hull_velocity = vec3(0.0);
uniform float side : hint_range(-1.0,1.0) = -1.0;
uniform float front_z = -2.95;
uniform float stern_z = 0.0;
uniform float front_width : hint_range(0.0,2.0) = 0.3;
uniform float middle_width : hint_range(0.0,2.0) = 0.68;
uniform float stern_width : hint_range(0.0,2.0) = 0.49;
uniform float guided_fraction : hint_range(0.1,0.95) = 0.95;
uniform vec3 emission_jitter = vec3(0.055,0.025,0.04);
uniform float stern_swirl : hint_range(0.0,0.3) = 0.045;
uniform float merge_distance_m : hint_range(0.0,2.0) = 0.25;
uniform float tail_length_m : hint_range(0.0,5.0) = 1.0;
uniform float scale_min : hint_range(0.01,5.0) = 0.8;
uniform float scale_max : hint_range(0.01,5.0) = 1.8;
uniform float birth_size : hint_range(0.0,5.0) = 1.0;
uniform float end_size : hint_range(0.0,5.0) = 1.0;
uniform vec4 base_color : source_color = vec4(1.0);
uniform sampler2D color_ramp : hint_default_white, repeat_disable, filter_linear;

float random_value(inout uint state) {
	state = state*1664525u+1013904223u;
	return float(state & 0x00ffffffu)/16777215.0;
}

vec3 contour(float progress, vec3 jitter) {
	float hull_progress = clamp(progress/0.7,0.0,1.0);
	float merge = smoothstep(0.7,0.82,progress);
	float tail_progress = smoothstep(0.82,1.0,progress);
	float width = mix(front_width,middle_width,smoothstep(0.0,0.48,hull_progress));
	width = mix(width,stern_width,smoothstep(0.48,1.0,hull_progress));
	width *= 1.0-merge;
	// Zero sideways slope at the stern gives a straight, continuous release.
	float envelope = pow(sin(hull_progress*3.14159265),2.0);
	float swirl = sin(hull_progress*12.5663706+jitter.x*40.0)*envelope*stern_swirl;
	vec3 scatter = jitter*vec3(mix(1.0,0.35,merge),1.0,1.0);
	return vec3(side*width+swirl,mix(0.0,0.025,progress),mix(front_z,stern_z,hull_progress)+merge_distance_m*merge+tail_length_m*tail_progress)+scatter;
}

void start() {
	uint seed = NUMBER*747796405u+RANDOM_SEED+2891336453u;
	USERDATA1 = vec4((vec3(random_value(seed),random_value(seed),random_value(seed))*2.0-1.0)*emission_jitter,
		mix(scale_min,scale_max,random_value(seed)));
	CUSTOM = vec4(0.0);
	VELOCITY = vec3(0.0);
	COLOR = base_color;
	TRANSFORM = hull_transform;
	TRANSFORM[3] = hull_transform*vec4(contour(0.0,USERDATA1.xyz),1.0);
	TRANSFORM[0].xyz *= USERDATA1.w;
	TRANSFORM[1].xyz *= USERDATA1.w;
	TRANSFORM[2].xyz *= USERDATA1.w;
}

void process() {
	CUSTOM.y += DELTA/max(particle_lifetime_s,0.001);
	float progress = clamp(CUSTOM.y/max(guided_fraction,0.001),0.0,1.0);
	COLOR = base_color*textureLod(color_ramp,vec2(clamp(CUSTOM.y,0.0,1.0),0.5),0.0);
	// Rebuild from the stable per-particle size, never multiply frame after frame.
	float size = USERDATA1.w*mix(birth_size,end_size,smoothstep(0.0,1.0,CUSTOM.y));
	vec3 axis_x = length(TRANSFORM[0].xyz)>0.00001 ? normalize(TRANSFORM[0].xyz) : vec3(1.0,0.0,0.0);
	vec3 axis_y = length(TRANSFORM[1].xyz)>0.00001 ? normalize(TRANSFORM[1].xyz) : vec3(0.0,1.0,0.0);
	vec3 axis_z = length(TRANSFORM[2].xyz)>0.00001 ? normalize(TRANSFORM[2].xyz) : vec3(0.0,0.0,1.0);
	TRANSFORM[0].xyz = axis_x*size;
	TRANSFORM[1].xyz = axis_y*size;
	TRANSFORM[2].xyz = axis_z*size;
	if (CUSTOM.z<0.5 && guide_active && CUSTOM.y<guided_fraction) {
		TRANSFORM[3] = hull_transform*vec4(contour(progress,USERDATA1.xyz),1.0);
	} else {
		if (CUSTOM.z<0.5) {
			if (guide_active) {
				TRANSFORM[3] = hull_transform*vec4(contour(1.0,USERDATA1.xyz),1.0);
			}
			// The complete metric route includes convergence and the common tail.
			// Detach at its end; lifetime changes pacing, not route length.
			VELOCITY = hull_velocity;
			CUSTOM.z = 1.0;
		} else {
			TRANSFORM[3].xyz += VELOCITY*DELTA;
		}
	}
	if (CUSTOM.y>=1.0) ACTIVE=false;
}
