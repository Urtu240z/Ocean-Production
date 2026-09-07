/* P6_BUBBLE_NOISE_BINDINGS_BEGIN */
layout(set = 0, binding = 11) uniform sampler3D bubble_noise;
layout(set = 0, binding = 12) uniform sampler3D bubble_warp_noise;
/* P6_BUBBLE_NOISE_BINDINGS_END */

/* P6_BUBBLE_NOISE_HELPERS_BEGIN */
/* P6_BUBBLE_NOISE_MACRO_BEGIN */
// The scalar volume stores a tileable, prefiltered value-noise field. Macro
// and micro use the same volume at different frequencies and offsets.
float bubble_macro_noise_3d(vec3 p) {
	return textureLod(bubble_noise, fract((p + 0.5) / 32.0), 0.0).r;
}
/* P6_BUBBLE_NOISE_MACRO_END */

/* P6_BUBBLE_NOISE_MICRO_BEGIN */
float bubble_micro_noise_3d(vec3 p) {
	return textureLod(bubble_noise, fract((p + 0.5) / 32.0), 0.0).r;
}
/* P6_BUBBLE_NOISE_MICRO_END */

/* P6_BUBBLE_NOISE_WARP_BEGIN */
// The vector volume stores the two-octave curl basis at phase zero. A slow
// world-space phase offset keeps the lookup temporally alive without the
// per-march sin/cos evaluation used by the reference path.
vec3 bubble_curl_velocity(vec3 world_position) {
	float scale_m = max(bubbles.flow.w, 0.25);
	float phase = bubbles.noise.x * max(bubbles.advection.w, 0.0);
	vec3 p = world_position / scale_m;
	vec3 phase_offset = vec3(phase * 0.071, phase * 0.053, phase * 0.089);
	vec3 curl = textureLod(bubble_warp_noise, fract((p + phase_offset + 0.5) / 32.0), 0.0).xyz * 2.0 - 1.0;
	return curl * max(bubbles.flow.z, 0.0);
}
/* P6_BUBBLE_NOISE_WARP_END */
/* P6_BUBBLE_NOISE_HELPERS_END */
