// Shared seeded broadband spectrum, evaluated as an Eulerian heightfield.
// Choppiness adds a bounded crest harmonic, not a second FFT simulation.
float wave_area_weight(vec3 p, mat4 inverse_frame, vec4 shape, vec4 blend) {
	vec2 q = (inverse_frame * vec4(p, 1.0)).xz;
	float distance_m;
	if (shape.w < 0.5) {
		vec2 d = (abs(q) - shape.xz) * blend.yz;
		distance_m = length(max(d,vec2(0.0))) + min(max(d.x,d.y),0.0);
	} else {
		distance_m = (length(q) - shape.x) * min(blend.y,blend.z);
	}
	return 1.0 - smoothstep(0.0, max(blend.x, 0.001), distance_m);
}

// height, slope.x, slope.z, vertical speed per ocean simulation second.
vec4 wave_area_component(vec2 p, vec4 c, vec4 extra, float time_s) {
	float phase = dot(p,c.xy) - time_s*c.w + extra.x;
	float derivative = c.z*(cos(phase)-2.0*extra.y*sin(2.0*phase));
	return vec4(c.z*(sin(phase)+extra.y*cos(2.0*phase)), derivative*c.xy, -derivative*c.w);
}

vec4 wave_area_group(vec2 p, vec4 value, vec4 groups, float seed, float time_s) {
	if (groups.x <= 0.0) { return value; }
	float phase = dot(p,groups.yz) - time_s*groups.w + seed*0.723;
	float norm = sqrt(1.0+groups.x*groups.x*0.5);
	float envelope = (1.0+groups.x*sin(phase))/norm;
	float derivative = groups.x*cos(phase)/norm;
	return vec4(value.x*envelope, value.yz*envelope+value.x*derivative*groups.yz, value.w*envelope-value.x*derivative*groups.w);
}
