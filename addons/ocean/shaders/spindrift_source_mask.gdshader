shader_type spatial;
render_mode unshaded, blend_mix, cull_disabled, depth_test_disabled;

uniform sampler2D displacement_long : repeat_enable, filter_linear;
uniform sampler2D displacement_mid : repeat_enable, filter_linear;
uniform sampler2D displacement_short : repeat_enable, filter_linear;
uniform sampler2D normal_long : repeat_enable, filter_linear;
uniform sampler2D normal_mid : repeat_enable, filter_linear;
uniform sampler2D normal_short : repeat_enable, filter_linear;
uniform sampler2D crest_foam_long : repeat_enable, filter_linear;
uniform sampler2D crest_foam_mid : repeat_enable, filter_linear;
uniform sampler2D crest_foam_short : repeat_enable, filter_linear;
uniform sampler2D crest_breakup_texture : repeat_enable, filter_linear;
uniform vec2 mask_origin = vec2(0.0);
uniform float sea_level = 0.0;
uniform float domain_long_m = 512.0;
uniform float domain_mid_m = 137.0;
uniform float domain_short_m = 37.0;
uniform float crest_threshold = 0.58;
uniform float crest_softness = 0.16;
uniform float min_wave_strength = 0.12;
uniform float storm_strength = 0.85;
uniform float wave_height_reference_m = 2.5;
uniform int source_debug_stage = 0;
uniform float short_fade_start_m = 0.0;
uniform float short_fade_end_m = 55.0;
uniform float mid_fade_start_m = 96.0;
uniform float mid_fade_end_m = 280.0;
uniform float long_fade_start_m = 768.0;
uniform float long_fade_end_m = 2500.0;
uniform float crest_detail_contribution = 0.35;
uniform float crest_intensity = 0.96;
uniform float crest_contrast = 1.19;
uniform float crest_distance_fade_start_m = 0.0;
uniform float crest_distance_fade_end_m = 5000.0;
uniform float crest_breakup_strength = 0.45;
uniform float crest_breakup_world_size_m = 14.0;
uniform float crest_edge_softness = 0.32;
// 0 = real source mask, 1 = forced black, 2 = forced white.
uniform int source_override = 0;

varying float source_value;

vec2 ocean_uv(vec2 world_xz, float domain_m) { return world_xz / max(domain_m, 0.001) + vec2(0.5); }
float fade_weight(float distance_m, float start_m, float end_m) { return 1.0 - smoothstep(start_m, max(end_m, start_m + 0.001), distance_m); }
float crest_breakup_mask(vec2 base_xz) {
	float noise = texture(crest_breakup_texture, base_xz / max(crest_breakup_world_size_m, 0.001)).r;
	float softness = clamp(crest_edge_softness, 0.01, 0.49);
	float breakup = mix(0.25, 1.0, smoothstep(0.5 - softness, 0.5 + softness, noise));
	return mix(1.0, breakup, crest_breakup_strength);
}

void vertex() {
	vec2 world_xz = mask_origin + VERTEX.xz;
	float distance_m = distance(world_xz, mask_origin);
	float long_weight = fade_weight(distance_m, long_fade_start_m, long_fade_end_m);
	float mid_weight = fade_weight(distance_m, mid_fade_start_m, mid_fade_end_m);
	float short_weight = fade_weight(distance_m, short_fade_start_m, short_fade_end_m);
	vec3 displacement = vec3(0.0);
	if (source_override == 0) {
		displacement = texture(displacement_long, ocean_uv(world_xz, domain_long_m)).xyz * long_weight
			+ texture(displacement_mid, ocean_uv(world_xz, domain_mid_m)).xyz * mid_weight
			+ texture(displacement_short, ocean_uv(world_xz, domain_short_m)).xyz * short_weight;
	}
	// Match the ocean surface vertex exactly: the source sample is evaluated at
	// the base world XZ, then the visible mask vertex follows the same displaced
	// world XZ/Y as the crest surface and particle spawn position.
	VERTEX.xz += displacement.xz;
	VERTEX.y = sea_level + displacement.y + 0.035;
	if (source_override == 1) {
		source_value = 0.0;
	} else if (source_override == 2) {
		source_value = 1.0;
	} else {
		float long_crest = texture(crest_foam_long, ocean_uv(world_xz, domain_long_m)).r * long_weight;
		float mid_detail = texture(crest_foam_mid, ocean_uv(world_xz, domain_mid_m)).r * mid_weight * crest_detail_contribution * 0.55;
		float short_detail = texture(crest_foam_short, ocean_uv(world_xz, domain_short_m)).r * short_weight * crest_detail_contribution * 0.30;
		float detail = 1.0 - (1.0 - clamp(mid_detail, 0.0, 1.0)) * (1.0 - clamp(short_detail, 0.0, 1.0));
		float raw_crest = 1.0 - (1.0 - clamp(long_crest, 0.0, 1.0)) * (1.0 - detail);
		float crest = pow(smoothstep(0.0, 1.0, raw_crest), 1.0 / max(crest_contrast, 0.1));
		float distance_fade = 1.0 - smoothstep(crest_distance_fade_start_m, max(crest_distance_fade_end_m, crest_distance_fade_start_m + 0.001), distance_m);
		crest = clamp(crest * crest_intensity * crest_breakup_mask(world_xz) * distance_fade, 0.0, 1.0);
		vec3 normal = normalize(texture(normal_long, ocean_uv(world_xz, domain_long_m)).xyz * long_weight
			+ texture(normal_mid, ocean_uv(world_xz, domain_mid_m)).xyz * mid_weight
			+ texture(normal_short, ocean_uv(world_xz, domain_short_m)).xyz * short_weight);
		float steepness = length(normal.xz) / max(abs(normal.y), 0.08);
		float steep_gate = smoothstep(0.12, 0.72, steepness);
		float height_gate = smoothstep(min_wave_strength, max(min_wave_strength + 0.18, 0.20), abs(displacement.y) / max(wave_height_reference_m, 0.01));
		float crest_gate = smoothstep(crest_threshold, crest_threshold + max(crest_softness, 0.01), crest);
		if (source_debug_stage == 1) {
			source_value = clamp(height_gate * storm_strength, 0.0, 1.0);
		} else if (source_debug_stage == 2) {
			source_value = clamp(steep_gate * storm_strength, 0.0, 1.0);
		} else if (source_debug_stage == 3) {
			source_value = clamp(crest_gate * storm_strength, 0.0, 1.0);
		} else {
			source_value = clamp(crest_gate * mix(0.45, 1.0, steep_gate) * mix(0.35, 1.0, height_gate) * storm_strength, 0.0, 1.0);
		}
	}
}

void fragment() {
	ALBEDO = vec3(source_value);
	ALPHA = 1.0;
}
