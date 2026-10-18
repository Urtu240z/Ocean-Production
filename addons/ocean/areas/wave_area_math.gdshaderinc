// Shared XZ footprint and exterior feather for surface/underwater FFT mixing.
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
