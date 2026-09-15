shader_type spatial;
render_mode unshaded, blend_mix, cull_disabled, depth_draw_never;

uniform sampler2D displacement_long : repeat_enable, filter_linear;
uniform sampler2D displacement_mid : repeat_enable, filter_linear;
uniform sampler2D displacement_short : repeat_enable, filter_linear;
uniform sampler2D normal_long : repeat_enable, filter_linear;
uniform sampler2D normal_mid : repeat_enable, filter_linear;
uniform sampler2D normal_short : repeat_enable, filter_linear;
uniform sampler2D crest_breakup_texture : repeat_enable, filter_linear;
uniform vec2 mask_origin = vec2(0.0);
uniform float sea_level = 0.0;
uniform float domain_long_m = 512.0;
uniform float domain_mid_m = 137.0;
uniform float domain_short_m = 37.0;
uniform float crest_min = 0.001;
uniform float crest_full = 0.03;
uniform float min_wave_strength = 0.12;
uniform float storm_strength = 0.85;
uniform float wave_height_reference_m = 2.5;
uniform float long_whitecap_threshold = 0.62;
uniform float mid_whitecap_threshold = 0.66;
uniform float short_whitecap_threshold = 0.68;
uniform float long_crest_weight = 1.0;
uniform float mid_crest_weight = 0.65;
uniform float short_crest_weight = 0.10;
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
// Diagnostic outputs. These only change the displayed grayscale value; they
// do not change the values used by particle emission.
uniform int debug_output = 0;
uniform float debug_height_gain = 1.0;
uniform float debug_steepness_gain = 4.0;
uniform float debug_crest_gain = 1.0;
uniform float debug_breakup_gain = 1.0;
uniform float debug_active_radius_m = 48.0;

varying float source_value;

