/* P6_BUBBLE_NOISE_BINDINGS_BEGIN */
/* P6_BUBBLE_NOISE_BINDINGS_END */

/* P6_BUBBLE_NOISE_HELPERS_BEGIN */
/* P6_BUBBLE_NOISE_MACRO_BEGIN */
// Coherent value-noise basis. Camera motion never affects its coordinates;
// the persistent advection and flow/wave warps below evolve its domain.
float bubble_macro_hash_3d(vec3 p) {
	p = fract(p * 0.1031);
	p += dot(p, p.yzx + 33.33);
	return fract((p.x + p.y) * p.z);
}

float bubble_macro_noise_3d(vec3 p) {
	vec3 cell = floor(p);
	vec3 local = fract(p);
	local = local * local * (3.0 - 2.0 * local);
	float n000 = bubble_macro_hash_3d(cell + vec3(0.0, 0.0, 0.0));
	float n100 = bubble_macro_hash_3d(cell + vec3(1.0, 0.0, 0.0));
	float n010 = bubble_macro_hash_3d(cell + vec3(0.0, 1.0, 0.0));
	float n110 = bubble_macro_hash_3d(cell + vec3(1.0, 1.0, 0.0));
	float n001 = bubble_macro_hash_3d(cell + vec3(0.0, 0.0, 1.0));
	float n101 = bubble_macro_hash_3d(cell + vec3(1.0, 0.0, 1.0));
	float n011 = bubble_macro_hash_3d(cell + vec3(0.0, 1.0, 1.0));
	float n111 = bubble_macro_hash_3d(cell + vec3(1.0, 1.0, 1.0));
	float z0 = mix(mix(n000, n100, local.x), mix(n010, n110, local.x), local.y);
	float z1 = mix(mix(n001, n101, local.x), mix(n011, n111, local.x), local.y);
	return mix(z0, z1, local.z);
}
/* P6_BUBBLE_NOISE_MACRO_END */

/* P6_BUBBLE_NOISE_MICRO_BEGIN */
float bubble_micro_hash_3d(vec3 p) {
	p = fract(p * 0.1031);
	p += dot(p, p.yzx + 33.33);
	return fract((p.x + p.y) * p.z);
}

float bubble_micro_noise_3d(vec3 p) {
	vec3 cell = floor(p);
	vec3 local = fract(p);
	local = local * local * (3.0 - 2.0 * local);
	float n000 = bubble_micro_hash_3d(cell + vec3(0.0, 0.0, 0.0));
	float n100 = bubble_micro_hash_3d(cell + vec3(1.0, 0.0, 0.0));
	float n010 = bubble_micro_hash_3d(cell + vec3(0.0, 1.0, 0.0));
	float n110 = bubble_micro_hash_3d(cell + vec3(1.0, 1.0, 0.0));
	float n001 = bubble_micro_hash_3d(cell + vec3(0.0, 0.0, 1.0));
	float n101 = bubble_micro_hash_3d(cell + vec3(1.0, 0.0, 1.0));
	float n011 = bubble_micro_hash_3d(cell + vec3(0.0, 1.0, 1.0));
	float n111 = bubble_micro_hash_3d(cell + vec3(1.0, 1.0, 1.0));
	float z0 = mix(mix(n000, n100, local.x), mix(n010, n110, local.x), local.y);
	float z1 = mix(mix(n001, n101, local.x), mix(n011, n111, local.x), local.y);
	return mix(z0, z1, local.z);
}
/* P6_BUBBLE_NOISE_MICRO_END */

/* P6_BUBBLE_NOISE_WARP_BEGIN */

// Exact analytic curl field used by ocean_underwater_bubbles_update.glsl.
// The render domain therefore twists with the same field that advects density.
vec3 bubble_curl_octave(vec3 p, float time_phase) {
	return vec3(
		-sin(p.y + time_phase * 1.13) - cos(p.z + time_phase * 0.83),
		-sin(p.z - time_phase * 0.70) - cos(p.x - time_phase * 0.61),
		-sin(p.x + time_phase * 0.37) - cos(p.y + time_phase)
	);
}

vec3 bubble_curl_velocity(vec3 world_position) {
	float scale_m = max(bubbles.flow.w, 0.25);
	float phase = bubbles.noise.x * max(bubbles.advection.w, 0.0);
	vec3 p = world_position / scale_m;
	vec3 first = bubble_curl_octave(p, phase);
	vec3 second_p = vec3(p.z + 13.7, p.x - 7.1, p.y + 3.9) * 1.91;
	vec3 second = bubble_curl_octave(second_p, phase * 0.73 + 5.2);
	return (first + second * 0.35) * (0.36 * max(bubbles.flow.z, 0.0));
}
/* P6_BUBBLE_NOISE_WARP_END */
/* P6_BUBBLE_NOISE_HELPERS_END */