vec2 ocean_uv(vec2 world_xz, float domain_m) { return world_xz / max(domain_m, 0.001) + vec2(0.5); }
float fade_weight(float distance_m, float start_m, float end_m) { return 1.0 - smoothstep(start_m, max(end_m, start_m + 0.001), distance_m); }
float crest_breakup_mask_from_raw(float noise) {
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
	vec4 long_sample = vec4(0.0);
	vec4 mid_sample = vec4(0.0);
	vec4 short_sample = vec4(0.0);
	if (source_override == 0) {
		long_sample = texture(displacement_long, ocean_uv(world_xz, domain_long_m));
		mid_sample = texture(displacement_mid, ocean_uv(world_xz, domain_mid_m));
		short_sample = texture(displacement_short, ocean_uv(world_xz, domain_short_m));
		displacement = long_sample.xyz * long_weight
			+ mid_sample.xyz * mid_weight
			+ short_sample.xyz * short_weight;
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
		// displacement.*.a is the instantaneous Jacobian from assemble_maps.glsl.
		float long_break = max(0.0, long_whitecap_threshold - long_sample.a) * long_crest_weight * long_weight;
		float mid_break = max(0.0, mid_whitecap_threshold - mid_sample.a) * mid_crest_weight * mid_weight;
		float short_break = max(0.0, short_whitecap_threshold - short_sample.a) * short_crest_weight * short_weight;
		float mid_detail = clamp(mid_break * 0.55, 0.0, 1.0);
		float short_detail = clamp(short_break * 0.15, 0.0, 1.0);
		float instantaneous_break_source = 1.0 - (1.0 - clamp(long_break, 0.0, 1.0))
			* (1.0 - mid_detail) * (1.0 - short_detail);
		float raw_crest = clamp(instantaneous_break_source, 0.0, 1.0);
		float crest_gate = smoothstep(crest_min, max(crest_full, crest_min + 0.0001), raw_crest);
		float crest_distance_fade = 1.0 - smoothstep(crest_distance_fade_start_m, max(crest_distance_fade_end_m, crest_distance_fade_start_m + 0.001), distance_m);
		float breakup_raw = texture(crest_breakup_texture, world_xz / max(crest_breakup_world_size_m, 0.001)).r;
		float breakup_factor = crest_breakup_mask_from_raw(breakup_raw);
		vec3 normal_sum = texture(normal_long, ocean_uv(world_xz, domain_long_m)).xyz * long_weight
			+ texture(normal_mid, ocean_uv(world_xz, domain_mid_m)).xyz * mid_weight
			+ texture(normal_short, ocean_uv(world_xz, domain_short_m)).xyz * short_weight;
		vec3 normal = length(normal_sum) > 0.0001 ? normalize(normal_sum) : vec3(0.0, 1.0, 0.0);
		float steepness = length(normal.xz) / max(abs(normal.y), 0.08);
		float steep_gate = smoothstep(0.12, 0.72, steepness);
		float positive_height = max(displacement.y, 0.0);
		float height_ratio = positive_height / max(wave_height_reference_m, 0.01);
		float height_gate = smoothstep(min_wave_strength, max(min_wave_strength + 0.18, 0.20), height_ratio);
		float domain_fade = clamp(short_weight + mid_weight + long_weight, 0.0, 1.0);
		float clipmap_fade = max(short_weight, max(mid_weight, long_weight));
		float active_radius_fade = 1.0 - smoothstep(debug_active_radius_m * 0.82, max(debug_active_radius_m, debug_active_radius_m * 0.82 + 0.001), distance_m);
		float height_support = smoothstep(min_wave_strength, max(min_wave_strength + 0.18, 0.20), height_ratio);
		float clipmap_validity = max(long_weight, max(mid_weight, short_weight));
		float physical_spawn_score = clamp(instantaneous_break_source * height_support * domain_fade * clipmap_validity, 0.0, 1.0);
		float source_pre_threshold = physical_spawn_score;
		float source_final = clamp(physical_spawn_score * breakup_factor * crest_distance_fade * storm_strength, 0.0, 1.0);
		if (debug_output == 1) {
			source_value = clamp(positive_height * debug_height_gain, 0.0, 1.0);
		} else if (debug_output == 2) {
			source_value = clamp(height_gate * storm_strength, 0.0, 1.0);
		} else if (debug_output == 3) {
			source_value = clamp(steepness * debug_steepness_gain, 0.0, 1.0);
		} else if (debug_output == 4) {
			source_value = clamp(steep_gate * storm_strength, 0.0, 1.0);
		} else if (debug_output == 5) {
			source_value = clamp(raw_crest * debug_crest_gain, 0.0, 1.0);
		} else if (debug_output == 6) {
			source_value = clamp(crest_gate * storm_strength, 0.0, 1.0);
		} else if (debug_output == 7) {
			source_value = clamp(breakup_raw * debug_breakup_gain, 0.0, 1.0);
		} else if (debug_output == 8) {
			source_value = domain_fade;
		} else if (debug_output == 9) {
			source_value = clipmap_fade;
		} else if (debug_output == 10) {
			source_value = source_pre_threshold;
		} else if (debug_output == 11) {
			source_value = source_final;
		} else if (debug_output == 12) {
			source_value = short_weight;
		} else if (debug_output == 13) {
			source_value = mid_weight;
		} else if (debug_output == 14) {
			source_value = long_weight;
		} else if (debug_output == 15) {
			source_value = active_radius_fade;
		} else if (debug_output == 16) {
			source_value = float(raw_crest > 0.01);
		} else if (debug_output == 17) {
			source_value = float(raw_crest > 0.02);
		} else if (debug_output == 18) {
			source_value = float(raw_crest > 0.05);
		} else if (debug_output == 19) {
			source_value = float(raw_crest > 0.10);
		} else if (debug_output == 20) {
			source_value = float(raw_crest > 0.20);
		} else if (debug_output == 21) {
			source_value = float(raw_crest > 0.40);
		} else if (debug_output == 22) {
			source_value = float(raw_crest > 0.60);
		} else if (debug_output == 23) {
			source_value = clamp(raw_crest, 0.0, 1.0);
		} else if (debug_output == 24) {
			source_value = clamp(raw_crest * 4.0, 0.0, 1.0);
		} else if (debug_output == 25) {
			source_value = clamp(raw_crest * 8.0, 0.0, 1.0);
		} else if (debug_output == 26) {
			source_value = clamp(raw_crest * 16.0, 0.0, 1.0);
		} else if (source_debug_stage == 1) {
			source_value = clamp(height_gate * storm_strength, 0.0, 1.0);
		} else if (source_debug_stage == 2) {
			source_value = clamp(steep_gate * storm_strength, 0.0, 1.0);
		} else if (source_debug_stage == 3) {
			source_value = clamp(crest_gate * storm_strength, 0.0, 1.0);
		} else {
			source_value = source_final;
		}
	}
}

void fragment() {
	ALBEDO = vec3(source_value);
	ALPHA = 1.0;
}
